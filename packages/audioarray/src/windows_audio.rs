use std::{
	collections::VecDeque,
	fs,
	path::PathBuf,
	sync::{
		atomic::{AtomicBool, AtomicU32, Ordering},
		Arc,
	},
	thread,
	time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use cpal::{
	traits::{DeviceTrait, HostTrait, StreamTrait},
	Device, Sample, SampleFormat, SampleRate, Stream, StreamConfig, SupportedStreamConfig,
};
use crossbeam_queue::ArrayQueue;
use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::Array2;
use serde::{Deserialize, Serialize};
use tracing::{error, info, warn};
use wasapi::{DeviceEnumerator, Direction as WasapiDirection, Role as WasapiRole};

use crate::{
	app_routing::{process_is_running, AppRouter, GlobalAudioDefaults},
	BusSummary, Config, EndpointSummary, GraphSnapshot, MeterReading,
};

const SAMPLE_RATE: u32 = 48_000;
const WAVEFORM_BINS: usize = 96;
const WAVEFORM_SAMPLES: usize = WAVEFORM_BINS * 2;
const WAVEFORM_WINDOW_MS: usize = 240;

const ENDPOINT_HISTORY_LIMIT: usize = 8;
const PREFERRED_ENDPOINT_RECHECK_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone, Copy)]
enum Direction {
	Input,
	Output,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct SavedEndpoint {
	id: String,
	name: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct PhysicalEndpointState {
	// These two fields migrate the original one-endpoint state format. New
	// state files contain only the ordered input/output histories below.
	#[serde(default, skip_serializing)]
	input: Option<SavedEndpoint>,
	#[serde(default, skip_serializing)]
	output: Option<SavedEndpoint>,
	#[serde(default)]
	inputs: Vec<SavedEndpoint>,
	#[serde(default)]
	outputs: Vec<SavedEndpoint>,
}

impl PhysicalEndpointState {
	fn migrate_legacy(&mut self) -> bool {
		let mut changed = false;
		if let Some(endpoint) = self.input.take() {
			changed |= remember_endpoint(&mut self.inputs, endpoint);
		}
		if let Some(endpoint) = self.output.take() {
			changed |= remember_endpoint(&mut self.outputs, endpoint);
		}
		changed
	}

	fn remember(&mut self, direction: Direction, endpoint: SavedEndpoint) -> bool {
		remember_endpoint(self.history_mut(direction), endpoint)
	}

	fn history(&self, direction: Direction) -> &[SavedEndpoint] {
		match direction {
			Direction::Input => &self.inputs,
			Direction::Output => &self.outputs,
		}
	}

	fn history_mut(&mut self, direction: Direction) -> &mut Vec<SavedEndpoint> {
		match direction {
			Direction::Input => &mut self.inputs,
			Direction::Output => &mut self.outputs,
		}
	}
}

fn remember_endpoint(history: &mut Vec<SavedEndpoint>, endpoint: SavedEndpoint) -> bool {
	let already_first = history
		.first()
		.is_some_and(|saved| saved.id == endpoint.id && saved.name == endpoint.name);
	history
		.retain(|saved| saved.id != endpoint.id && !saved.name.eq_ignore_ascii_case(&endpoint.name));
	history.insert(0, endpoint);
	history.truncate(ENDPOINT_HISTORY_LIMIT);
	!already_first
}

struct EndpointCoordinator {
	state_path: PathBuf,
	state: PhysicalEndpointState,
	defaults: GlobalAudioDefaults,
	temporary_output: Option<String>,
}

impl EndpointCoordinator {
	fn new(config: &Config) -> Result<Self> {
		let state_path = physical_state_path()?;
		let mut state = load_physical_state(&state_path)?;
		let mut changed = state.migrate_legacy();
		for (wasapi_direction, direction) in [
			(WasapiDirection::Capture, Direction::Input),
			(WasapiDirection::Render, Direction::Output),
		] {
			if let Some(endpoint) = default_endpoint(wasapi_direction)? {
				if !is_non_physical_endpoint_name(&endpoint.name) {
					changed |= state.remember(direction, endpoint);
				}
			}
		}
		if state.inputs.is_empty() || state.outputs.is_empty() {
			bail!(
				"AudioArray has no remembered physical input/output. Stop AudioArray, select physical Windows defaults, then start it again"
			);
		}
		if changed || !state_path.exists() {
			save_physical_state(&state_path, &state)?;
		}
		let defaults = GlobalAudioDefaults::new(config)?;
		let temporary_output = temporary_output_for_session(config)?;
		defaults.enforce_inputs()?;
		if !temporary_output_yields_defaults(config, temporary_output.as_deref()) {
			defaults.enforce_outputs()?;
		}
		Ok(Self {
			state_path,
			state,
			defaults,
			temporary_output,
		})
	}

	fn effective_config(&self, config: &Config) -> Result<Config> {
		let mut effective = config.clone();
		effective.microphone.input = if let Some(temporary_input) = self.temporary_input(config) {
			temporary_input
		} else {
			first_active_endpoint_name(Direction::Input, self.state.history(Direction::Input))?
		};
		effective.monitor.output = if let Some(temporary_output) = &self.temporary_output {
			temporary_output.clone()
		} else {
			first_active_endpoint_name(Direction::Output, self.state.history(Direction::Output))?
		};
		Ok(effective)
	}

	fn temporary_input(&self, config: &Config) -> Option<String> {
		temporary_input_for_output(config, self.temporary_output.as_deref())
	}

	fn reconcile(&mut self, config: &Config) -> Result<bool> {
		let mut changed = false;
		let temporary_output = temporary_output_for_session(config)?;
		let temporary_changed = temporary_output != self.temporary_output;
		if temporary_changed {
			info!(
				output = temporary_output.as_deref().unwrap_or("physical fallback"),
				"temporary session audio output changed"
			);
			self.temporary_output = temporary_output;
		}
		for (wasapi_direction, direction, label) in [
			(WasapiDirection::Capture, Direction::Input, "input"),
			(WasapiDirection::Render, Direction::Output, "output"),
		] {
			let Some(endpoint) = default_endpoint(wasapi_direction)? else {
				continue;
			};
			if !is_non_physical_endpoint_name(&endpoint.name)
				&& self.state.remember(direction, endpoint.clone())
			{
				info!(physical_endpoint = %endpoint.name, "adopted Windows-selected physical {label}");
				changed = true;
			}
		}
		if changed {
			save_physical_state(&self.state_path, &self.state)?;
		}
		if changed || !input_defaults_match(config)? {
			self.defaults.enforce_inputs()?;
		}
		if !temporary_output_yields_defaults(config, self.temporary_output.as_deref())
			&& (changed || temporary_changed || !output_defaults_match(config)?)
		{
			self.defaults.enforce_outputs()?;
		}
		Ok(changed || temporary_changed)
	}

	fn returned_preferred_endpoint(
		&self,
		config: &Config,
		graph: &RunningGraph,
	) -> Option<(&'static str, String)> {
		if self.temporary_input(config).is_none() {
			if let Some(endpoint) = returned_preferred_endpoint(
				Direction::Input,
				self.state.history(Direction::Input),
				&graph.input_name,
			) {
				return Some(("input", endpoint));
			}
		}
		if self.temporary_output.is_none() {
			if let Some(endpoint) = returned_preferred_endpoint(
				Direction::Output,
				self.state.history(Direction::Output),
				&graph.output_name,
			) {
				return Some(("output", endpoint));
			}
		}
		None
	}
}

struct RunningGraph {
	_streams: Vec<Stream>,
	failed: Arc<AtomicBool>,
	worker_stop: Arc<AtomicBool>,
	worker: Option<thread::JoinHandle<()>>,
	input_name: String,
	output_name: String,
}

impl Drop for RunningGraph {
	fn drop(&mut self) {
		self.worker_stop.store(true, Ordering::Release);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
	}
}

fn physical_state_path() -> Result<PathBuf> {
	let app_data = std::env::var_os("APPDATA")
		.ok_or_else(|| anyhow!("APPDATA is unavailable; cannot persist physical audio selections"))?;
	Ok(PathBuf::from(app_data)
		.join("AudioArray")
		.join("physical-endpoints.toml"))
}

fn temporary_output_for_session(config: &Config) -> Result<Option<String>> {
	// OculusDash exists only while a Link/Air Link session is presenting the
	// Quest runtime. Detect it directly so Meta can be configured to preserve
	// Windows defaults and never let applications bypass AudioArray's buses.
	if process_is_running("OculusDash.exe")?
		&& resolve_endpoint(WasapiDirection::Render, &config.monitor.vr_output).is_ok()
	{
		return Ok(Some(config.monitor.vr_output.trim().to_string()));
	}

	let Some(endpoint) = default_endpoint_for_role(WasapiDirection::Render, WasapiRole::Console)?
	else {
		return Ok(None);
	};
	for temporary_output in [&config.monitor.remote_output, &config.monitor.vr_output] {
		if endpoint.name.eq_ignore_ascii_case(temporary_output.trim()) {
			return Ok(Some(endpoint.name));
		}
	}
	Ok(None)
}

fn temporary_output_yields_defaults(config: &Config, temporary_output: Option<&str>) -> bool {
	temporary_output
		.is_some_and(|output| output.eq_ignore_ascii_case(config.monitor.remote_output.trim()))
}

fn temporary_input_for_output(config: &Config, temporary_output: Option<&str>) -> Option<String> {
	temporary_output
		.filter(|output| output.eq_ignore_ascii_case(config.monitor.vr_output.trim()))
		.map(|_| config.microphone.vr_input.trim().to_string())
}

fn load_physical_state(path: &PathBuf) -> Result<PhysicalEndpointState> {
	if !path.exists() {
		return Ok(PhysicalEndpointState::default());
	}
	let text = fs::read_to_string(path)
		.with_context(|| format!("could not read physical endpoint state {}", path.display()))?;
	toml::from_str(&text)
		.with_context(|| format!("could not parse physical endpoint state {}", path.display()))
}

fn save_physical_state(path: &PathBuf, state: &PhysicalEndpointState) -> Result<()> {
	let parent = path
		.parent()
		.ok_or_else(|| anyhow!("physical endpoint state path has no parent"))?;
	fs::create_dir_all(parent)?;
	fs::write(path, toml::to_string_pretty(state)?)
		.with_context(|| format!("could not save physical endpoint state {}", path.display()))
}

fn default_endpoint(direction: WasapiDirection) -> Result<Option<SavedEndpoint>> {
	default_endpoint_for_role(direction, WasapiRole::Console)
}

fn default_endpoint_for_role(
	direction: WasapiDirection,
	role: WasapiRole,
) -> Result<Option<SavedEndpoint>> {
	let _ = wasapi::initialize_mta();
	let enumerator =
		DeviceEnumerator::new().context("could not enumerate Windows audio defaults")?;
	let device = match enumerator.get_default_device_for_role(&direction, &role) {
		Ok(device) => device,
		Err(_) => return Ok(None),
	};
	Ok(Some(SavedEndpoint {
		id: device.get_id()?,
		name: device.get_friendlyname()?,
	}))
}

fn output_defaults_match(config: &Config) -> Result<bool> {
	for (direction, role, expected) in [
		(
			WasapiDirection::Render,
			WasapiRole::Console,
			config.cables.game.as_str(),
		),
		(
			WasapiDirection::Render,
			WasapiRole::Multimedia,
			config.cables.game.as_str(),
		),
		(
			WasapiDirection::Render,
			WasapiRole::Communications,
			config.cables.comms.as_str(),
		),
	] {
		let Some(endpoint) = default_endpoint_for_role(direction, role)? else {
			return Ok(false);
		};
		if !endpoint.name.eq_ignore_ascii_case(expected) {
			return Ok(false);
		}
	}
	Ok(true)
}

fn input_defaults_match(config: &Config) -> Result<bool> {
	for role in [
		WasapiRole::Console,
		WasapiRole::Multimedia,
		WasapiRole::Communications,
	] {
		let Some(endpoint) = default_endpoint_for_role(WasapiDirection::Capture, role)? else {
			return Ok(false);
		};
		if !endpoint.name.eq_ignore_ascii_case(&config.cables.clean_mic) {
			return Ok(false);
		}
	}
	Ok(true)
}

fn effective_physical_config(config: &Config) -> Result<Config> {
	let state_path = physical_state_path()?;
	let mut state = load_physical_state(&state_path)?;
	state.migrate_legacy();
	let mut effective = config.clone();
	effective.microphone.input =
		first_active_endpoint_name(Direction::Input, state.history(Direction::Input))?;
	effective.monitor.output =
		first_active_endpoint_name(Direction::Output, state.history(Direction::Output))?;
	Ok(effective)
}

fn effective_session_config(config: &Config) -> Result<Config> {
	let mut effective = effective_physical_config(config)?;
	if let Some(temporary_output) = temporary_output_for_session(config)? {
		effective.monitor.output = temporary_output.clone();
		if let Some(temporary_input) = temporary_input_for_output(config, Some(&temporary_output)) {
			effective.microphone.input = temporary_input;
		}
	}
	Ok(effective)
}

pub(crate) fn print_devices() -> Result<()> {
	let host = cpal::default_host();
	let default_input = device_name(host.default_input_device().as_ref());
	let default_output = device_name(host.default_output_device().as_ref());
	println!(
		"Default input:  {}",
		default_input.as_deref().unwrap_or("<none>")
	);
	println!(
		"Default output: {}",
		default_output.as_deref().unwrap_or("<none>")
	);
	println!("\nWindows role defaults:");
	for (direction, role, label) in [
		(
			WasapiDirection::Render,
			WasapiRole::Console,
			"Output console",
		),
		(
			WasapiDirection::Render,
			WasapiRole::Multimedia,
			"Output multimedia",
		),
		(
			WasapiDirection::Render,
			WasapiRole::Communications,
			"Output communications",
		),
		(
			WasapiDirection::Capture,
			WasapiRole::Console,
			"Input console",
		),
		(
			WasapiDirection::Capture,
			WasapiRole::Multimedia,
			"Input multimedia",
		),
		(
			WasapiDirection::Capture,
			WasapiRole::Communications,
			"Input communications",
		),
	] {
		let name = default_endpoint_for_role(direction, role)?
			.map(|endpoint| endpoint.name)
			.unwrap_or_else(|| "<none>".into());
		println!("  {label:23} {name}");
	}
	println!("\nInput endpoints:");
	for device in host
		.input_devices()
		.context("could not enumerate input endpoints")?
	{
		println!(
			"  {}",
			device.name().unwrap_or_else(|_| "<unreadable>".into())
		);
	}
	println!("\nOutput endpoints:");
	for device in host
		.output_devices()
		.context("could not enumerate output endpoints")?
	{
		println!(
			"  {}",
			device.name().unwrap_or_else(|_| "<unreadable>".into())
		);
	}
	Ok(())
}

pub(crate) fn doctor(config: &Config) -> Result<()> {
	let effective = effective_physical_config(config)?;
	let host = cpal::default_host();
	let input = resolve_physical_device(&host, Direction::Input, &effective.microphone.input)?;
	let output = resolve_physical_device(&host, Direction::Output, &effective.monitor.output)?;
	let remote_output =
		resolve_named_device(&host, Direction::Output, &effective.monitor.remote_output)?;
	let vr_output = resolve_named_device(&host, Direction::Output, &effective.monitor.vr_output)?;
	let vr_input = resolve_named_device(&host, Direction::Input, &effective.microphone.vr_input)?;
	validate_cables(&host, config)?;
	println!("AudioArray graph is ready.");
	println!("  Physical input:  {}", input.name()?);
	println!("  Physical output: {}", output.name()?);
	println!("  Moonlight output: {}", remote_output.name()?);
	println!("  VR output:        {}", vr_output.name()?);
	println!("  VR input:         {}", vr_input.name()?);
	println!(
		"  Suppression:     {}",
		if config.noise_suppression.enabled {
			"DeepFilterNet3"
		} else {
			"disabled"
		}
	);
	Ok(())
}

pub(crate) fn benchmark(config: &Config, seconds: u32) -> Result<()> {
	if seconds == 0 || seconds > 300 {
		bail!("benchmark duration must be between 1 and 300 seconds");
	}
	let runtime = RuntimeParams::default_with_ch(1)
		.with_atten_lim(config.noise_suppression.attenuation_limit_db)
		.with_post_filter(config.noise_suppression.post_filter_beta);
	let mut model = DfTract::new(DfParams::default(), &runtime)
		.context("could not initialize the embedded DeepFilterNet3 model")?;
	let mut input = Array2::zeros((1, model.hop_size));
	let mut output = Array2::zeros((1, model.hop_size));
	model.process(input.view(), output.view_mut())?;
	let frame_count = seconds as usize * model.sr / model.hop_size;
	let mut phase = 0.0_f32;
	let mut random = 0x9e37_79b9_u32;
	let started = Instant::now();
	for _ in 0..frame_count {
		for sample in input.iter_mut() {
			random ^= random << 13;
			random ^= random >> 17;
			random ^= random << 5;
			let noise = (random as f32 / u32::MAX as f32 - 0.5) * 0.04;
			*sample = phase.sin() * 0.12 + noise;
			phase += std::f32::consts::TAU * 180.0 / model.sr as f32;
		}
		model.process(input.view(), output.view_mut())?;
	}
	let elapsed = started.elapsed();
	let realtime = Duration::from_secs(seconds as u64);
	println!(
		"Processed {seconds}s of noisy audio in {:.3}s.",
		elapsed.as_secs_f64()
	);
	println!(
		"Real-time factor: {:.3}x.",
		elapsed.as_secs_f64() / realtime.as_secs_f64()
	);
	println!(
		"Compute headroom: {:.1}x real time.",
		realtime.as_secs_f64() / elapsed.as_secs_f64()
	);
	Ok(())
}

pub(crate) fn levels(config: &Config, seconds: u32) -> Result<()> {
	if seconds == 0 || seconds > 60 {
		bail!("level probe duration must be between 1 and 60 seconds");
	}
	let effective = effective_session_config(config)?;
	let host = cpal::default_host();
	let devices = [
		(
			"Physical Mic",
			resolve_microphone_device(&host, &effective)?,
		),
		(
			"Game",
			resolve_named_device(&host, Direction::Input, &config.cables.game)?,
		),
		(
			"Comms",
			resolve_named_device(&host, Direction::Input, &config.cables.comms)?,
		),
		(
			"Music",
			resolve_named_device(&host, Direction::Input, &config.cables.music)?,
		),
		(
			"Clean Mic",
			resolve_named_device(&host, Direction::Input, &config.cables.clean_mic)?,
		),
	];
	let mut streams = Vec::new();
	let mut meters = Vec::new();
	for (label, device) in devices {
		let supported = preferred_config(&device, Direction::Input, true)?;
		let stream_config: StreamConfig = supported.clone().into();
		let peak = Arc::new(AtomicU32::new(0.0_f32.to_bits()));
		let stream = build_level_input(
			&device,
			&stream_config,
			supported.sample_format(),
			peak.clone(),
			None,
		)?;
		stream.play()?;
		meters.push((label, device.name()?, peak));
		streams.push(stream);
	}
	println!("Measuring live audio for {seconds} seconds...");
	thread::sleep(Duration::from_secs(seconds as u64));
	drop(streams);
	for (label, device, peak) in meters {
		let peak = f32::from_bits(peak.load(Ordering::Relaxed));
		let dbfs = if peak > 0.0 {
			20.0 * peak.log10()
		} else {
			f32::NEG_INFINITY
		};
		println!("{label:12} {dbfs:7.1} dBFS  {device}");
	}
	Ok(())
}

pub(crate) fn graph_snapshot(config: &Config) -> Result<GraphSnapshot> {
	let state_path = physical_state_path()?;
	let mut state = load_physical_state(&state_path)?;
	state.migrate_legacy();
	let mut input_devices = physical_endpoints(Direction::Input, state.history(Direction::Input))?;
	let mut output_devices =
		physical_endpoints(Direction::Output, state.history(Direction::Output))?;
	let main_input = input_devices
		.iter()
		.find(|endpoint| endpoint.selected)
		.cloned();
	let main_output = output_devices
		.iter()
		.find(|endpoint| endpoint.selected)
		.cloned();
	let session_override = temporary_output_for_session(config)?;
	let session_input_override = temporary_input_for_output(config, session_override.as_deref());
	if let Some(session_input) = &session_input_override {
		mark_selected_endpoint(&mut input_devices, session_input);
	}
	if session_override
		.as_deref()
		.is_some_and(|output| output.eq_ignore_ascii_case(config.monitor.vr_output.trim()))
	{
		mark_selected_endpoint(&mut output_devices, &config.monitor.vr_output);
	}
	let routing_ready = input_defaults_match(config)?
		&& (temporary_output_yields_defaults(config, session_override.as_deref())
			|| output_defaults_match(config)?);
	let suppression = if config.noise_suppression.enabled {
		"DeepFilterNet3".to_string()
	} else {
		"Bypassed".to_string()
	};

	Ok(GraphSnapshot {
		platform: "windows",
		engine_online: process_is_running("audioarray.exe")?,
		routing_ready,
		sample_rate: SAMPLE_RATE,
		suppression,
		suppression_enabled: config.noise_suppression.enabled,
		suppression_intensity: crate::suppression_intensity(&config.noise_suppression),
		suppression_attenuation_limit_db: config.noise_suppression.attenuation_limit_db,
		main_input,
		main_output,
		input_devices,
		output_devices,
		session_override,
		session_input_override,
		buses: vec![
			BusSummary {
				id: "game",
				name: config.cables.game.clone(),
				purpose: "Windows default / games",
				spatial: Some("DTS Headphone:X"),
			},
			BusSummary {
				id: "comms",
				name: config.cables.comms.clone(),
				purpose: "Voice communications",
				spatial: None,
			},
			BusSummary {
				id: "music",
				name: config.cables.music.clone(),
				purpose: "Music applications",
				spatial: Some("Dolby Atmos for Headphones"),
			},
			BusSummary {
				id: "clean-mic",
				name: config.cables.clean_mic.clone(),
				purpose: "Suppressed microphone",
				spatial: None,
			},
		],
		routes: config.routes.clone(),
		monitor_latency_ms: config.monitor.latency_ms,
		microphone_latency_ms: config.microphone.latency_ms,
	})
}

pub(crate) fn meter_snapshot(config: &Config) -> Result<Vec<MeterReading>> {
	let mut probe = MeterProbe::new(config)?;
	thread::sleep(Duration::from_millis(80));
	Ok(probe.read())
}

struct SignalProbe {
	id: &'static str,
	peak: Arc<AtomicU32>,
	samples: Arc<ArrayQueue<f32>>,
	history: VecDeque<f32>,
	history_limit: usize,
}

pub(crate) struct MeterProbe {
	input_name: String,
	signals: Vec<SignalProbe>,
	_streams: Vec<Stream>,
}

impl MeterProbe {
	pub(crate) fn new(config: &Config) -> Result<Self> {
		let effective = effective_session_config(config)?;
		let host = cpal::default_host();
		let active_input = resolve_microphone_device(&host, &effective)?;
		let input_name = active_input.name()?;
		let devices = [
			("physical-mic", active_input),
			(
				"game",
				resolve_named_device(&host, Direction::Input, &config.cables.game)?,
			),
			(
				"comms",
				resolve_named_device(&host, Direction::Input, &config.cables.comms)?,
			),
			(
				"music",
				resolve_named_device(&host, Direction::Input, &config.cables.music)?,
			),
			(
				"clean-mic",
				resolve_named_device(&host, Direction::Input, &config.cables.clean_mic)?,
			),
		];
		let mut signals = Vec::new();
		let mut streams = Vec::new();
		for (id, device) in devices {
			let supported = preferred_config(&device, Direction::Input, true)?;
			let stream_config: StreamConfig = supported.clone().into();
			let peak = Arc::new(AtomicU32::new(0.0_f32.to_bits()));
			let history_limit =
				(stream_config.sample_rate.0 as usize * WAVEFORM_WINDOW_MS / 1_000).max(WAVEFORM_BINS);
			let samples = Arc::new(ArrayQueue::new(history_limit * 2));
			let stream = build_level_input(
				&device,
				&stream_config,
				supported.sample_format(),
				peak.clone(),
				Some(samples.clone()),
			)?;
			stream.play()?;
			signals.push(SignalProbe {
				id,
				peak,
				samples,
				history: VecDeque::with_capacity(history_limit),
				history_limit,
			});
			streams.push(stream);
		}
		Ok(Self {
			input_name,
			signals,
			_streams: streams,
		})
	}

	pub(crate) fn read(&mut self) -> Vec<MeterReading> {
		let mut readings = Vec::with_capacity(self.signals.len() + 2);
		for signal in &mut self.signals {
			while let Some(sample) = signal.samples.pop() {
				signal.history.push_back(sample);
			}
			while signal.history.len() > signal.history_limit {
				signal.history.pop_front();
			}
			readings.push(meter_reading(
				signal.id,
				f32::from_bits(signal.peak.swap(0, Ordering::AcqRel)),
				waveform_from_history(&signal.history),
			));
		}
		let monitor_peak = readings
			.iter()
			.filter(|reading| matches!(reading.id, "game" | "comms" | "music"))
			.map(|reading| reading.peak)
			.fold(0.0_f32, f32::max);
		let monitor_waveform = (0..WAVEFORM_SAMPLES)
			.map(|index| {
				readings
					.iter()
					.filter(|reading| matches!(reading.id, "game" | "comms" | "music"))
					.map(|reading| reading.waveform.get(index).copied().unwrap_or(0.0))
					.sum::<f32>()
					.clamp(-1.0, 1.0)
			})
			.collect();
		let clean_mic_peak = readings
			.iter()
			.find(|reading| reading.id == "clean-mic")
			.map_or(0.0, |reading| reading.peak);
		let complete_waveform = (0..WAVEFORM_SAMPLES)
			.map(|index| {
				readings
					.iter()
					.filter(|reading| matches!(reading.id, "game" | "comms" | "music" | "clean-mic"))
					.map(|reading| reading.waveform.get(index).copied().unwrap_or(0.0))
					.sum::<f32>()
					.clamp(-1.0, 1.0)
			})
			.collect();
		readings.push(meter_reading("monitor", monitor_peak, monitor_waveform));
		readings.push(meter_reading(
			"complete-mix",
			monitor_peak.max(clean_mic_peak),
			complete_waveform,
		));
		readings
	}

	pub(crate) fn is_current(&self, config: &Config) -> Result<bool> {
		Ok(self
			.input_name
			.eq_ignore_ascii_case(&effective_session_config(config)?.microphone.input))
	}
}

fn waveform_from_history(history: &VecDeque<f32>) -> Vec<f32> {
	let mut waveform = vec![0.0; WAVEFORM_SAMPLES];
	if history.is_empty() {
		return waveform;
	}
	for output_bin in 0..WAVEFORM_BINS {
		// New samples enter at the source side of the wire. As they age through
		// the rolling window they therefore travel toward the destination.
		let source_bin = WAVEFORM_BINS - output_bin - 1;
		let start = source_bin * history.len() / WAVEFORM_BINS;
		let end = ((source_bin + 1) * history.len() / WAVEFORM_BINS).max(start + 1);
		let mut minimum = 1.0_f32;
		let mut maximum = -1.0_f32;
		for index in start..end.min(history.len()) {
			let sample = history[index].clamp(-1.0, 1.0);
			minimum = minimum.min(sample);
			maximum = maximum.max(sample);
		}
		if maximum >= minimum {
			waveform[output_bin * 2] = minimum;
			waveform[output_bin * 2 + 1] = maximum;
		}
	}
	waveform
}

fn meter_reading(id: &'static str, peak: f32, waveform: Vec<f32>) -> MeterReading {
	let peak = peak.clamp(0.0, 1.0);
	let dbfs = if peak > 0.0 {
		20.0 * peak.log10()
	} else {
		-96.0
	};
	MeterReading {
		id,
		peak,
		dbfs,
		waveform,
	}
}

fn physical_endpoints(
	direction: Direction,
	history: &[SavedEndpoint],
) -> Result<Vec<EndpointSummary>> {
	let wasapi_direction = match direction {
		Direction::Input => WasapiDirection::Capture,
		Direction::Output => WasapiDirection::Render,
	};
	let selected = first_active_endpoint(direction, history).ok();
	let _ = wasapi::initialize_mta();
	let enumerator = DeviceEnumerator::new().context("could not enumerate physical endpoints")?;
	let collection = enumerator
		.get_device_collection(&wasapi_direction)
		.context("could not collect physical endpoints")?;
	let mut endpoints = Vec::new();
	for device in &collection {
		let device = device.context("could not inspect a physical endpoint")?;
		let endpoint = SavedEndpoint {
			id: device.get_id()?,
			name: device.get_friendlyname()?,
		};
		if is_non_physical_endpoint_name(&endpoint.name) && !is_quest_endpoint_name(&endpoint.name) {
			continue;
		}
		endpoints.push(EndpointSummary {
			selected: selected
				.as_ref()
				.is_some_and(|current| current.id == endpoint.id),
			id: endpoint.id,
			name: endpoint.name,
		});
	}
	endpoints.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
	Ok(endpoints)
}

fn mark_selected_endpoint(endpoints: &mut [EndpointSummary], selector: &str) {
	for endpoint in endpoints {
		endpoint.selected =
			endpoint.id == selector || endpoint.name.eq_ignore_ascii_case(selector.trim());
	}
}

fn first_active_endpoint(direction: Direction, history: &[SavedEndpoint]) -> Result<SavedEndpoint> {
	let name = first_active_endpoint_name(direction, history)?;
	let wasapi_direction = match direction {
		Direction::Input => WasapiDirection::Capture,
		Direction::Output => WasapiDirection::Render,
	};
	resolve_endpoint(wasapi_direction, &name)
}

fn resolve_endpoint(direction: WasapiDirection, selector: &str) -> Result<SavedEndpoint> {
	let _ = wasapi::initialize_mta();
	let enumerator = DeviceEnumerator::new().context("could not enumerate audio endpoints")?;
	let collection = enumerator
		.get_device_collection(&direction)
		.context("could not collect audio endpoints")?;
	let mut partial = Vec::new();
	for device in &collection {
		let device = device.context("could not inspect an audio endpoint")?;
		let endpoint = SavedEndpoint {
			id: device.get_id()?,
			name: device.get_friendlyname()?,
		};
		if endpoint.id == selector || endpoint.name.eq_ignore_ascii_case(selector) {
			return Ok(endpoint);
		}
		if endpoint
			.name
			.to_ascii_lowercase()
			.contains(&selector.to_ascii_lowercase())
		{
			partial.push(endpoint);
		}
	}
	match partial.len() {
		1 => Ok(partial.remove(0)),
		0 => bail!("no active audio endpoint matches {selector:?}"),
		_ => bail!("audio endpoint selector {selector:?} is ambiguous"),
	}
}

fn update_peak(peak: &AtomicU32, value: f32) {
	let value = value.abs().min(1.0);
	let mut current = peak.load(Ordering::Relaxed);
	while value > f32::from_bits(current) {
		match peak.compare_exchange_weak(
			current,
			value.to_bits(),
			Ordering::Relaxed,
			Ordering::Relaxed,
		) {
			Ok(_) => break,
			Err(observed) => current = observed,
		}
	}
}

fn build_level_input(
	device: &Device,
	config: &StreamConfig,
	format: SampleFormat,
	peak: Arc<AtomicU32>,
	samples: Option<Arc<ArrayQueue<f32>>>,
) -> Result<Stream> {
	macro_rules! build {
		($sample:ty) => {{
			let peak = peak.clone();
			let samples = samples.clone();
			let channels = config.channels.max(1) as usize;
			device.build_input_stream(
				config,
				move |data: &[$sample], _| {
					for frame in data.chunks(channels) {
						let mut mono = 0.0_f32;
						for &sample in frame {
							let sample = f32::from_sample(sample);
							update_peak(&peak, sample);
							mono += sample;
						}
						if let Some(samples) = &samples {
							push_latest(samples, mono / frame.len().max(1) as f32);
						}
					}
				},
				|err| error!(%err, "level probe stream failed"),
				None,
			)?
		}};
	}
	Ok(match format {
		SampleFormat::F32 => build!(f32),
		SampleFormat::I16 => build!(i16),
		SampleFormat::U16 => build!(u16),
		other => bail!("unsupported level-probe sample format {other}"),
	})
}

pub(crate) fn run(config: Config, stop: Arc<AtomicBool>) -> Result<()> {
	let mut endpoints = EndpointCoordinator::new(&config)?;
	let (mut graph, _) = wait_for_graph(&config, &mut endpoints, &stop)?;
	let mut app_router = AppRouter::new(&config)?;
	app_router.reconcile()?;
	let mut next_route_reconcile = Instant::now() + Duration::from_secs(3);
	let mut next_preferred_endpoint_recheck = Instant::now() + PREFERRED_ENDPOINT_RECHECK_INTERVAL;
	info!(input = %graph.input_name, output = %graph.output_name, "AudioArray graph started");

	while !stop.load(Ordering::Acquire) {
		thread::sleep(Duration::from_millis(750));
		match endpoints.reconcile(&config) {
			Ok(true) => {
				drop(graph);
				graph = wait_for_graph(&config, &mut endpoints, &stop)?.0;
				continue;
			}
			Ok(false) => {}
			Err(err) => warn!(%err, "could not reconcile Windows audio defaults; will retry"),
		}
		if Instant::now() >= next_preferred_endpoint_recheck {
			next_preferred_endpoint_recheck = Instant::now() + PREFERRED_ENDPOINT_RECHECK_INTERVAL;
			if let Some((direction, endpoint)) = endpoints.returned_preferred_endpoint(&config, &graph)
			{
				info!(%direction, %endpoint, "a higher-priority physical endpoint returned; rebuilding graph");
				drop(graph);
				graph = wait_for_graph(&config, &mut endpoints, &stop)?.0;
				continue;
			}
		}
		if Instant::now() >= next_route_reconcile {
			if let Err(err) = app_router.reconcile() {
				warn!(%err, "could not reconcile per-app audio routes; will retry");
			}
			next_route_reconcile = Instant::now() + Duration::from_secs(3);
		}
		if graph.failed.swap(false, Ordering::AcqRel) {
			warn!("an audio stream failed; rebuilding the complete graph");
			drop(graph);
			graph = wait_for_graph(&config, &mut endpoints, &stop)?.0;
		}
	}

	info!("AudioArray graph stopped");
	Ok(())
}

fn wait_for_graph(
	config: &Config,
	endpoints: &mut EndpointCoordinator,
	stop: &AtomicBool,
) -> Result<(RunningGraph, Config)> {
	let mut attempts = 0_u64;
	let mut retry_delay = Duration::from_secs(1);
	loop {
		if stop.load(Ordering::Acquire) {
			bail!("AudioArray stopped while waiting for audio devices");
		}
		if let Err(err) = endpoints.reconcile(config) {
			warn!(%err, "could not reconcile Windows audio defaults while waiting for devices");
		}
		let effective = match endpoints.effective_config(config) {
			Ok(effective) => effective,
			Err(err) => {
				attempts += 1;
				if attempts == 1 || attempts % 5 == 0 {
					warn!(%err, "no remembered physical endpoint is currently usable; waiting for a reconnect or a new Windows device selection");
				}
				if wait_before_graph_retry(retry_delay, config, endpoints, stop)? {
					retry_delay = Duration::from_secs(1);
				} else {
					retry_delay = retry_delay.saturating_mul(2).min(Duration::from_secs(30));
				}
				continue;
			}
		};
		match build_graph(&effective) {
			Ok(graph) => return Ok((graph, effective)),
			Err(err) => {
				attempts += 1;
				if attempts == 1 || attempts % 5 == 0 {
					warn!(%err, "physical audio endpoint unavailable; waiting for reconnection or a new Windows device selection");
				}
				if wait_before_graph_retry(retry_delay, config, endpoints, stop)? {
					retry_delay = Duration::from_secs(1);
				} else {
					retry_delay = retry_delay.saturating_mul(2).min(Duration::from_secs(30));
				}
			}
		}
	}
}

fn wait_before_graph_retry(
	delay: Duration,
	config: &Config,
	endpoints: &mut EndpointCoordinator,
	stop: &AtomicBool,
) -> Result<bool> {
	let deadline = Instant::now() + delay;
	while Instant::now() < deadline {
		if stop.load(Ordering::Acquire) {
			bail!("AudioArray stopped while waiting for audio devices");
		}
		thread::sleep(
			deadline
				.saturating_duration_since(Instant::now())
				.min(Duration::from_secs(1)),
		);
		match endpoints.reconcile(config) {
			Ok(true) => return Ok(true),
			Ok(false) => {}
			Err(err) => {
				warn!(%err, "could not reconcile Windows audio defaults while waiting for devices")
			}
		}
	}
	Ok(false)
}

fn validate_cables(host: &cpal::Host, config: &Config) -> Result<()> {
	for (label, selector, direction) in [
		("Game", config.cables.game.as_str(), Direction::Input),
		("Comms", config.cables.comms.as_str(), Direction::Input),
		("Music", config.cables.music.as_str(), Direction::Input),
		(
			"Clean Mic",
			config.cables.clean_mic.as_str(),
			Direction::Output,
		),
	] {
		resolve_named_device(host, direction, selector)
			.with_context(|| format!("{label} VAC endpoint is unavailable"))?;
	}
	Ok(())
}

fn build_graph(config: &Config) -> Result<RunningGraph> {
	let host = cpal::default_host();
	validate_cables(&host, config)?;
	let physical_input = resolve_microphone_device(&host, config)?;
	let monitor_output = resolve_monitor_device(&host, config)?;
	let input_name = physical_input.name()?;
	let output_name = monitor_output.name()?;
	let failed = Arc::new(AtomicBool::new(false));
	let mut streams = Vec::new();
	let monitor_outputs = vec![monitor_output];

	for (label, selector, gain) in [
		(
			"Game",
			config.cables.game.as_str(),
			config.monitor.game_gain,
		),
		(
			"Comms",
			config.cables.comms.as_str(),
			config.monitor.comms_gain,
		),
		(
			"Music",
			config.cables.music.as_str(),
			config.monitor.music_gain,
		),
	] {
		let cable = resolve_named_device(&host, Direction::Input, selector)?;
		streams.extend(build_stereo_route(
			label,
			&cable,
			&monitor_outputs,
			config.monitor.latency_ms,
			gain,
			failed.clone(),
		)?);
	}

	let clean_mic_output = resolve_named_device(&host, Direction::Output, &config.cables.clean_mic)?;
	let (mic_input, mic_output, worker_stop, worker) =
		build_clean_mic_route(&physical_input, &clean_mic_output, config, failed.clone())?;
	streams.push(mic_input);
	streams.push(mic_output);

	for stream in &streams {
		stream
			.play()
			.context("could not start an AudioArray stream")?;
	}

	Ok(RunningGraph {
		_streams: streams,
		failed,
		worker_stop,
		worker: Some(worker),
		input_name,
		output_name,
	})
}

fn build_stereo_route(
	label: &'static str,
	input: &Device,
	outputs: &[Device],
	latency_ms: u32,
	gain: f32,
	failed: Arc<AtomicBool>,
) -> Result<Vec<Stream>> {
	let input_supported = preferred_config(input, Direction::Input, false)?;
	let input_config: StreamConfig = input_supported.clone().into();
	let input_rate = input_config.sample_rate.0;
	let queue_frames = (input_rate as usize * latency_ms as usize / 1_000).max(480);
	let queues = outputs
		.iter()
		.map(|_| {
			let queue = Arc::new(ArrayQueue::new(queue_frames * 8));
			for _ in 0..queue_frames {
				let _ = queue.push(0.0);
				let _ = queue.push(0.0);
			}
			queue
		})
		.collect::<Vec<_>>();
	let mut streams = vec![build_stereo_input(
		input,
		&input_config,
		input_supported.sample_format(),
		queues.clone(),
		gain,
		label,
		failed.clone(),
	)?];
	for (output, queue) in outputs.iter().zip(queues) {
		let output_supported = preferred_config(output, Direction::Output, true)?;
		let output_config: StreamConfig = output_supported.clone().into();
		let output_rate = output_config.sample_rate.0;
		streams.push(build_stereo_output(
			output,
			&output_config,
			output_supported.sample_format(),
			queue,
			queue_frames,
			input_rate as f64 / output_rate as f64,
			label,
			failed.clone(),
		)?);
	}
	Ok(streams)
}

fn build_clean_mic_route(
	input: &Device,
	output: &Device,
	config: &Config,
	failed: Arc<AtomicBool>,
) -> Result<(Stream, Stream, Arc<AtomicBool>, thread::JoinHandle<()>)> {
	let input_supported = preferred_config(input, Direction::Input, true)?;
	let output_supported = preferred_config(output, Direction::Output, false)?;
	let input_config: StreamConfig = input_supported.clone().into();
	let output_config: StreamConfig = output_supported.clone().into();
	let latency_frames =
		(SAMPLE_RATE as usize * config.microphone.latency_ms as usize / 1_000).max(960);
	let raw = Arc::new(ArrayQueue::new(SAMPLE_RATE as usize));
	let clean = Arc::new(ArrayQueue::new(SAMPLE_RATE as usize));

	let input_stream = build_mono_input(
		input,
		&input_config,
		input_supported.sample_format(),
		raw.clone(),
		config.microphone.gain,
		input_config.sample_rate.0,
		failed.clone(),
	)?;
	let output_stream = build_mono_output(
		output,
		&output_config,
		output_supported.sample_format(),
		clean.clone(),
		latency_frames,
		failed.clone(),
	)?;

	let worker_stop = Arc::new(AtomicBool::new(false));
	let thread_stop = worker_stop.clone();
	let thread_failed = failed;
	let suppression = config.noise_suppression.clone();
	let worker = thread::Builder::new()
		.name("audioarray-deepfilternet".into())
		.spawn(move || {
			if let Err(err) = run_suppression(raw, clean, &suppression, &thread_stop) {
				error!(%err, "Clean Mic processing stopped");
				thread_failed.store(true, Ordering::Release);
				thread_stop.store(true, Ordering::Release);
			}
		})
		.context("could not start the Clean Mic processing worker")?;

	Ok((input_stream, output_stream, worker_stop, worker))
}

fn run_suppression(
	raw: Arc<ArrayQueue<f32>>,
	clean: Arc<ArrayQueue<f32>>,
	config: &crate::NoiseSuppressionConfig,
	stop: &AtomicBool,
) -> Result<()> {
	if !config.enabled {
		while !stop.load(Ordering::Acquire) {
			if let Some(sample) = raw.pop() {
				push_latest(&clean, sample);
			} else {
				thread::sleep(Duration::from_millis(1));
			}
		}
		return Ok(());
	}

	let runtime = RuntimeParams::default_with_ch(1)
		.with_atten_lim(config.attenuation_limit_db)
		.with_post_filter(config.post_filter_beta);
	let mut model = DfTract::new(DfParams::default(), &runtime)
		.context("could not initialize the embedded DeepFilterNet3 model")?;
	if model.sr != SAMPLE_RATE as usize {
		bail!(
			"DeepFilterNet requires {} Hz but AudioArray is fixed at {SAMPLE_RATE} Hz",
			model.sr
		);
	}
	let mut input_frame = Array2::zeros((1, model.hop_size));
	let mut output_frame = Array2::zeros((1, model.hop_size));
	model
		.process(input_frame.view(), output_frame.view_mut())
		.context("could not warm up DeepFilterNet3")?;
	for _ in 0..(model.fft_size - model.hop_size + model.lookahead * model.hop_size) {
		push_latest(&clean, 0.0);
	}
	info!(
		hop = model.hop_size,
		lookahead = model.lookahead,
		"DeepFilterNet3 Clean Mic worker ready"
	);

	while !stop.load(Ordering::Acquire) {
		if raw.len() < model.hop_size {
			thread::sleep(Duration::from_millis(1));
			continue;
		}
		for sample in input_frame.iter_mut() {
			*sample = raw.pop().unwrap_or(0.0);
		}
		model
			.process(input_frame.view(), output_frame.view_mut())
			.context("DeepFilterNet3 inference failed")?;
		for &sample in output_frame.iter() {
			push_latest(&clean, sample);
		}
	}
	Ok(())
}

fn preferred_config(
	device: &Device,
	direction: Direction,
	allow_native_rate: bool,
) -> Result<SupportedStreamConfig> {
	let configs: Vec<_> = match direction {
		Direction::Input => device.supported_input_configs()?.collect(),
		Direction::Output => device.supported_output_configs()?.collect(),
	};
	configs
		.into_iter()
		.filter(|range| {
			matches!(
				range.sample_format(),
				SampleFormat::F32 | SampleFormat::I16 | SampleFormat::U16
			) && (allow_native_rate
				|| (range.min_sample_rate().0 <= SAMPLE_RATE
					&& range.max_sample_rate().0 >= SAMPLE_RATE))
		})
		.min_by_key(|range| {
			let selected_rate =
				SAMPLE_RATE.clamp(range.min_sample_rate().0, range.max_sample_rate().0);
			let rate_score = selected_rate.abs_diff(SAMPLE_RATE);
			let format_score = if range.sample_format() == SampleFormat::F32 {
				0
			} else {
				1
			};
			let channel_score = range.channels().abs_diff(2) as u32;
			(rate_score, format_score, channel_score)
		})
		.map(|range| {
			let selected_rate =
				SAMPLE_RATE.clamp(range.min_sample_rate().0, range.max_sample_rate().0);
			range.with_sample_rate(SampleRate(selected_rate))
		})
		.ok_or_else(|| {
			let requirement = if allow_native_rate {
				"a supported shared-mode format".to_string()
			} else {
				format!("a {SAMPLE_RATE} Hz shared-mode format")
			};
			anyhow!("{} has no {requirement}", device.name().unwrap_or_default())
		})
}

fn resolve_physical_device(
	host: &cpal::Host,
	direction: Direction,
	selector: &str,
) -> Result<Device> {
	let device = if selector.eq_ignore_ascii_case("default") {
		match direction {
			Direction::Input => host.default_input_device(),
			Direction::Output => host.default_output_device(),
		}
		.ok_or_else(|| {
			anyhow!(
				"Windows has no default {} endpoint",
				direction_name(direction)
			)
		})?
	} else {
		resolve_named_device(host, direction, selector)?
	};
	let name = device.name()?;
	if is_non_physical_endpoint_name(&name) {
		bail!("refusing to use routing or remote endpoint {name:?} as a physical endpoint; this would create a feedback loop or bind AudioArray to a temporary session device");
	}
	Ok(device)
}

fn resolve_microphone_device(host: &cpal::Host, config: &Config) -> Result<Device> {
	if config
		.microphone
		.input
		.eq_ignore_ascii_case(config.microphone.vr_input.trim())
	{
		resolve_named_device(host, Direction::Input, &config.microphone.input)
	} else {
		resolve_physical_device(host, Direction::Input, &config.microphone.input)
	}
}

fn first_active_endpoint_name(direction: Direction, history: &[SavedEndpoint]) -> Result<String> {
	let _ = wasapi::initialize_mta();
	let wasapi_direction = match direction {
		Direction::Input => WasapiDirection::Capture,
		Direction::Output => WasapiDirection::Render,
	};
	let enumerator =
		DeviceEnumerator::new().context("could not enumerate active Windows audio endpoints")?;
	let collection = enumerator
		.get_device_collection(&wasapi_direction)
		.context("could not collect active Windows audio endpoints")?;
	let mut active = Vec::new();
	for device in &collection {
		let device = device.context("could not inspect an active Windows audio endpoint")?;
		active.push(SavedEndpoint {
			id: device.get_id()?,
			name: device.get_friendlyname()?,
		});
	}
	for saved in history {
		if let Some(endpoint) = active.iter().find(|endpoint| {
			endpoint.id == saved.id || endpoint.name.eq_ignore_ascii_case(&saved.name)
		}) {
			return Ok(endpoint.name.clone());
		}
	}
	let remembered = if history.is_empty() {
		"<none>".to_string()
	} else {
		history
			.iter()
			.map(|endpoint| endpoint.name.as_str())
			.collect::<Vec<_>>()
			.join("; ")
	};
	bail!(
		"no remembered physical {} endpoint is active (remembered: {remembered})",
		direction_name(direction),
	)
}

fn returned_preferred_endpoint(
	direction: Direction,
	history: &[SavedEndpoint],
	current: &str,
) -> Option<String> {
	let preferred = history.first()?;
	if preferred.name.eq_ignore_ascii_case(current) {
		return None;
	}
	let active = first_active_endpoint_name(direction, history).ok()?;
	(!active.eq_ignore_ascii_case(current)).then_some(active)
}

fn resolve_monitor_device(host: &cpal::Host, config: &Config) -> Result<Device> {
	if [&config.monitor.remote_output, &config.monitor.vr_output]
		.iter()
		.any(|temporary| config.monitor.output.eq_ignore_ascii_case(temporary))
	{
		resolve_named_device(host, Direction::Output, &config.monitor.output)
	} else {
		resolve_physical_device(host, Direction::Output, &config.monitor.output)
	}
}

fn is_non_physical_endpoint_name(name: &str) -> bool {
	let name = name.to_ascii_lowercase();
	[
		"virtual audio cable",
		"audioarray",
		"steam streaming",
		"oculus virtual audio",
		"sunshine",
		"remote audio",
		"virtual desktop audio",
	]
	.iter()
	.any(|marker| name.contains(marker))
}

fn is_quest_endpoint_name(name: &str) -> bool {
	name.to_ascii_lowercase().contains("oculus virtual audio")
}

fn resolve_named_device(host: &cpal::Host, direction: Direction, selector: &str) -> Result<Device> {
	let selector = selector.trim().to_ascii_lowercase();
	let devices: Vec<_> = match direction {
		Direction::Input => host.input_devices()?.collect(),
		Direction::Output => host.output_devices()?.collect(),
	};
	if let Some(exact) = devices.iter().find(|device| {
		device
			.name()
			.map(|name| name.eq_ignore_ascii_case(&selector))
			.unwrap_or(false)
	}) {
		return Ok(exact.clone());
	}
	let matches: Vec<_> = devices
		.into_iter()
		.filter(|device| {
			device
				.name()
				.map(|name| name.to_ascii_lowercase().contains(&selector))
				.unwrap_or(false)
		})
		.collect();
	match matches.len() {
		0 => bail!(
			"no {} endpoint contains {selector:?}",
			direction_name(direction)
		),
		1 => Ok(matches.into_iter().next().unwrap()),
		_ => {
			let names = matches
				.iter()
				.filter_map(|device| device.name().ok())
				.collect::<Vec<_>>()
				.join(", ");
			bail!(
				"{} endpoint selector {selector:?} is ambiguous: {names}",
				direction_name(direction)
			)
		}
	}
}

fn device_name(device: Option<&Device>) -> Option<String> {
	device.and_then(|device| device.name().ok())
}

fn direction_name(direction: Direction) -> &'static str {
	match direction {
		Direction::Input => "input",
		Direction::Output => "output",
	}
}

fn push_latest(queue: &ArrayQueue<f32>, sample: f32) {
	if queue.push(sample).is_err() {
		let _ = queue.pop();
		let _ = queue.push(sample);
	}
}

fn stream_error(
	label: &'static str,
	failed: Arc<AtomicBool>,
) -> impl FnMut(cpal::StreamError) + Send + 'static {
	move |err| {
		error!(route = label, %err, "audio stream failed");
		failed.store(true, Ordering::Release);
	}
}

fn build_stereo_input(
	device: &Device,
	config: &StreamConfig,
	format: SampleFormat,
	queues: Vec<Arc<ArrayQueue<f32>>>,
	gain: f32,
	label: &'static str,
	failed: Arc<AtomicBool>,
) -> Result<Stream> {
	macro_rules! build {
		($sample:ty) => {{
			let queues = queues.clone();
			let channels = config.channels as usize;
			device.build_input_stream(
				config,
				move |data: &[$sample], _| {
					for frame in data.chunks(channels) {
						let left = f32::from_sample(frame[0]) * gain;
						let right = f32::from_sample(*frame.get(1).unwrap_or(&frame[0])) * gain;
						for queue in &queues {
							push_latest(queue, left);
							push_latest(queue, right);
						}
					}
				},
				stream_error(label, failed.clone()),
				None,
			)?
		}};
	}
	Ok(match format {
		SampleFormat::F32 => build!(f32),
		SampleFormat::I16 => build!(i16),
		SampleFormat::U16 => build!(u16),
		other => bail!("unsupported input sample format {other}"),
	})
}

fn build_mono_input(
	device: &Device,
	config: &StreamConfig,
	format: SampleFormat,
	queue: Arc<ArrayQueue<f32>>,
	gain: f32,
	input_rate: u32,
	failed: Arc<AtomicBool>,
) -> Result<Stream> {
	macro_rules! build {
		($sample:ty) => {{
			let queue = queue.clone();
			let channels = config.channels as usize;
			let mut resampler = MonoInputResampler::new(input_rate, SAMPLE_RATE);
			device.build_input_stream(
				config,
				move |data: &[$sample], _| {
					for frame in data.chunks(channels) {
						let sum: f32 = frame.iter().copied().map(f32::from_sample).sum();
						resampler.push(sum / frame.len() as f32 * gain, &queue);
					}
				},
				stream_error("Clean Mic input", failed.clone()),
				None,
			)?
		}};
	}
	Ok(match format {
		SampleFormat::F32 => build!(f32),
		SampleFormat::I16 => build!(i16),
		SampleFormat::U16 => build!(u16),
		other => bail!("unsupported microphone sample format {other}"),
	})
}

struct MonoInputResampler {
	previous: Option<f32>,
	next_output_offset: f64,
	source_frames_per_output: f64,
}

impl MonoInputResampler {
	fn new(input_rate: u32, output_rate: u32) -> Self {
		Self {
			previous: None,
			next_output_offset: 0.0,
			source_frames_per_output: input_rate as f64 / output_rate as f64,
		}
	}

	fn push(&mut self, current: f32, queue: &ArrayQueue<f32>) {
		let Some(previous) = self.previous.replace(current) else {
			return;
		};
		while self.next_output_offset < 1.0 {
			let phase = self.next_output_offset as f32;
			push_latest(queue, previous + (current - previous) * phase);
			self.next_output_offset += self.source_frames_per_output;
		}
		self.next_output_offset -= 1.0;
	}
}

struct StereoReader {
	queue: Arc<ArrayQueue<f32>>,
	target_frames: usize,
	previous: (f32, f32),
	next: (f32, f32),
	phase: f32,
	source_frames_per_output: f64,
	started: bool,
}

impl StereoReader {
	fn next(&mut self) -> (f32, f32) {
		if !self.started {
			if self.queue.len() < self.target_frames * 2 + 4 {
				return (0.0, 0.0);
			}
			self.previous = self.pop_frame().unwrap_or_default();
			self.next = self.pop_frame().unwrap_or(self.previous);
			self.phase = 0.0;
			self.started = true;
		}
		let output = (
			self.previous.0 + (self.next.0 - self.previous.0) * self.phase,
			self.previous.1 + (self.next.1 - self.previous.1) * self.phase,
		);
		let fill_frames = self.queue.len() as f32 / 2.0;
		let fill_error = (fill_frames - self.target_frames as f32) / self.target_frames as f32;
		let ratio = 1.0 + (fill_error * 0.002).clamp(-0.003, 0.003);
		self.phase += (self.source_frames_per_output * ratio as f64) as f32;
		while self.phase >= 1.0 {
			self.phase -= 1.0;
			self.previous = self.next;
			if let Some(next) = self.pop_frame() {
				self.next = next;
			} else {
				self.started = false;
				return (0.0, 0.0);
			}
		}
		output
	}

	fn pop_frame(&self) -> Option<(f32, f32)> {
		Some((self.queue.pop()?, self.queue.pop()?))
	}
}

struct MonoReader {
	queue: Arc<ArrayQueue<f32>>,
	target_samples: usize,
	previous: f32,
	next: f32,
	phase: f32,
	started: bool,
}

impl MonoReader {
	fn next(&mut self) -> f32 {
		if !self.started {
			if self.queue.len() < self.target_samples {
				return 0.0;
			}
			self.previous = self.queue.pop().unwrap_or_default();
			self.next = self.queue.pop().unwrap_or(self.previous);
			self.phase = 0.0;
			self.started = true;
		}
		let output = self.previous + (self.next - self.previous) * self.phase;
		let fill_error =
			(self.queue.len() as f32 - self.target_samples as f32) / self.target_samples as f32;
		let ratio = 1.0 + (fill_error * 0.002).clamp(-0.003, 0.003);
		self.phase += ratio;
		while self.phase >= 1.0 {
			self.phase -= 1.0;
			self.previous = self.next;
			if let Some(next) = self.queue.pop() {
				self.next = next;
			} else {
				self.started = false;
				return 0.0;
			}
		}
		output
	}
}

fn build_stereo_output(
	device: &Device,
	config: &StreamConfig,
	format: SampleFormat,
	queue: Arc<ArrayQueue<f32>>,
	target_frames: usize,
	source_frames_per_output: f64,
	label: &'static str,
	failed: Arc<AtomicBool>,
) -> Result<Stream> {
	macro_rules! build {
		($sample:ty) => {{
			let channels = config.channels as usize;
			let mut reader = StereoReader {
				queue: queue.clone(),
				target_frames,
				previous: (0.0, 0.0),
				next: (0.0, 0.0),
				phase: 0.0,
				source_frames_per_output,
				started: false,
			};
			device.build_output_stream(
				config,
				move |data: &mut [$sample], _| {
					for frame in data.chunks_mut(channels) {
						let (left, right) = reader.next();
						for (channel, sample) in frame.iter_mut().enumerate() {
							let value = if channel % 2 == 0 { left } else { right };
							*sample = <$sample>::from_sample(value);
						}
					}
				},
				stream_error(label, failed.clone()),
				None,
			)?
		}};
	}
	Ok(match format {
		SampleFormat::F32 => build!(f32),
		SampleFormat::I16 => build!(i16),
		SampleFormat::U16 => build!(u16),
		other => bail!("unsupported output sample format {other}"),
	})
}

fn build_mono_output(
	device: &Device,
	config: &StreamConfig,
	format: SampleFormat,
	queue: Arc<ArrayQueue<f32>>,
	target_frames: usize,
	failed: Arc<AtomicBool>,
) -> Result<Stream> {
	macro_rules! build {
		($sample:ty) => {{
			let channels = config.channels as usize;
			let mut reader = MonoReader {
				queue: queue.clone(),
				target_samples: target_frames,
				previous: 0.0,
				next: 0.0,
				phase: 0.0,
				started: false,
			};
			device.build_output_stream(
				config,
				move |data: &mut [$sample], _| {
					for frame in data.chunks_mut(channels) {
						let value = <$sample>::from_sample(reader.next());
						frame.fill(value);
					}
				},
				stream_error("Clean Mic output", failed.clone()),
				None,
			)?
		}};
	}
	Ok(match format {
		SampleFormat::F32 => build!(f32),
		SampleFormat::I16 => build!(i16),
		SampleFormat::U16 => build!(u16),
		other => bail!("unsupported Clean Mic output sample format {other}"),
	})
}
