use std::{
	collections::VecDeque,
	fs,
	mem::size_of,
	net::UdpSocket,
	path::{Path, PathBuf},
	sync::{
		atomic::{AtomicBool, AtomicU32, Ordering},
		Arc,
	},
	thread,
	time::{Duration, Instant, SystemTime},
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
	app_routing::{
		ensure_capture_endpoint_ready, ensure_capture_endpoint_selector_ready, process_is_running,
		AppRouter, GlobalAudioDefaults,
	},
	master_volume::MasterVolumeBridge,
	nvidia_afx::NvidiaAfx,
	patch_destinations, patch_sources, BusSummary, Config, EndpointSummary, GraphSnapshot,
	MeterReading, PatchConnection, SuppressionBackend, SuppressionTransition,
};

const SAMPLE_RATE: u32 = 48_000;
const WAVEFORM_BINS: usize = 96;
const WAVEFORM_SAMPLES: usize = WAVEFORM_BINS * 2;
const WAVEFORM_WINDOW_MS: usize = 240;
const PROCESSED_MIC_TELEMETRY_ADDRESS: &str = "127.0.0.1:47847";
const PROCESSED_MIC_TELEMETRY_MAGIC: &[u8; 4] = b"AAMP";
const PROCESSED_MIC_TELEMETRY_VERSION: u32 = 1;
const PROCESSED_MIC_TELEMETRY_HEADER_BYTES: usize = 16;
const PROCESSED_MIC_TELEMETRY_PACKET_BYTES: usize =
	PROCESSED_MIC_TELEMETRY_HEADER_BYTES + WAVEFORM_SAMPLES * size_of::<f32>();
const PROCESSED_MIC_TELEMETRY_INTERVAL_SAMPLES: usize = SAMPLE_RATE as usize / 30;
const PROCESSED_MIC_TELEMETRY_STALE_AFTER: Duration = Duration::from_millis(250);

const ENDPOINT_HISTORY_LIMIT: usize = 8;
const PREFERRED_ENDPOINT_RECHECK_INTERVAL: Duration = Duration::from_secs(2);
const NVIDIA_AFX_LABEL: &str = "NVIDIA AFX (RTX)";
const DEEPFILTER_LABEL: &str = "DeepFilterNet3";

#[derive(Debug, Deserialize, Serialize)]
struct ActiveSuppressionStatus {
	engine: String,
}

enum SuppressionProcessor {
	Nvidia(NvidiaAfx),
	DeepFilter {
		model: Box<DfTract>,
		input: Array2<f32>,
		output: Array2<f32>,
	},
}

impl SuppressionProcessor {
	fn new(config: &crate::NoiseSuppressionConfig) -> Result<Self> {
		match config.engine.as_str() {
			"nvidia_afx" => Self::nvidia(config),
			"deepfilternet3" => Self::deep_filter(config),
			other => bail!("unsupported suppression engine {other:?}"),
		}
	}

	fn nvidia(config: &crate::NoiseSuppressionConfig) -> Result<Self> {
		let processor = NvidiaAfx::new(crate::suppression_intensity(config))?;
		Ok(Self::Nvidia(processor))
	}

	fn deep_filter(config: &crate::NoiseSuppressionConfig) -> Result<Self> {
		let runtime = RuntimeParams::default_with_ch(1)
			.with_atten_lim(config.attenuation_limit_db)
			.with_post_filter(config.post_filter_beta);
		let mut model = Box::new(
			DfTract::new(DfParams::default(), &runtime)
				.context("could not initialize the embedded DeepFilterNet3 model")?,
		);
		if model.sr != SAMPLE_RATE as usize {
			bail!(
				"DeepFilterNet requires {} Hz but AMPS is fixed at {SAMPLE_RATE} Hz",
				model.sr
			);
		}
		let input = Array2::zeros((1, model.hop_size));
		let mut output = Array2::zeros((1, model.hop_size));
		model
			.process(input.view(), output.view_mut())
			.context("could not warm up DeepFilterNet3")?;
		Ok(Self::DeepFilter {
			model,
			input,
			output,
		})
	}

	fn label(&self) -> &'static str {
		match self {
			Self::Nvidia(_) => NVIDIA_AFX_LABEL,
			Self::DeepFilter { .. } => DEEPFILTER_LABEL,
		}
	}

	fn frame_samples(&self) -> usize {
		match self {
			Self::Nvidia(processor) => processor.frame_samples(),
			Self::DeepFilter { model, .. } => model.hop_size,
		}
	}

	fn backend(&self) -> SuppressionBackend {
		match self {
			Self::Nvidia(_) => SuppressionBackend::Nvidia,
			Self::DeepFilter { .. } => SuppressionBackend::DeepFilter,
		}
	}

	fn update_parameters(&mut self, config: &crate::NoiseSuppressionConfig) -> Result<()> {
		match self {
			Self::Nvidia(_) => {
				bail!("NVIDIA AFX parameter changes require a Clean Mic processor rebuild")
			}
			Self::DeepFilter { model, .. } => {
				model.set_atten_lim(config.attenuation_limit_db);
				model.set_pf_beta(config.post_filter_beta);
				Ok(())
			}
		}
	}

	fn startup_silence(&self) -> usize {
		match self {
			Self::Nvidia(_) => 0,
			Self::DeepFilter { model, .. } => {
				model.fft_size - model.hop_size + model.lookahead * model.hop_size
			}
		}
	}

	fn process(&mut self, input_frame: &[f32], output_frame: &mut [f32]) -> Result<()> {
		match self {
			Self::Nvidia(processor) => processor.process(input_frame, output_frame),
			Self::DeepFilter {
				model,
				input,
				output,
			} => {
				for (destination, source) in input.iter_mut().zip(input_frame) {
					*destination = *source;
				}
				model
					.process(input.view(), output.view_mut())
					.context("DeepFilterNet3 inference failed")?;
				for (destination, source) in output_frame.iter_mut().zip(output.iter()) {
					*destination = *source;
				}
				Ok(())
			}
		}
	}
}

#[derive(Clone, Copy)]
enum Direction {
	Input,
	Output,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct SavedEndpoint {
	id: String,
	name: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
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
	master_volume: Option<MasterVolumeBridge>,
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
				"AMPS has no remembered physical input/output. Stop AMPS, select physical Windows defaults, then start it again"
			);
		}
		let active_input = first_active_endpoint(Direction::Input, state.history(Direction::Input))?;
		ensure_capture_endpoint_ready(&active_input.id)?;
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
			master_volume: None,
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
		let mut persisted_state = load_physical_state(&self.state_path)?;
		let migrated = persisted_state.migrate_legacy();
		let mut changed = persisted_state != self.state;
		if changed {
			info!("adopted an explicit AMPS physical endpoint selection");
			self.state = persisted_state;
		}
		if migrated {
			save_physical_state(&self.state_path, &self.state)?;
		}
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
				if matches!(direction, Direction::Input) {
					ensure_capture_endpoint_ready(&endpoint.id).with_context(|| {
						format!(
							"could not make selected physical {label} {:?} usable",
							endpoint.name
						)
					})?;
				}
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

	fn begin_graph_rebuild(&mut self, config: &Config, effective: &Config) -> Result<()> {
		if let Some(bridge) = &mut self.master_volume {
			bridge.retarget(&effective.monitor.output)?;
		} else {
			self.master_volume = Some(MasterVolumeBridge::new(
				&config.cables.game,
				&effective.monitor.output,
			)?);
		}
		self
			.master_volume
			.as_ref()
			.expect("master-volume bridge was initialized")
			.begin_graph_rebuild()
	}

	fn finish_graph_rebuild(&self) -> Result<()> {
		self
			.master_volume
			.as_ref()
			.ok_or_else(|| anyhow!("master-volume bridge is unavailable"))?
			.finish_graph_rebuild()
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
	patch_stop: Arc<AtomicBool>,
	patch_worker: Option<thread::JoinHandle<()>>,
	input_name: String,
	output_name: String,
}

impl Drop for RunningGraph {
	fn drop(&mut self) {
		self.worker_stop.store(true, Ordering::Release);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
		self.patch_stop.store(true, Ordering::Release);
		if let Some(worker) = self.patch_worker.take() {
			let _ = worker.join();
		}
	}
}

struct ActiveSuppressionGuard;

impl Drop for ActiveSuppressionGuard {
	fn drop(&mut self) {
		clear_active_suppression();
	}
}

fn active_suppression_path() -> Option<PathBuf> {
	std::env::var_os("LOCALAPPDATA")
		.map(PathBuf::from)
		.map(|root| root.join("AMPS").join("active-suppression.toml"))
}

fn publish_active_suppression(engine: &str) {
	let Some(path) = active_suppression_path() else {
		warn!("LOCALAPPDATA is unavailable; suppression status cannot be published");
		return;
	};
	let result = (|| -> Result<()> {
		if let Some(parent) = path.parent() {
			fs::create_dir_all(parent)?;
		}
		let status = ActiveSuppressionStatus {
			engine: engine.to_string(),
		};
		fs::write(&path, toml::to_string_pretty(&status)?)?;
		Ok(())
	})();
	if let Err(error) = result {
		warn!(%error, path = %path.display(), "could not publish active suppression backend");
	}
}

fn clear_active_suppression() {
	let Some(path) = active_suppression_path() else {
		return;
	};
	if let Err(error) = fs::remove_file(&path) {
		if error.kind() != std::io::ErrorKind::NotFound {
			warn!(%error, path = %path.display(), "could not clear active suppression backend");
		}
	}
}

fn read_active_suppression() -> Option<String> {
	let path = active_suppression_path()?;
	let text = fs::read_to_string(path).ok()?;
	toml::from_str::<ActiveSuppressionStatus>(&text)
		.ok()
		.map(|status| status.engine)
}

fn configured_suppression_label(engine: &str) -> &'static str {
	match engine {
		"nvidia_afx" => NVIDIA_AFX_LABEL,
		"deepfilternet3" => DEEPFILTER_LABEL,
		_ => "Unknown",
	}
}

fn physical_state_path() -> Result<PathBuf> {
	let app_data = std::env::var_os("APPDATA")
		.ok_or_else(|| anyhow!("APPDATA is unavailable; cannot persist physical audio selections"))?;
	Ok(PathBuf::from(app_data)
		.join("AMPS")
		.join("physical-endpoints.toml"))
}

fn temporary_output_for_session(config: &Config) -> Result<Option<String>> {
	// OculusDash exists only while a Link/Air Link session is presenting the
	// Quest runtime. Detect it directly so Meta can be configured to preserve
	// Windows defaults and never let applications bypass AMPS's buses.
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

pub(crate) fn remember_selected_physical_output(selector: &str) -> Result<()> {
	remember_selected_physical_endpoint(Direction::Output, selector)
}

pub(crate) fn remember_selected_physical_input(selector: &str) -> Result<()> {
	remember_selected_physical_endpoint(Direction::Input, selector)
}

fn remember_selected_physical_endpoint(direction: Direction, selector: &str) -> Result<()> {
	let wasapi_direction = match direction {
		Direction::Input => WasapiDirection::Capture,
		Direction::Output => WasapiDirection::Render,
	};
	let endpoint = resolve_endpoint(wasapi_direction, selector)?;
	if is_non_physical_endpoint_name(&endpoint.name) {
		return Ok(());
	}
	if matches!(direction, Direction::Input) {
		ensure_capture_endpoint_ready(&endpoint.id)?;
	}
	let path = physical_state_path()?;
	let mut state = load_physical_state(&path)?;
	let changed = state.migrate_legacy() | state.remember(direction, endpoint.clone());
	if changed {
		save_physical_state(&path, &state)?;
		info!(
			physical_endpoint = %endpoint.name,
			direction = direction_name(direction),
			"persisted an explicit AMPS physical endpoint selection"
		);
	}
	Ok(())
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
	println!("AMPS graph is ready.");
	println!("  Physical input:  {}", input.name()?);
	println!("  Physical output: {}", output.name()?);
	println!("  Moonlight output: {}", remote_output.name()?);
	println!("  VR output:        {}", vr_output.name()?);
	println!("  VR input:         {}", vr_input.name()?);
	println!(
		"  Suppression:     {}",
		if config.noise_suppression.enabled {
			configured_suppression_label(&config.noise_suppression.engine)
		} else {
			"disabled"
		}
	);
	if config.noise_suppression.enabled {
		println!(
			"  NVIDIA runtime: {}",
			if crate::nvidia_afx::runtime_available() {
				"available"
			} else {
				"unavailable"
			}
		);
	}
	Ok(())
}

pub(crate) fn benchmark(config: &Config, seconds: u32) -> Result<()> {
	if seconds == 0 || seconds > 300 {
		bail!("benchmark duration must be between 1 and 300 seconds");
	}
	let mut processor = SuppressionProcessor::new(&config.noise_suppression)?;
	let frame_samples = processor.frame_samples();
	let mut input = vec![0.0_f32; frame_samples];
	let mut output = vec![0.0_f32; frame_samples];
	processor.process(&input, &mut output)?;
	let frame_count = seconds as usize * SAMPLE_RATE as usize / frame_samples;
	let mut phase = 0.0_f32;
	let mut random = 0x9e37_79b9_u32;
	let started = Instant::now();
	for _ in 0..frame_count {
		for sample in &mut input {
			random ^= random << 13;
			random ^= random >> 17;
			random ^= random << 5;
			let noise = (random as f32 / u32::MAX as f32 - 0.5) * 0.04;
			*sample = phase.sin() * 0.12 + noise;
			phase += std::f32::consts::TAU * 180.0 / SAMPLE_RATE as f32;
		}
		processor.process(&input, &mut output)?;
	}
	let elapsed = started.elapsed();
	let realtime = Duration::from_secs(seconds as u64);
	println!(
		"{} processed {seconds}s of noisy audio in {:.3}s.",
		processor.label(),
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
			"Comms Audio",
			resolve_named_device(&host, Direction::Input, &config.cables.comms)?,
		),
		(
			"Media",
			resolve_named_device(&host, Direction::Input, &config.cables.music)?,
		),
		(
			"AI Audio",
			resolve_named_device(&host, Direction::Input, &config.cables.chatgpt)?,
		),
		(
			"AI Mic",
			resolve_named_device(&host, Direction::Input, &config.cables.chatgpt_in)?,
		),
		(
			"Comms Mic",
			resolve_named_device(&host, Direction::Input, &config.cables.comms_send)?,
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
	let engine_online = process_is_running("amps.exe")?;
	let suppression = if config.noise_suppression.enabled {
		if engine_online {
			read_active_suppression().unwrap_or_else(|| {
				configured_suppression_label(&config.noise_suppression.engine).to_string()
			})
		} else {
			configured_suppression_label(&config.noise_suppression.engine).to_string()
		}
	} else {
		"Bypassed".to_string()
	};

	Ok(GraphSnapshot {
		platform: "windows",
		engine_online,
		routing_ready,
		sample_rate: SAMPLE_RATE,
		suppression,
		suppression_engine: config.noise_suppression.engine.clone(),
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
				purpose: "Incoming voice communications",
				spatial: None,
			},
			BusSummary {
				id: "music",
				name: config.cables.music.clone(),
				purpose: "Music, shows, and movies",
				spatial: Some("Dolby Atmos for Headphones"),
			},
			BusSummary {
				id: "chatgpt",
				name: config.cables.chatgpt.clone(),
				purpose: "ChatGPT / Codex playback only",
				spatial: None,
			},
			BusSummary {
				id: "clean-mic",
				name: config.cables.clean_mic.clone(),
				purpose: "Suppressed microphone",
				spatial: None,
			},
			BusSummary {
				id: "chatgpt-in",
				name: config.cables.chatgpt_in.clone(),
				purpose: "Filtered mic + received communications; no AI return",
				spatial: None,
			},
			BusSummary {
				id: "comms-send",
				name: config.cables.comms_send.clone(),
				purpose: "Filtered mic + AI Audio; no communications self-return",
				spatial: None,
			},
		],
		patch_sources: patch_sources(),
		patch_destinations: patch_destinations(),
		patches: config.patchbay.connections.clone(),
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

struct ProcessedMicPublisher {
	socket: UdpSocket,
	history: VecDeque<f32>,
	history_limit: usize,
	samples_since_publish: usize,
	peak_since_publish: f32,
	warned: bool,
}

impl ProcessedMicPublisher {
	fn new() -> Option<Self> {
		match UdpSocket::bind("127.0.0.1:0") {
			Ok(socket) => Some(Self {
				socket,
				history: VecDeque::with_capacity(SAMPLE_RATE as usize * WAVEFORM_WINDOW_MS / 1_000),
				history_limit: SAMPLE_RATE as usize * WAVEFORM_WINDOW_MS / 1_000,
				samples_since_publish: 0,
				peak_since_publish: 0.0,
				warned: false,
			}),
			Err(error) => {
				warn!(%error, "could not create the processed-microphone telemetry publisher");
				None
			}
		}
	}

	fn push(&mut self, samples: &[f32]) {
		for &sample in samples {
			let sample = if sample.is_finite() {
				sample.clamp(-1.0, 1.0)
			} else {
				0.0
			};
			self.history.push_back(sample);
			self.peak_since_publish = self.peak_since_publish.max(sample.abs());
		}
		while self.history.len() > self.history_limit {
			self.history.pop_front();
		}
		self.samples_since_publish += samples.len();
		if self.samples_since_publish < PROCESSED_MIC_TELEMETRY_INTERVAL_SAMPLES {
			return;
		}
		self.samples_since_publish %= PROCESSED_MIC_TELEMETRY_INTERVAL_SAMPLES;
		let waveform = waveform_from_history(&self.history);
		let mut packet = Vec::with_capacity(PROCESSED_MIC_TELEMETRY_PACKET_BYTES);
		packet.extend_from_slice(PROCESSED_MIC_TELEMETRY_MAGIC);
		packet.extend_from_slice(&PROCESSED_MIC_TELEMETRY_VERSION.to_le_bytes());
		packet.extend_from_slice(&self.peak_since_publish.to_le_bytes());
		packet.extend_from_slice(&(WAVEFORM_SAMPLES as u32).to_le_bytes());
		for sample in waveform {
			packet.extend_from_slice(&sample.to_le_bytes());
		}
		self.peak_since_publish = 0.0;
		if let Err(error) = self
			.socket
			.send_to(&packet, PROCESSED_MIC_TELEMETRY_ADDRESS)
		{
			if !self.warned {
				warn!(%error, "could not publish processed-microphone telemetry");
				self.warned = true;
			}
		} else {
			self.warned = false;
		}
	}
}

struct ProcessedMicReceiver {
	socket: UdpSocket,
	latest: MeterReading,
	last_received: Option<Instant>,
	warned: bool,
}

impl ProcessedMicReceiver {
	fn bind() -> Option<Self> {
		let socket = match UdpSocket::bind(PROCESSED_MIC_TELEMETRY_ADDRESS) {
			Ok(socket) => socket,
			Err(error) => {
				warn!(%error, "could not bind the processed-microphone telemetry receiver");
				return None;
			}
		};
		if let Err(error) = socket.set_nonblocking(true) {
			warn!(%error, "could not make processed-microphone telemetry nonblocking");
			return None;
		}
		Some(Self {
			socket,
			latest: silent_meter_reading("processed-mic"),
			last_received: None,
			warned: false,
		})
	}

	fn read(&mut self) -> MeterReading {
		let mut packet = [0_u8; PROCESSED_MIC_TELEMETRY_PACKET_BYTES];
		loop {
			match self.socket.recv(&mut packet) {
				Ok(size) => {
					if let Some(reading) = decode_processed_mic_packet(&packet[..size]) {
						self.latest = reading;
						self.last_received = Some(Instant::now());
						self.warned = false;
					}
				}
				Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
				Err(error) => {
					if !self.warned {
						warn!(%error, "could not receive processed-microphone telemetry");
						self.warned = true;
					}
					break;
				}
			}
		}
		if self
			.last_received
			.is_none_or(|received| received.elapsed() > PROCESSED_MIC_TELEMETRY_STALE_AFTER)
		{
			return silent_meter_reading("processed-mic");
		}
		self.latest.clone()
	}
}

fn decode_processed_mic_packet(packet: &[u8]) -> Option<MeterReading> {
	if packet.len() != PROCESSED_MIC_TELEMETRY_PACKET_BYTES
		|| packet.get(..4)? != PROCESSED_MIC_TELEMETRY_MAGIC
		|| u32::from_le_bytes(packet.get(4..8)?.try_into().ok()?) != PROCESSED_MIC_TELEMETRY_VERSION
		|| u32::from_le_bytes(packet.get(12..16)?.try_into().ok()?) as usize != WAVEFORM_SAMPLES
	{
		return None;
	}
	let peak = f32::from_le_bytes(packet.get(8..12)?.try_into().ok()?);
	let mut waveform = Vec::with_capacity(WAVEFORM_SAMPLES);
	for bytes in packet[PROCESSED_MIC_TELEMETRY_HEADER_BYTES..].chunks_exact(size_of::<f32>()) {
		let sample = f32::from_le_bytes(bytes.try_into().ok()?);
		waveform.push(if sample.is_finite() {
			sample.clamp(-1.0, 1.0)
		} else {
			0.0
		});
	}
	Some(meter_reading(
		"processed-mic",
		if peak.is_finite() { peak } else { 0.0 },
		waveform,
	))
}

fn silent_meter_reading(id: &'static str) -> MeterReading {
	meter_reading(id, 0.0, vec![0.0; WAVEFORM_SAMPLES])
}

pub(crate) struct MeterProbe {
	input_name: String,
	patches: Vec<PatchConnection>,
	signals: Vec<SignalProbe>,
	processed_mic: Option<ProcessedMicReceiver>,
	_streams: Vec<Stream>,
}

pub(crate) struct CleanMicMonitor {
	output_name: String,
	_streams: Vec<Stream>,
}

impl CleanMicMonitor {
	pub(crate) fn new(config: &Config) -> Result<Self> {
		let effective = effective_session_config(config)?;
		let host = cpal::default_host();
		let clean_mic = resolve_named_device(&host, Direction::Input, &config.cables.clean_mic)?;
		let output = resolve_monitor_device(&host, &effective)?;
		let output_name = output.name()?;
		let failed = Arc::new(AtomicBool::new(false));
		let streams = build_stereo_route(
			"Clean Mic Monitor",
			&clean_mic,
			&[output],
			config.monitor.latency_ms,
			1.0,
			failed,
		)?;
		for stream in &streams {
			stream
				.play()
				.context("could not start the temporary Clean Mic monitor")?;
		}
		Ok(Self {
			output_name,
			_streams: streams,
		})
	}

	pub(crate) fn output_name(&self) -> &str {
		&self.output_name
	}
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
				"chatgpt",
				resolve_named_device(&host, Direction::Input, &config.cables.chatgpt)?,
			),
			(
				"chatgpt-in",
				resolve_named_device(&host, Direction::Input, &config.cables.chatgpt_in)?,
			),
			(
				"comms-send",
				resolve_named_device(&host, Direction::Input, &config.cables.comms_send)?,
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
			patches: config.patchbay.connections.clone(),
			signals,
			processed_mic: ProcessedMicReceiver::bind(),
			_streams: streams,
		})
	}

	pub(crate) fn read(&mut self) -> Vec<MeterReading> {
		let mut readings = Vec::with_capacity(self.signals.len() + 3);
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
		readings.push(self.processed_mic.as_mut().map_or_else(
			|| silent_meter_reading("processed-mic"),
			ProcessedMicReceiver::read,
		));
		let monitor_peak = readings
			.iter()
			.filter(|reading| self.is_patched_to_monitor(reading.id))
			.map(|reading| reading.peak)
			.fold(0.0_f32, f32::max);
		let monitor_waveform = (0..WAVEFORM_SAMPLES)
			.map(|index| {
				readings
					.iter()
					.filter(|reading| self.is_patched_to_monitor(reading.id))
					.map(|reading| reading.waveform.get(index).copied().unwrap_or(0.0))
					.sum::<f32>()
					.clamp(-1.0, 1.0)
			})
			.collect();
		let clean_mic_peak = readings
			.iter()
			.find(|reading| reading.id == "clean-mic")
			.map_or(0.0, |reading| reading.peak);
		let complete_peak = readings
			.iter()
			.filter(|reading| matches!(reading.id, "game" | "comms" | "music" | "clean-mic"))
			.map(|reading| reading.peak)
			.fold(0.0_f32, f32::max);
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
			complete_peak.max(clean_mic_peak),
			complete_waveform,
		));
		readings
	}

	pub(crate) fn is_current(&self, config: &Config) -> Result<bool> {
		Ok(self
			.input_name
			.eq_ignore_ascii_case(&effective_session_config(config)?.microphone.input)
			&& self.patches == config.patchbay.connections)
	}

	fn is_patched_to_monitor(&self, source: &str) -> bool {
		self
			.patches
			.iter()
			.any(|patch| patch.source == source && patch.destination == "monitor")
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

pub(crate) fn run(config: Config, config_path: PathBuf, stop: Arc<AtomicBool>) -> Result<()> {
	let _control_owner = crate::control::EngineLock::acquire(&config_path)?;
	crate::control::mark_offline(&config_path)?;
	// Discard any uncommitted filter target left by an interrupted transaction.
	for name in ["filter-target.json", "filter-applied.json"] {
		let _ = fs::remove_file(config_path.with_file_name(name));
	}
	clear_active_suppression();
	let _active_suppression_guard = ActiveSuppressionGuard;
	let mut endpoints = EndpointCoordinator::new(&config)?;
	let (mut graph, _) = wait_for_graph(&config, &config_path, &mut endpoints, &stop)?;
	let mut app_router = AppRouter::new(&config)?;
	app_router.reconcile()?;
	let mut next_route_reconcile = Instant::now() + Duration::from_secs(3);
	let mut next_preferred_endpoint_recheck = Instant::now() + PREFERRED_ENDPOINT_RECHECK_INTERVAL;
	info!(input = %graph.input_name, output = %graph.output_name, "AMPS graph started");

	while !stop.load(Ordering::Acquire) {
		thread::sleep(Duration::from_millis(750));
		match endpoints.reconcile(&config) {
			Ok(true) => {
				drop(graph);
				graph = wait_for_graph(&config, &config_path, &mut endpoints, &stop)?.0;
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
				graph = wait_for_graph(&config, &config_path, &mut endpoints, &stop)?.0;
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
			graph = wait_for_graph(&config, &config_path, &mut endpoints, &stop)?.0;
		}
	}

	info!("AMPS graph stopped");
	Ok(())
}

fn wait_for_graph(
	config: &Config,
	config_path: &Path,
	endpoints: &mut EndpointCoordinator,
	stop: &AtomicBool,
) -> Result<(RunningGraph, Config)> {
	let mut attempts = 0_u64;
	let mut retry_delay = Duration::from_secs(1);
	// Prior workers have joined before recovery reaches here. Discard a staged
	// mic target so hardware recovery always reconstructs the committed graph.
	for name in ["filter-target.json", "filter-applied.json"] {
		let _ = fs::remove_file(config_path.with_file_name(name));
	}
	loop {
		if stop.load(Ordering::Acquire) {
			bail!("AMPS stopped while waiting for audio devices");
		}
		if let Err(err) = endpoints.reconcile(config) {
			warn!(%err, "could not reconcile Windows audio defaults while waiting for devices");
		}
		let current = Config::load(config_path)?;
		let effective = match endpoints.effective_config(&current) {
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
		endpoints.begin_graph_rebuild(config, &effective)?;
		match build_graph(&effective, config_path) {
			Ok(graph) => {
				// Opening a Bluetooth Classic microphone makes Windows transition the
				// paired render endpoint from A2DP to HFP. Some drivers complete that
				// transition muted at zero even though the graph opened successfully.
				// Restore the mirrored master state to playback instead of adopting the
				// transient mute, while keeping the microphone itself usable.
				ensure_capture_endpoint_selector_ready(&effective.microphone.input)?;
				endpoints.finish_graph_rebuild()?;
				return Ok((graph, effective));
			}
			Err(err) => {
				if let Err(bridge_error) = endpoints.finish_graph_rebuild() {
					warn!(%bridge_error, "could not resume master-volume mirroring after a failed graph build");
				}
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
			bail!("AMPS stopped while waiting for audio devices");
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
		(
			"Comms Audio",
			config.cables.comms.as_str(),
			Direction::Input,
		),
		("Media", config.cables.music.as_str(), Direction::Input),
		("AI Audio", config.cables.chatgpt.as_str(), Direction::Input),
		(
			"AI Audio render",
			config.cables.chatgpt.as_str(),
			Direction::Output,
		),
		(
			"AI Mic",
			config.cables.chatgpt_in.as_str(),
			Direction::Input,
		),
		(
			"AI Mic render",
			config.cables.chatgpt_in.as_str(),
			Direction::Output,
		),
		(
			"Comms Mic",
			config.cables.comms_send.as_str(),
			Direction::Input,
		),
		(
			"Comms Mic render",
			config.cables.comms_send.as_str(),
			Direction::Output,
		),
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

fn build_graph(config: &Config, config_path: &Path) -> Result<RunningGraph> {
	let host = cpal::default_host();
	validate_cables(&host, config)?;
	let physical_input = resolve_microphone_device(&host, config)?;
	let monitor_output = resolve_monitor_device(&host, config)?;
	let input_name = physical_input.name()?;
	let output_name = monitor_output.name()?;
	let failed = Arc::new(AtomicBool::new(false));
	let mut streams = Vec::new();
	let clean_mic_output = resolve_named_device(&host, Direction::Output, &config.cables.clean_mic)?;
	let (mic_input, mic_output, worker_stop, worker) = build_clean_mic_route(
		&physical_input,
		&clean_mic_output,
		config,
		config_path,
		failed.clone(),
	)?;
	streams.push(mic_input);
	streams.push(mic_output);

	for stream in &streams {
		stream.play().context("could not start an AMPS stream")?;
	}
	let (patch_stop, patch_worker) =
		spawn_patchbay(config.clone(), config_path.to_path_buf(), failed.clone())?;

	Ok(RunningGraph {
		_streams: streams,
		failed,
		worker_stop,
		worker: Some(worker),
		patch_stop,
		patch_worker: Some(patch_worker),
		input_name,
		output_name,
	})
}

fn spawn_patchbay(
	config: Config,
	config_path: PathBuf,
	failed: Arc<AtomicBool>,
) -> Result<(Arc<AtomicBool>, thread::JoinHandle<()>)> {
	let stop = Arc::new(AtomicBool::new(false));
	let thread_stop = stop.clone();
	let worker = thread::Builder::new()
		.name("amps-patchbay".into())
		.spawn(move || run_patchbay(config, config_path, failed, thread_stop))
		.context("could not start the AMPS patchbay worker")?;
	Ok((stop, worker))
}

fn run_patchbay(
	config: Config,
	config_path: PathBuf,
	failed: Arc<AtomicBool>,
	stop: Arc<AtomicBool>,
) {
	use crate::control::Backend;
	let result = (|| -> Result<()> {
		let mut backend = LivePatchBackend {
			routes: std::collections::BTreeMap::new(),
			path: config_path.clone(),
		};
		let mut empty = config.clone();
		empty.patchbay.connections.clear();
		let mut initial = backend.stage(&empty, &config)?;
		backend.activate(&mut initial)?;
		backend.finish(initial);
		let mut server = crate::control::Server::new(&config_path, config)?;
		server.ready()?;
		let mut heartbeat = Instant::now();
		while !stop.load(Ordering::Acquire) {
			if backend
				.routes
				.values()
				.any(|r| r.failed.load(Ordering::Acquire))
			{
				bail!("An active patch endpoint failed; rebuilding against current devices");
			}
			if let Some(request) = server.next_request()? {
				let reply = server.execute(&request, &mut backend)?;
				info!(request = %reply.id, applied = reply.applied, revision = reply.revision, error = ?reply.error, "routing command acknowledged");
				if server.status.applied_revision.is_none() {
					bail!("Controller requires recovery from the last committed graph");
				}
			}
			if heartbeat.elapsed() >= Duration::from_secs(2) {
				server.publish()?;
				heartbeat = Instant::now();
			}
			thread::sleep(Duration::from_millis(100));
		}
		Ok(())
	})();
	if let Err(error) = result {
		error!(%error, "patch controller stopped");
		failed.store(true, Ordering::Release);
	}
}

struct LivePatch {
	_streams: Vec<Stream>,
	gate: Arc<AtomicBool>,
	failed: Arc<AtomicBool>,
}
struct LivePatchBackend {
	routes: std::collections::BTreeMap<String, LivePatch>,
	path: PathBuf,
}
struct StagedPatch {
	added: std::collections::BTreeMap<String, LivePatch>,
	removed: Vec<String>,
	previous_filter: crate::NoiseSuppressionConfig,
	filter_changed: bool,
}
fn patch_id(patch: &PatchConnection) -> String {
	format!("{}:{}", patch.source, patch.destination)
}

impl crate::control::Backend for LivePatchBackend {
	type Staged = StagedPatch;
	fn stage(&mut self, previous: &Config, next: &Config) -> Result<StagedPatch> {
		next.validate()?;
		let host = cpal::default_host();
		let mut added = std::collections::BTreeMap::new();
		let wanted = next
			.patchbay
			.connections
			.iter()
			.map(patch_id)
			.collect::<Vec<_>>();
		for patch in &next.patchbay.connections {
			let id = patch_id(patch);
			if self.routes.contains_key(&id) {
				continue;
			}
			let input = resolve_named_device(
				&host,
				Direction::Input,
				patch_source_selector(next, &patch.source)?,
			)?;
			let output = if patch.destination == "monitor" {
				resolve_monitor_device(&host, next)?
			} else {
				resolve_named_device(
					&host,
					Direction::Output,
					patch_source_selector(next, &patch.destination)?,
				)?
			};
			let gain = if patch.destination == "monitor" {
				match patch.source.as_str() {
					"game" => next.monitor.game_gain,
					"comms" => next.monitor.comms_gain,
					"music" => next.monitor.music_gain,
					"chatgpt" => next.monitor.chatgpt_gain,
					_ => 1.0,
				}
			} else {
				1.0
			};
			let gate = Arc::new(AtomicBool::new(false));
			let local_failed = Arc::new(AtomicBool::new(false));
			let streams = build_gated_stereo_route(
				patch_label(&patch.source),
				&input,
				&[output],
				next.monitor.latency_ms,
				gain,
				local_failed.clone(),
				gate.clone(),
			)?;
			for stream in &streams {
				stream.play().context("Could not stage new connection")?;
			}
			added.insert(
				id,
				LivePatch {
					_streams: streams,
					gate,
					failed: local_failed,
				},
			);
		}
		// Warm new streams muted. Existing routes remain untouched and audible.
		if !added.is_empty() {
			thread::sleep(Duration::from_millis(50));
		}
		if added.values().any(|r| r.failed.load(Ordering::Acquire)) {
			bail!("A new endpoint failed while staging; existing routes retained");
		}
		let filter_changed = previous.noise_suppression != next.noise_suppression;
		if filter_changed {
			if let Err(error) = set_filter_target(&self.path, &next.noise_suppression) {
				if let Err(rollback) = set_filter_target(&self.path, &previous.noise_suppression) {
					for route in self.routes.values() {
						route.failed.store(true, Ordering::Release);
					}
					return Err(error.context(format!(
						"Could not restore mic filter ({rollback:#}); recovering saved graph"
					)));
				}
				return Err(error);
			}
		}
		Ok(StagedPatch {
			added,
			removed: self
				.routes
				.keys()
				.filter(|id| !wanted.contains(id))
				.cloned()
				.collect(),
			previous_filter: previous.noise_suppression.clone(),
			filter_changed,
		})
	}
	fn activate(&mut self, staged: &mut StagedPatch) -> Result<()> {
		if staged
			.added
			.values()
			.chain(self.routes.values())
			.any(|r| r.failed.load(Ordering::Acquire))
		{
			bail!("A device disappeared before activation");
		}
		for id in &staged.removed {
			if let Some(route) = self.routes.get(id) {
				route.gate.store(false, Ordering::Release);
			}
		}
		for route in staged.added.values() {
			route.gate.store(true, Ordering::Release);
		}
		Ok(())
	}
	fn rollback(&mut self, staged: StagedPatch) -> Result<()> {
		for route in staged.added.values() {
			route.gate.store(false, Ordering::Release);
		}
		for id in &staged.removed {
			if let Some(route) = self.routes.get(id) {
				route.gate.store(true, Ordering::Release);
			}
		}
		if staged.filter_changed {
			set_filter_target(&self.path, &staged.previous_filter)?;
		}
		Ok(())
	}
	fn finish(&mut self, staged: StagedPatch) {
		for id in staged.removed {
			self.routes.remove(&id);
		}
		self.routes.extend(staged.added);
	}
}

#[derive(Serialize, Deserialize)]
struct FilterTarget {
	token: String,
	config: crate::NoiseSuppressionConfig,
}
#[derive(Serialize, Deserialize)]
struct FilterReceipt {
	token: String,
	config: crate::NoiseSuppressionConfig,
	error: Option<String>,
}
impl FilterReceipt {
	fn acknowledges(&self, target: &FilterTarget) -> bool {
		self.token == target.token && self.config == target.config
	}
}
fn publish_filter_receipt(
	path: &Path,
	target: &FilterTarget,
	processor: &Option<SuppressionProcessor>,
) {
	let config = &target.config;
	let receipt = FilterReceipt {
		token: target.token.clone(),
		config: config.clone(),
		error: if config.enabled && processor.is_none() {
			Some("Noise processor unavailable; microphone is bypassed".into())
		} else {
			None
		},
	};
	if let Ok(bytes) = serde_json::to_vec(&receipt) {
		let _ = crate::control::atomic_write(&path.with_file_name("filter-applied.json"), &bytes);
	}
}
fn filter_target(path: &Path) -> Result<FilterTarget> {
	let target = path.with_file_name("filter-target.json");
	if target.exists() {
		Ok(serde_json::from_slice(&fs::read(target)?)?)
	} else {
		Ok(FilterTarget {
			token: "committed".into(),
			config: Config::load(path)?.noise_suppression,
		})
	}
}
fn set_filter_target(path: &Path, config: &crate::NoiseSuppressionConfig) -> Result<()> {
	let target = FilterTarget {
		token: crate::control::token(),
		config: config.clone(),
	};
	crate::control::atomic_write(
		&path.with_file_name("filter-target.json"),
		&serde_json::to_vec(&target)?,
	)?;
	let started = Instant::now();
	while started.elapsed() < Duration::from_secs(4) {
		if let Ok(bytes) = fs::read(path.with_file_name("filter-applied.json")) {
			if let Ok(receipt) = serde_json::from_slice::<FilterReceipt>(&bytes) {
				if receipt.acknowledges(&target) {
					if let Some(error) = receipt.error {
						bail!("{error}");
					}
					return Ok(());
				}
			}
		}
		thread::sleep(Duration::from_millis(30));
	}
	bail!("Microphone processor did not acknowledge the requested settings")
}

fn patch_source_selector<'a>(config: &'a Config, source: &str) -> Result<&'a str> {
	match source {
		"game" => Ok(&config.cables.game),
		"comms" => Ok(&config.cables.comms),
		"music" => Ok(&config.cables.music),
		"chatgpt" => Ok(&config.cables.chatgpt),
		"chatgpt_in" => Ok(&config.cables.chatgpt_in),
		"comms_send" => Ok(&config.cables.comms_send),
		"clean_mic" => Ok(&config.cables.clean_mic),
		other => bail!("unknown patch port {other:?}"),
	}
}

fn patch_label(source: &str) -> &'static str {
	match source {
		"game" => "Patch Game",
		"comms" => "Patch Comms Audio",
		"music" => "Patch Media",
		"chatgpt" => "Patch AI Audio",
		"chatgpt_in" => "Patch AI Mic",
		"comms_send" => "Patch Comms Mic",
		"clean_mic" => "Patch Clean Mic",
		_ => "Patch Unknown",
	}
}

fn build_stereo_route(
	label: &'static str,
	input: &Device,
	outputs: &[Device],
	latency_ms: u32,
	gain: f32,
	failed: Arc<AtomicBool>,
) -> Result<Vec<Stream>> {
	build_gated_stereo_route(
		label,
		input,
		outputs,
		latency_ms,
		gain,
		failed,
		Arc::new(AtomicBool::new(true)),
	)
}

fn build_gated_stereo_route(
	label: &'static str,
	input: &Device,
	outputs: &[Device],
	latency_ms: u32,
	gain: f32,
	failed: Arc<AtomicBool>,
	gate: Arc<AtomicBool>,
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
			gate.clone(),
		)?);
	}
	Ok(streams)
}

fn build_clean_mic_route(
	input: &Device,
	output: &Device,
	config: &Config,
	config_path: &Path,
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
	let suppression_config_path = config_path.to_path_buf();
	let worker = thread::Builder::new()
		.name("amps-suppression".into())
		.spawn(move || {
			if let Err(err) = run_suppression(
				raw,
				clean,
				&suppression,
				&suppression_config_path,
				&thread_stop,
			) {
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
	config_path: &Path,
	stop: &AtomicBool,
) -> Result<()> {
	let mut active_target = filter_target(config_path).unwrap_or_else(|error| {
		warn!(
			error = %format!("{error:#}"),
			"could not reload the initial suppression controls; using the graph configuration"
		);
		FilterTarget {
			token: "committed".into(),
			config: config.clone(),
		}
	});
	let mut active_config = active_target.config.clone();
	let mut processor = create_suppression_processor(&active_config, &clean);
	publish_filter_receipt(config_path, &active_target, &processor);
	let mut telemetry = ProcessedMicPublisher::new();
	let mut input_frame = Vec::new();
	let mut output_frame = Vec::new();
	let mut revision = suppression_revision(config_path);
	let mut next_control_check = Instant::now() + Duration::from_millis(50);

	while !stop.load(Ordering::Acquire) {
		if Instant::now() >= next_control_check {
			next_control_check = Instant::now() + Duration::from_millis(50);
			let observed_revision = suppression_revision(config_path);
			if observed_revision != revision {
				match filter_target(config_path) {
					Ok(target) => {
						let updated = target.config.clone();
						revision = observed_revision;
						if updated != active_config || (updated.enabled && processor.is_none()) {
							reconfigure_suppression(&mut processor, &active_config, &updated, &clean);
							active_config = updated;
						}
						active_target = target;
						publish_filter_receipt(config_path, &active_target, &processor);
					}
					Err(error) => warn!(
						error = %format!("{error:#}"),
						"could not hot-reload suppression controls; retaining the current Clean Mic processor"
					),
				}
			}
		}

		let Some(active_processor) = processor.as_mut() else {
			if let Some(sample) = raw.pop() {
				push_latest(&clean, sample);
				if let Some(telemetry) = &mut telemetry {
					telemetry.push(std::slice::from_ref(&sample));
				}
			} else {
				thread::sleep(Duration::from_millis(1));
			}
			continue;
		};
		let frame_samples = active_processor.frame_samples();
		if raw.len() < frame_samples {
			thread::sleep(Duration::from_millis(1));
			continue;
		}
		input_frame.resize(frame_samples, 0.0);
		output_frame.resize(frame_samples, 0.0);
		for sample in &mut input_frame {
			*sample = raw.pop().unwrap_or(0.0);
		}
		if let Err(error) = active_processor.process(&input_frame, &mut output_frame) {
			error!(
				error = %format!("{error:#}"),
				"Clean Mic suppression failed; preserving the mic as an unfiltered passthrough without rebuilding playback buses"
			);
			processor = None;
			publish_active_suppression("Suppression error · mic bypassed");
			publish_filter_receipt(config_path, &active_target, &processor);
			continue;
		}
		for &sample in &output_frame {
			push_latest(&clean, sample);
		}
		if let Some(telemetry) = &mut telemetry {
			telemetry.push(&output_frame);
		}
	}
	Ok(())
}

fn create_suppression_processor(
	config: &crate::NoiseSuppressionConfig,
	clean: &ArrayQueue<f32>,
) -> Option<SuppressionProcessor> {
	if !config.enabled {
		publish_active_suppression("Bypassed");
		info!("Clean Mic suppression bypassed");
		return None;
	}
	let mut processor = match SuppressionProcessor::new(config) {
		Ok(processor) => processor,
		Err(error) => {
			let label = if config.engine == "nvidia_afx" {
				"NVIDIA AFX error · mic bypassed"
			} else {
				"Suppression error · mic bypassed"
			};
			publish_active_suppression(label);
			error!(
				error = %format!("{error:#}"),
				"Clean Mic suppression could not initialize; preserving an unfiltered passthrough without rebuilding playback buses"
			);
			return None;
		}
	};
	let frame_samples = processor.frame_samples();
	let input = vec![0.0_f32; frame_samples];
	let mut output = vec![0.0_f32; frame_samples];
	if let Err(error) = processor.process(&input, &mut output) {
		publish_active_suppression("Suppression error · mic bypassed");
		error!(
			error = %format!("{error:#}"),
			"Clean Mic suppression warmup failed; preserving an unfiltered passthrough without rebuilding playback buses"
		);
		return None;
	}
	for _ in 0..processor.startup_silence() {
		push_latest(clean, 0.0);
	}
	publish_active_suppression(processor.label());
	info!(
		backend = processor.label(),
		frame_samples, "GPU-capable Clean Mic worker ready"
	);
	Some(processor)
}

fn reconfigure_suppression(
	processor: &mut Option<SuppressionProcessor>,
	current: &crate::NoiseSuppressionConfig,
	updated: &crate::NoiseSuppressionConfig,
	clean: &ArrayQueue<f32>,
) {
	let transition = crate::suppression_transition(
		current,
		updated,
		processor.as_ref().map(SuppressionProcessor::backend),
	);
	match transition {
		SuppressionTransition::Bypass => {
			*processor = None;
			publish_active_suppression("Bypassed");
			info!("hot-reloaded Clean Mic suppression bypass");
		}
		SuppressionTransition::UpdateInPlace => {
			let Some(active_processor) = processor.as_mut() else {
				*processor = create_suppression_processor(updated, clean);
				return;
			};
			match active_processor.update_parameters(updated) {
				Ok(()) => {
					publish_active_suppression(active_processor.label());
					info!(
						backend = active_processor.label(),
						intensity = crate::suppression_intensity(updated),
						"hot-reloaded Clean Mic suppression parameters"
					);
				}
				Err(error) => {
					error!(
						error = %format!("{error:#}"),
						"could not hot-reload Clean Mic suppression parameters; rebuilding only its processor"
					);
					*processor = create_suppression_processor(updated, clean);
				}
			}
		}
		SuppressionTransition::Rebuild => {
			info!(
				engine = updated.engine,
				intensity = crate::suppression_intensity(updated),
				"rebuilding only the Clean Mic suppression processor"
			);
			*processor = create_suppression_processor(updated, clean);
		}
	}
}

fn suppression_revision(
	config_path: &Path,
) -> (
	Option<(u64, SystemTime)>,
	Option<(u64, SystemTime)>,
	Option<(u64, SystemTime)>,
) {
	(
		file_revision(config_path),
		file_revision(&config_path.with_file_name("controls.toml")),
		file_revision(&config_path.with_file_name("filter-target.json")),
	)
}

fn file_revision(path: &Path) -> Option<(u64, SystemTime)> {
	let metadata = fs::metadata(path).ok()?;
	Some((metadata.len(), metadata.modified().ok()?))
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
		bail!("refusing to use routing or remote endpoint {name:?} as a physical endpoint; this would create a feedback loop or bind AMPS to a temporary session device");
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
		|| name.starts_with("amps ")
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
	gate: Arc<AtomicBool>,
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
					let audible = gate.load(Ordering::Acquire);
					for frame in data.chunks_mut(channels) {
						let (left, right) = reader.next();
						for (channel, sample) in frame.iter_mut().enumerate() {
							let value = if audible {
								stereo_output_value(left, right, channels, channel)
							} else {
								0.0
							};
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

fn stereo_output_value(left: f32, right: f32, channels: usize, channel: usize) -> f32 {
	if channels == 1 {
		(left + right) * 0.5
	} else if channel % 2 == 0 {
		left
	} else {
		right
	}
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

#[cfg(test)]
mod tests {
	use super::stereo_output_value;
	#[test]
	fn repeated_filter_settings_require_a_fresh_acknowledgement() {
		let config = toml::from_str::<crate::Config>(crate::DEFAULT_CONFIG)
			.unwrap()
			.noise_suppression;
		let target = super::FilterTarget {
			token: "new-request".into(),
			config: config.clone(),
		};
		let mut receipt = super::FilterReceipt {
			token: "old-request".into(),
			config,
			error: None,
		};
		assert!(!receipt.acknowledges(&target));
		receipt.token = target.token.clone();
		assert!(receipt.acknowledges(&target));
	}

	#[test]
	fn hands_free_mono_output_preserves_both_stereo_channels() {
		assert_eq!(stereo_output_value(0.25, 0.75, 1, 0), 0.5);
		assert_eq!(stereo_output_value(0.25, 0.75, 2, 0), 0.25);
		assert_eq!(stereo_output_value(0.25, 0.75, 2, 1), 0.75);
	}
}
