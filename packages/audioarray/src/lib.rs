use std::{
	collections::BTreeSet,
	fs,
	path::{Path, PathBuf},
};

#[cfg(windows)]
use std::sync::{atomic::AtomicBool, Arc};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

#[cfg(windows)]
mod app_routing;
#[cfg(windows)]
mod master_volume;
#[cfg(windows)]
mod nvidia_afx;
#[cfg(windows)]
mod windows_audio;

pub const DEFAULT_CONFIG: &str = include_str!("../config.example.toml");
pub const MAX_SUPPRESSION_ATTENUATION_DB: f32 = 40.0;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Config {
	pub cables: CableConfig,
	#[serde(default)]
	pub monitor: MonitorConfig,
	#[serde(default)]
	pub microphone: MicrophoneConfig,
	#[serde(default)]
	pub noise_suppression: NoiseSuppressionConfig,
	#[serde(default)]
	pub patchbay: PatchbayConfig,
	#[serde(default)]
	pub routes: Vec<AppRoute>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AppRoute {
	pub process: String,
	pub output: Option<String>,
	pub input: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CableConfig {
	pub game: String,
	pub comms: String,
	pub music: String,
	pub clean_mic: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct PatchConnection {
	pub source: String,
	pub destination: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(default)]
pub struct PatchbayConfig {
	pub connections: Vec<PatchConnection>,
}

impl Default for PatchbayConfig {
	fn default() -> Self {
		Self {
			connections: vec![
				PatchConnection {
					source: "game".into(),
					destination: "monitor".into(),
				},
				PatchConnection {
					source: "comms".into(),
					destination: "monitor".into(),
				},
				PatchConnection {
					source: "music".into(),
					destination: "monitor".into(),
				},
			],
		}
	}
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct MonitorConfig {
	pub output: String,
	pub remote_output: String,
	pub vr_output: String,
	pub latency_ms: u32,
	pub game_gain: f32,
	pub comms_gain: f32,
	pub music_gain: f32,
}

impl Default for MonitorConfig {
	fn default() -> Self {
		Self {
			output: "default".into(),
			remote_output: "Speakers (Steam Streaming Speakers)".into(),
			vr_output: "Headphones (Oculus Virtual Audio Device)".into(),
			latency_ms: 35,
			game_gain: 1.0,
			comms_gain: 1.0,
			music_gain: 1.0,
		}
	}
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct MicrophoneConfig {
	pub input: String,
	pub vr_input: String,
	pub latency_ms: u32,
	pub gain: f32,
}

impl Default for MicrophoneConfig {
	fn default() -> Self {
		Self {
			input: "default".into(),
			vr_input: "Headset Microphone (Oculus Virtual Audio Device)".into(),
			latency_ms: 45,
			gain: 1.0,
		}
	}
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(default)]
pub struct NoiseSuppressionConfig {
	pub enabled: bool,
	pub engine: String,
	pub attenuation_limit_db: f32,
	pub post_filter_beta: f32,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SuppressionBackend {
	Nvidia,
	DeepFilter,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SuppressionTransition {
	Bypass,
	UpdateInPlace,
	Rebuild,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct RuntimeControls {
	noise_suppression: Option<NoiseSuppressionControls>,
	patchbay: Option<PatchbayControls>,
}

impl Default for RuntimeControls {
	fn default() -> Self {
		Self {
			noise_suppression: None,
			patchbay: None,
		}
	}
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct NoiseSuppressionControls {
	enabled: bool,
	intensity: u8,
	engine: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PatchbayControls {
	connections: Vec<PatchConnection>,
}

impl Default for NoiseSuppressionControls {
	fn default() -> Self {
		Self {
			enabled: NoiseSuppressionConfig::default().enabled,
			intensity: suppression_intensity(&NoiseSuppressionConfig::default()),
			engine: None,
		}
	}
}

impl Default for NoiseSuppressionConfig {
	fn default() -> Self {
		Self {
			enabled: true,
			engine: "nvidia_afx".into(),
			attenuation_limit_db: 20.0,
			post_filter_beta: 0.0,
		}
	}
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointSummary {
	pub id: String,
	pub name: String,
	pub selected: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BusSummary {
	pub id: &'static str,
	pub name: String,
	pub purpose: &'static str,
	pub spatial: Option<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchPortSummary {
	pub id: &'static str,
	pub name: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphSnapshot {
	pub platform: &'static str,
	pub engine_online: bool,
	pub routing_ready: bool,
	pub sample_rate: u32,
	pub suppression: String,
	pub suppression_engine: String,
	pub suppression_enabled: bool,
	pub suppression_intensity: u8,
	pub suppression_attenuation_limit_db: f32,
	pub main_input: Option<EndpointSummary>,
	pub main_output: Option<EndpointSummary>,
	pub input_devices: Vec<EndpointSummary>,
	pub output_devices: Vec<EndpointSummary>,
	pub session_override: Option<String>,
	pub session_input_override: Option<String>,
	pub buses: Vec<BusSummary>,
	pub patch_sources: Vec<PatchPortSummary>,
	pub patch_destinations: Vec<PatchPortSummary>,
	pub patches: Vec<PatchConnection>,
	pub routes: Vec<AppRoute>,
	pub monitor_latency_ms: u32,
	pub microphone_latency_ms: u32,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeterReading {
	pub id: &'static str,
	pub peak: f32,
	pub dbfs: f32,
	pub waveform: Vec<f32>,
}

impl Config {
	pub fn load(path: &Path) -> Result<Self> {
		let text = fs::read_to_string(path)
			.with_context(|| format!("could not read AudioArray config {}", path.display()))?;
		let mut config: Self = toml::from_str(&text)
			.with_context(|| format!("could not parse AudioArray config {}", path.display()))?;
		let controls_path = runtime_controls_path(path);
		if controls_path.is_file() {
			let controls_text = fs::read_to_string(&controls_path).with_context(|| {
				format!(
					"could not read AudioArray controls {}",
					controls_path.display()
				)
			})?;
			let controls: RuntimeControls = toml::from_str(&controls_text).with_context(|| {
				format!(
					"could not parse AudioArray controls {}",
					controls_path.display()
				)
			})?;
			if let Some(suppression) = controls.noise_suppression {
				if suppression.intensity > 100 {
					bail!("noise suppression intensity must be between 0 and 100");
				}
				config.noise_suppression.enabled = suppression.enabled;
				config.noise_suppression.attenuation_limit_db =
					attenuation_for_intensity(suppression.intensity);
				if let Some(engine) = suppression.engine {
					config.noise_suppression.engine = engine;
				}
			}
			if let Some(patchbay) = controls.patchbay {
				config.patchbay.connections = patchbay.connections;
			}
		}
		config.validate()?;
		Ok(config)
	}

	pub fn validate(&self) -> Result<()> {
		let cable_names = [
			self.cables.game.trim(),
			self.cables.comms.trim(),
			self.cables.music.trim(),
			self.cables.clean_mic.trim(),
		];
		if cable_names.iter().any(|name| name.is_empty()) {
			bail!("all four VAC cable names must be non-empty");
		}
		for (index, name) in cable_names.iter().enumerate() {
			if cable_names
				.iter()
				.skip(index + 1)
				.any(|other| name.eq_ignore_ascii_case(other))
			{
				bail!("VAC cable names must be unique; {name:?} appears more than once");
			}
		}
		for (label, value) in [
			("game_gain", self.monitor.game_gain),
			("comms_gain", self.monitor.comms_gain),
			("music_gain", self.monitor.music_gain),
			("microphone gain", self.microphone.gain),
		] {
			if !value.is_finite() || !(0.0..=4.0).contains(&value) {
				bail!("{label} must be between 0.0 and 4.0");
			}
		}
		if !(10..=250).contains(&self.monitor.latency_ms)
			|| !(10..=250).contains(&self.microphone.latency_ms)
		{
			bail!("audio latency must be between 10 and 250 milliseconds");
		}
		if self.monitor.remote_output.trim().is_empty() {
			bail!("remote_output must be non-empty");
		}
		if self.monitor.vr_output.trim().is_empty() {
			bail!("vr_output must be non-empty");
		}
		if self.microphone.vr_input.trim().is_empty() {
			bail!("vr_input must be non-empty");
		}
		if !matches!(
			self.noise_suppression.engine.as_str(),
			"nvidia_afx" | "deepfilternet3"
		) {
			bail!("noise suppression engine must be nvidia_afx or deepfilternet3");
		}
		if !self.noise_suppression.attenuation_limit_db.is_finite()
			|| !(0.0..=100.0).contains(&self.noise_suppression.attenuation_limit_db)
		{
			bail!("attenuation_limit_db must be between 0 and 100 dB");
		}
		if !self.noise_suppression.post_filter_beta.is_finite()
			|| !(0.0..=1.0).contains(&self.noise_suppression.post_filter_beta)
		{
			bail!("post_filter_beta must be between 0 and 1");
		}
		validate_patch_connections(&self.patchbay.connections)?;
		for route in &self.routes {
			if route.process.trim().is_empty() || !route.process.to_ascii_lowercase().ends_with(".exe")
			{
				bail!("route process names must be non-empty .exe names");
			}
			if route.output.is_none() && route.input.is_none() {
				bail!(
					"route for {} has neither an input nor output",
					route.process
				);
			}
			if let Some(output) = &route.output {
				if !matches!(output.as_str(), "game" | "comms" | "music") {
					bail!(
						"route output for {} must be game, comms, or music",
						route.process
					);
				}
			}
			if let Some(input) = &route.input {
				if input != "clean_mic" {
					bail!("route input for {} must be clean_mic", route.process);
				}
			}
		}
		Ok(())
	}
}

const PATCH_SOURCES: [(&str, &str); 4] = [
	("game", "Game"),
	("comms", "Comms"),
	("music", "Music"),
	("clean_mic", "Clean Mic"),
];
const PATCH_DESTINATIONS: [(&str, &str); 5] = [
	("game", "Game"),
	("comms", "Comms"),
	("music", "Music"),
	("clean_mic", "Clean Mic"),
	("monitor", "Main Output"),
];

pub fn patch_sources() -> Vec<PatchPortSummary> {
	PATCH_SOURCES
		.iter()
		.copied()
		.map(|(id, name)| PatchPortSummary { id, name })
		.collect()
}

pub fn patch_destinations() -> Vec<PatchPortSummary> {
	PATCH_DESTINATIONS
		.iter()
		.copied()
		.map(|(id, name)| PatchPortSummary { id, name })
		.collect()
}

pub fn validate_patch_connections(connections: &[PatchConnection]) -> Result<()> {
	let source_ids = PATCH_SOURCES.map(|(id, _)| id);
	let destination_ids = PATCH_DESTINATIONS.map(|(id, _)| id);
	let mut seen = BTreeSet::new();
	let mut adjacency = vec![Vec::new(); source_ids.len()];
	for connection in connections {
		let source = connection.source.trim();
		let destination = connection.destination.trim();
		if !source_ids.contains(&source) {
			bail!("unknown patch source {source:?}");
		}
		if !destination_ids.contains(&destination) {
			bail!("unknown patch destination {destination:?}");
		}
		if source == destination {
			bail!("refusing self-patch {source} -> {destination}");
		}
		if !seen.insert((source.to_string(), destination.to_string())) {
			bail!("duplicate patch {source} -> {destination}");
		}
		if destination != "monitor" {
			let source_index = source_ids
				.iter()
				.position(|candidate| candidate == &source)
				.unwrap();
			let destination_index = source_ids
				.iter()
				.position(|candidate| candidate == &destination)
				.unwrap();
			adjacency[source_index].push(destination_index);
		}
	}

	fn visit(node: usize, adjacency: &[Vec<usize>], state: &mut [u8]) -> bool {
		if state[node] == 1 {
			return true;
		}
		if state[node] == 2 {
			return false;
		}
		state[node] = 1;
		if adjacency[node]
			.iter()
			.any(|&destination| visit(destination, adjacency, state))
		{
			return true;
		}
		state[node] = 2;
		false
	}

	let mut state = vec![0; source_ids.len()];
	if (0..source_ids.len()).any(|node| visit(node, &adjacency, &mut state)) {
		bail!("patch would create an audio feedback loop");
	}
	Ok(())
}

pub fn suppression_intensity(config: &NoiseSuppressionConfig) -> u8 {
	((config.attenuation_limit_db / MAX_SUPPRESSION_ATTENUATION_DB * 100.0)
		.round()
		.clamp(0.0, 100.0)) as u8
}

pub fn attenuation_for_intensity(intensity: u8) -> f32 {
	intensity.min(100) as f32 / 100.0 * MAX_SUPPRESSION_ATTENUATION_DB
}

#[cfg(any(windows, test))]
pub(crate) fn suppression_transition(
	current: &NoiseSuppressionConfig,
	updated: &NoiseSuppressionConfig,
	backend: Option<SuppressionBackend>,
) -> SuppressionTransition {
	if !updated.enabled {
		return SuppressionTransition::Bypass;
	}
	if !current.enabled || current.engine != updated.engine {
		return SuppressionTransition::Rebuild;
	}
	match backend {
		// NVIDIA accepts a post-load intensity update but does not reliably
		// apply it to the loaded model. Recreate only the Clean Mic effect so
		// the requested ratio is guaranteed to become effective.
		Some(SuppressionBackend::Nvidia) | None => SuppressionTransition::Rebuild,
		Some(SuppressionBackend::DeepFilter) => SuppressionTransition::UpdateInPlace,
	}
}

pub fn save_suppression_controls(
	config_path: &Path,
	enabled: bool,
	intensity: u8,
	engine: &str,
) -> Result<()> {
	if intensity > 100 {
		bail!("noise suppression intensity must be between 0 and 100");
	}
	if !matches!(engine, "nvidia_afx" | "deepfilternet3") {
		bail!("noise suppression engine must be nvidia_afx or deepfilternet3");
	}
	let mut controls = load_runtime_controls(config_path)?;
	controls.noise_suppression = Some(NoiseSuppressionControls {
		enabled,
		intensity,
		engine: Some(engine.to_string()),
	});
	write_runtime_controls(config_path, &controls)
}

pub fn save_patch_connections(config_path: &Path, connections: Vec<PatchConnection>) -> Result<()> {
	validate_patch_connections(&connections)?;
	let mut controls = load_runtime_controls(config_path)?;
	controls.patchbay = Some(PatchbayControls { connections });
	write_runtime_controls(config_path, &controls)
}

fn load_runtime_controls(config_path: &Path) -> Result<RuntimeControls> {
	let path = runtime_controls_path(config_path);
	if !path.is_file() {
		return Ok(RuntimeControls::default());
	}
	let text = fs::read_to_string(&path)
		.with_context(|| format!("could not read AudioArray controls {}", path.display()))?;
	toml::from_str(&text)
		.with_context(|| format!("could not parse AudioArray controls {}", path.display()))
}

fn write_runtime_controls(config_path: &Path, controls: &RuntimeControls) -> Result<()> {
	let controls_path = runtime_controls_path(config_path);
	if let Some(parent) = controls_path.parent() {
		fs::create_dir_all(parent).with_context(|| {
			format!(
				"could not create AudioArray controls directory {}",
				parent.display()
			)
		})?;
	}
	let text = toml::to_string_pretty(&controls)
		.context("could not serialize AudioArray runtime controls")?;
	fs::write(&controls_path, text).with_context(|| {
		format!(
			"could not write AudioArray controls {}",
			controls_path.display()
		)
	})
}

fn runtime_controls_path(config_path: &Path) -> PathBuf {
	config_path.with_file_name("controls.toml")
}

pub fn default_config_path() -> Result<PathBuf> {
	if let Some(app_data) = std::env::var_os("APPDATA") {
		return Ok(PathBuf::from(app_data)
			.join("AudioArray")
			.join("config.toml"));
	}
	if let Some(home) = std::env::var_os("HOME") {
		return Ok(PathBuf::from(home)
			.join(".config")
			.join("audioarray")
			.join("config.toml"));
	}
	bail!("could not determine a default AudioArray config directory")
}

#[cfg(windows)]
pub fn run(config: Config, config_path: PathBuf, stop: Arc<AtomicBool>) -> Result<()> {
	windows_audio::run(config, config_path, stop)
}

#[cfg(windows)]
pub fn doctor(config: &Config) -> Result<()> {
	windows_audio::doctor(config)
}

#[cfg(windows)]
pub fn print_devices() -> Result<()> {
	windows_audio::print_devices()
}

#[cfg(windows)]
pub fn print_cable_endpoints(config: &Config) -> Result<()> {
	app_routing::print_cable_endpoints(config)
}

#[cfg(windows)]
pub fn benchmark(config: &Config, seconds: u32) -> Result<()> {
	windows_audio::benchmark(config, seconds)
}

#[cfg(windows)]
pub fn levels(config: &Config, seconds: u32) -> Result<()> {
	windows_audio::levels(config, seconds)
}

#[cfg(windows)]
pub fn select_main_output(endpoint: &str) -> Result<()> {
	app_routing::select_output(endpoint)?;
	windows_audio::remember_selected_physical_output(endpoint)
}

#[cfg(windows)]
pub fn select_main_input(endpoint: &str) -> Result<()> {
	app_routing::select_input(endpoint)?;
	windows_audio::remember_selected_physical_input(endpoint)
}

#[cfg(windows)]
pub fn graph_snapshot(config: &Config) -> Result<GraphSnapshot> {
	windows_audio::graph_snapshot(config)
}

#[cfg(windows)]
pub fn meter_snapshot(config: &Config) -> Result<Vec<MeterReading>> {
	windows_audio::meter_snapshot(config)
}

#[cfg(windows)]
pub struct MeterProbe(windows_audio::MeterProbe);

#[cfg(windows)]
pub struct CleanMicMonitor(windows_audio::CleanMicMonitor);

#[cfg(windows)]
impl CleanMicMonitor {
	pub fn new(config: &Config) -> Result<Self> {
		Ok(Self(windows_audio::CleanMicMonitor::new(config)?))
	}

	pub fn output_name(&self) -> &str {
		self.0.output_name()
	}
}

#[cfg(windows)]
impl MeterProbe {
	pub fn new(config: &Config) -> Result<Self> {
		Ok(Self(windows_audio::MeterProbe::new(config)?))
	}

	pub fn read(&mut self) -> Vec<MeterReading> {
		self.0.read()
	}

	pub fn is_current(&self, config: &Config) -> Result<bool> {
		self.0.is_current(config)
	}
}

#[cfg(not(windows))]
pub fn select_main_output(_endpoint: &str) -> Result<()> {
	bail!("AudioArray's Linux endpoint backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn select_main_input(_endpoint: &str) -> Result<()> {
	bail!("AudioArray's Linux endpoint backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn graph_snapshot(_config: &Config) -> Result<GraphSnapshot> {
	bail!("AudioArray's Linux graph backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn meter_snapshot(_config: &Config) -> Result<Vec<MeterReading>> {
	bail!("AudioArray's Linux meter backend has not been connected yet")
}

#[cfg(not(windows))]
pub struct MeterProbe;

#[cfg(not(windows))]
pub struct CleanMicMonitor;

#[cfg(not(windows))]
impl CleanMicMonitor {
	pub fn new(_config: &Config) -> Result<Self> {
		bail!("AudioArray's Linux Clean Mic monitor backend has not been connected yet")
	}

	pub fn output_name(&self) -> &str {
		"unavailable"
	}
}

#[cfg(not(windows))]
impl MeterProbe {
	pub fn new(_config: &Config) -> Result<Self> {
		bail!("AudioArray's Linux meter backend has not been connected yet")
	}

	pub fn read(&mut self) -> Vec<MeterReading> {
		Vec::new()
	}

	pub fn is_current(&self, _config: &Config) -> Result<bool> {
		Ok(false)
	}
}

#[cfg(test)]
mod tests {
	use super::{
		attenuation_for_intensity, suppression_intensity, suppression_transition,
		validate_patch_connections, NoiseSuppressionConfig, PatchConnection, SuppressionBackend,
		SuppressionTransition, MAX_SUPPRESSION_ATTENUATION_DB,
	};

	#[test]
	fn default_suppression_is_balanced() {
		assert_eq!(
			suppression_intensity(&NoiseSuppressionConfig::default()),
			50
		);
	}

	#[test]
	fn suppression_intensity_maps_to_bounded_attenuation() {
		assert_eq!(attenuation_for_intensity(0), 0.0);
		assert_eq!(attenuation_for_intensity(50), 20.0);
		assert_eq!(
			attenuation_for_intensity(100),
			MAX_SUPPRESSION_ATTENUATION_DB
		);
		assert_eq!(
			attenuation_for_intensity(200),
			MAX_SUPPRESSION_ATTENUATION_DB
		);
	}

	#[test]
	fn suppression_transition_covers_bypass_and_reenable() {
		let current = NoiseSuppressionConfig::default();
		let mut bypassed = current.clone();
		bypassed.enabled = false;
		assert_eq!(
			suppression_transition(&current, &bypassed, Some(SuppressionBackend::Nvidia)),
			SuppressionTransition::Bypass
		);
		assert_eq!(
			suppression_transition(&bypassed, &current, None),
			SuppressionTransition::Rebuild
		);
	}

	#[test]
	fn suppression_transition_rebuilds_engine_swaps() {
		let current = NoiseSuppressionConfig::default();
		let mut updated = current.clone();
		updated.engine = "deepfilternet3".into();
		assert_eq!(
			suppression_transition(&current, &updated, Some(SuppressionBackend::Nvidia)),
			SuppressionTransition::Rebuild
		);
		assert_eq!(
			suppression_transition(&updated, &current, Some(SuppressionBackend::DeepFilter)),
			SuppressionTransition::Rebuild
		);
	}

	#[test]
	fn suppression_transition_remembers_changes_while_bypassed() {
		let mut current = NoiseSuppressionConfig::default();
		current.enabled = false;
		let mut updated = current.clone();
		updated.engine = "deepfilternet3".into();
		assert_eq!(
			suppression_transition(&current, &updated, None),
			SuppressionTransition::Bypass
		);
		let mut enabled = updated.clone();
		enabled.enabled = true;
		assert_eq!(
			suppression_transition(&updated, &enabled, None),
			SuppressionTransition::Rebuild
		);
	}

	#[test]
	fn suppression_transition_rebuilds_nvidia_but_updates_deepfilter_in_place() {
		let current = NoiseSuppressionConfig::default();
		let mut updated = current.clone();
		updated.attenuation_limit_db = 40.0;
		assert_eq!(
			suppression_transition(&current, &updated, Some(SuppressionBackend::Nvidia)),
			SuppressionTransition::Rebuild
		);
		assert_eq!(
			suppression_transition(&current, &updated, Some(SuppressionBackend::DeepFilter)),
			SuppressionTransition::UpdateInPlace
		);
	}

	#[test]
	fn patchbay_allows_fanout_and_monitor_sinks() {
		let patches = vec![
			PatchConnection {
				source: "game".into(),
				destination: "clean_mic".into(),
			},
			PatchConnection {
				source: "game".into(),
				destination: "monitor".into(),
			},
			PatchConnection {
				source: "music".into(),
				destination: "clean_mic".into(),
			},
		];
		assert!(validate_patch_connections(&patches).is_ok());
	}

	#[test]
	fn patchbay_rejects_direct_and_indirect_feedback() {
		let direct = vec![
			PatchConnection {
				source: "game".into(),
				destination: "music".into(),
			},
			PatchConnection {
				source: "music".into(),
				destination: "game".into(),
			},
		];
		assert!(validate_patch_connections(&direct).is_err());

		let indirect = vec![
			PatchConnection {
				source: "game".into(),
				destination: "music".into(),
			},
			PatchConnection {
				source: "music".into(),
				destination: "clean_mic".into(),
			},
			PatchConnection {
				source: "clean_mic".into(),
				destination: "game".into(),
			},
		];
		assert!(validate_patch_connections(&indirect).is_err());
	}
}
