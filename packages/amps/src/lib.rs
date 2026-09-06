use std::{
	collections::BTreeSet,
	fs,
	path::{Path, PathBuf},
};

#[cfg(windows)]
use std::sync::{atomic::AtomicBool, Arc};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

pub mod control;
pub mod topology;

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
	pub chatgpt: String,
	pub chatgpt_in: String,
	#[serde(alias = "discord_send")]
	pub comms_send: String,
	pub clean_mic: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct PatchConnection {
	#[serde(deserialize_with = "deserialize_patch_port")]
	pub source: String,
	#[serde(deserialize_with = "deserialize_patch_port")]
	pub destination: String,
}

fn deserialize_patch_port<'de, D: serde::Deserializer<'de>>(
	deserializer: D,
) -> std::result::Result<String, D::Error> {
	let port = String::deserialize(deserializer)?;
	Ok(if port == "discord_send" {
		"comms_send".into()
	} else {
		port
	})
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
				PatchConnection {
					source: "chatgpt".into(),
					destination: "monitor".into(),
				},
				PatchConnection {
					source: "clean_mic".into(),
					destination: "comms_send".into(),
				},
				PatchConnection {
					source: "clean_mic".into(),
					destination: "chatgpt_in".into(),
				},
				PatchConnection {
					source: "comms".into(),
					destination: "chatgpt_in".into(),
				},
				PatchConnection {
					source: "chatgpt".into(),
					destination: "comms_send".into(),
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
	pub chatgpt_gain: f32,
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
			chatgpt_gain: 1.0,
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(default)]
struct RuntimeControls {
	schema_version: u32,
	revision: u64,
	noise_suppression: Option<NoiseSuppressionControls>,
	patchbay: Option<PatchbayControls>,
}

impl Default for RuntimeControls {
	fn default() -> Self {
		Self {
			schema_version: 1,
			revision: 0,
			noise_suppression: None,
			patchbay: None,
		}
	}
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(default)]
struct NoiseSuppressionControls {
	enabled: bool,
	intensity: u8,
	engine: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
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
			.with_context(|| format!("could not read AMPS config {}", path.display()))?;
		let mut config: Self = toml::from_str(&text)
			.with_context(|| format!("could not parse AMPS config {}", path.display()))?;
		let controls_path = runtime_controls_path(path);
		if controls_path.is_file() {
			let controls_text = fs::read_to_string(&controls_path)
				.with_context(|| format!("could not read AMPS controls {}", controls_path.display()))?;
			let controls: RuntimeControls = toml::from_str(&controls_text).with_context(|| {
				format!("could not parse AMPS controls {}", controls_path.display())
			})?;
			control::check_schema(controls.schema_version)?;
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
			self.cables.chatgpt.trim(),
			self.cables.chatgpt_in.trim(),
			self.cables.comms_send.trim(),
			self.cables.clean_mic.trim(),
		];
		if cable_names.iter().any(|name| name.is_empty()) {
			bail!("all seven VAC cable names must be non-empty");
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
			("chatgpt_gain", self.monitor.chatgpt_gain),
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
				if !matches!(output.as_str(), "game" | "comms" | "music" | "chatgpt") {
					bail!(
						"route output for {} must be game, comms, music, or chatgpt",
						route.process
					);
				}
			}
			if let Some(input) = &route.input {
				if !matches!(input.as_str(), "clean_mic" | "chatgpt_in" | "comms_send") {
					bail!(
						"route input for {} must be clean_mic, chatgpt_in, or comms_send",
						route.process
					);
				}
			}
		}
		Ok(())
	}
}

const PATCH_SOURCES: [(&str, &str); 5] = [
	("game", "Game"),
	("comms", "Comms Audio"),
	("music", "Media"),
	("chatgpt", "AI Audio"),
	("clean_mic", "Clean Mic"),
];
const PATCH_DESTINATIONS: [(&str, &str); 6] = [
	("game", "Game"),
	("comms", "Comms Audio"),
	("music", "Media"),
	("chatgpt_in", "AI Mic"),
	("comms_send", "Comms Mic"),
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
		if let Some(destination_index) = source_ids
			.iter()
			.position(|candidate| candidate == &destination)
		{
			let source_index = source_ids
				.iter()
				.position(|candidate| candidate == &source)
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
	for (source, destination) in [("comms", "comms_send"), ("chatgpt", "chatgpt_in")] {
		if patch_reaches(connections, source, destination) {
			bail!("patch would return {source} to its own conversation input {destination}");
		}
	}
	Ok(())
}

pub fn patch_reaches(connections: &[PatchConnection], source: &str, destination: &str) -> bool {
	let mut pending = vec![source];
	let mut visited = BTreeSet::new();
	while let Some(node) = pending.pop() {
		if !visited.insert(node) {
			continue;
		}
		for edge in connections.iter().filter(|edge| edge.source == node) {
			if edge.destination == destination {
				return true;
			}
			pending.push(&edge.destination);
		}
	}
	false
}

/// Explicit conversation setup only, never a generic config-load migration.
pub fn conversation_connections(existing: Vec<PatchConnection>) -> Result<Vec<PatchConnection>> {
	let mut merged = Vec::new();
	for mut edge in existing {
		if matches!(edge.source.as_str(), "chatgpt_in" | "comms_send") {
			continue;
		}
		// Replace the old mixed conversation paths with the isolated topology.
		if matches!(edge.source.as_str(), "comms" | "chatgpt") && edge.destination != "monitor" {
			continue;
		}
		if edge.destination == "clean_mic" {
			edge.destination = "comms_send".into();
		}
		if edge.destination == "chatgpt" {
			edge.destination = "chatgpt_in".into();
		}
		if !merged.contains(&edge) {
			merged.push(edge);
		}
	}
	for edge in PatchbayConfig::default().connections {
		if !merged.contains(&edge) {
			merged.push(edge);
		}
	}
	validate_patch_connections(&merged)?;
	Ok(merged)
}

pub fn setup_conversation(config_path: &Path) -> Result<()> {
	let mut controls = load_runtime_controls(config_path)?;
	let existing = controls
		.patchbay
		.take()
		.map(|patchbay| patchbay.connections)
		.unwrap_or_default();
	controls.patchbay = Some(PatchbayControls {
		connections: conversation_connections(existing)?,
	});
	write_runtime_controls(config_path, &controls)
}

/// Persist compatibility aliases without adding, removing, or reconnecting routes.
pub fn migrate_control_names(config_path: &Path) -> Result<()> {
	let controls = load_runtime_controls(config_path)?;
	if let Some(patchbay) = &controls.patchbay {
		validate_patch_connections(&patchbay.connections)?;
	}
	write_runtime_controls(config_path, &controls)
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
		.with_context(|| format!("could not read AMPS controls {}", path.display()))?;
	let controls: RuntimeControls = toml::from_str(&text)
		.with_context(|| format!("could not parse AMPS controls {}", path.display()))?;
	control::check_schema(controls.schema_version)?;
	Ok(controls)
}

fn write_runtime_controls(config_path: &Path, controls: &RuntimeControls) -> Result<()> {
	let _offline_guard = control::EngineLock::acquire(config_path)
		.context("AMPS is running; use the revisioned control command instead")?;
	let controls_path = runtime_controls_path(config_path);
	if let Some(parent) = controls_path.parent() {
		fs::create_dir_all(parent).with_context(|| {
			format!(
				"could not create AMPS controls directory {}",
				parent.display()
			)
		})?;
	}
	let text =
		toml::to_string_pretty(&controls).context("could not serialize AMPS runtime controls")?;
	control::atomic_write(&controls_path, text.as_bytes())
		.with_context(|| format!("could not write AMPS controls {}", controls_path.display()))
}

fn runtime_controls_path(config_path: &Path) -> PathBuf {
	config_path.with_file_name("controls.toml")
}

pub fn default_config_path() -> Result<PathBuf> {
	if let Some(app_data) = std::env::var_os("APPDATA") {
		return Ok(PathBuf::from(app_data).join("AMPS").join("config.toml"));
	}
	if let Some(home) = std::env::var_os("HOME") {
		return Ok(PathBuf::from(home)
			.join(".config")
			.join("amps")
			.join("config.toml"));
	}
	bail!("could not determine a default AMPS config directory")
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
	bail!("AMPS's Linux endpoint backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn select_main_input(_endpoint: &str) -> Result<()> {
	bail!("AMPS's Linux endpoint backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn graph_snapshot(_config: &Config) -> Result<GraphSnapshot> {
	bail!("AMPS's Linux graph backend has not been connected yet")
}

#[cfg(not(windows))]
pub fn meter_snapshot(_config: &Config) -> Result<Vec<MeterReading>> {
	bail!("AMPS's Linux meter backend has not been connected yet")
}

#[cfg(not(windows))]
pub struct MeterProbe;

#[cfg(not(windows))]
pub struct CleanMicMonitor;

#[cfg(not(windows))]
impl CleanMicMonitor {
	pub fn new(_config: &Config) -> Result<Self> {
		bail!("AMPS's Linux Clean Mic monitor backend has not been connected yet")
	}

	pub fn output_name(&self) -> &str {
		"unavailable"
	}
}

#[cfg(not(windows))]
impl MeterProbe {
	pub fn new(_config: &Config) -> Result<Self> {
		bail!("AMPS's Linux meter backend has not been connected yet")
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
		attenuation_for_intensity, patch_destinations, patch_sources, suppression_intensity,
		suppression_transition, validate_patch_connections, Config, NoiseSuppressionConfig,
		PatchConnection, PatchbayConfig, SuppressionBackend, SuppressionTransition, DEFAULT_CONFIG,
		MAX_SUPPRESSION_ATTENUATION_DB,
	};

	#[test]
	fn media_display_name_preserves_the_saved_music_routing_key() {
		let config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		assert_eq!(config.cables.music, "AMPS Media (Virtual Audio Cable)");
		for ports in [patch_sources(), patch_destinations()] {
			assert_eq!(
				ports.iter().find(|p| p.id == "music").unwrap().name,
				"Media"
			);
			assert!(!ports.iter().any(|p| p.id == "media"));
		}
		assert!(config
			.patchbay
			.connections
			.iter()
			.any(|p| p.source == "music" && p.destination == "monitor"));
		config.validate().unwrap();
	}

	#[test]
	fn conversation_display_names_preserve_saved_route_keys() {
		let config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		for (endpoint, name) in [
			(&config.cables.comms, "Comms Audio"),
			(&config.cables.comms_send, "Comms Mic"),
			(&config.cables.chatgpt, "AI Audio"),
			(&config.cables.chatgpt_in, "AI Mic"),
		] {
			assert_eq!(endpoint, &format!("AMPS {name} (Virtual Audio Cable)"));
		}
		let sources = patch_sources();
		let destinations = patch_destinations();
		for (id, name) in [("comms", "Comms Audio"), ("chatgpt", "AI Audio")] {
			assert_eq!(sources.iter().find(|p| p.id == id).unwrap().name, name);
		}
		for (id, name) in [
			("comms", "Comms Audio"),
			("comms_send", "Comms Mic"),
			("chatgpt_in", "AI Mic"),
		] {
			assert_eq!(destinations.iter().find(|p| p.id == id).unwrap().name, name);
		}
		assert_eq!(config.patchbay, PatchbayConfig::default());
		config.validate().unwrap();
	}

	#[test]
	fn bundled_config_defines_the_chatgpt_peer_bus() {
		let config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		config.validate().unwrap();
		assert_eq!(config.cables.chatgpt, "AMPS AI Audio (Virtual Audio Cable)");
		assert_eq!(config.patchbay, PatchbayConfig::default());
		let chatgpt_routes: Vec<_> = config
			.patchbay
			.connections
			.iter()
			.filter(|patch| patch.source == "chatgpt" || patch.destination == "chatgpt")
			.cloned()
			.collect();
		assert_eq!(
			chatgpt_routes,
			vec![
				PatchConnection {
					source: "chatgpt".into(),
					destination: "monitor".into(),
				},
				PatchConnection {
					source: "chatgpt".into(),
					destination: "comms_send".into()
				}
			]
		);
		let mut without_patchbay: toml::Value = toml::from_str(DEFAULT_CONFIG).unwrap();
		without_patchbay.as_table_mut().unwrap().remove("patchbay");
		let fallback: Config = without_patchbay.try_into().unwrap();
		assert_eq!(fallback.patchbay, config.patchbay);
	}

	#[test]
	fn saved_patch_choices_replace_defaults_without_adding_chatgpt_routes() {
		let root = std::env::temp_dir().join(format!(
			"amps-saved-patches-{}-{}",
			std::process::id(),
			std::time::SystemTime::now()
				.duration_since(std::time::UNIX_EPOCH)
				.unwrap()
				.as_nanos()
		));
		std::fs::create_dir(&root).unwrap();
		let config_path = root.join("config.toml");
		let controls_path = root.join("controls.toml");
		std::fs::write(&config_path, DEFAULT_CONFIG).unwrap();
		// Both an intentionally empty patch board and existing custom routes are
		// authoritative. Updating defaults must never reconnect a saved choice.
		for connections in [
			vec![],
			vec![
				PatchConnection {
					source: "game".into(),
					destination: "monitor".into(),
				},
				PatchConnection {
					source: "music".into(),
					destination: "comms_send".into(),
				},
			],
		] {
			super::save_suppression_controls(&config_path, false, 23, "deepfilternet3").unwrap();
			super::save_patch_connections(&config_path, connections.clone()).unwrap();
			let before = std::fs::read(&controls_path).unwrap();
			let loaded = Config::load(&config_path).unwrap();
			assert_eq!(loaded.patchbay.connections, connections);
			assert!(!loaded.noise_suppression.enabled);
			assert_eq!(suppression_intensity(&loaded.noise_suppression), 23);
			assert_eq!(std::fs::read(&controls_path).unwrap(), before);
		}
		std::fs::remove_dir_all(root).unwrap();
	}

	#[test]
	fn conversation_sources_and_sinks_are_isolated() {
		assert!(patch_sources().iter().any(|port| port.id == "chatgpt"));
		assert!(patch_destinations()
			.iter()
			.any(|port| port.id == "chatgpt_in"));
		assert!(!patch_sources()
			.iter()
			.any(|port| matches!(port.id, "chatgpt_in" | "comms_send")));
		assert!(!patch_destinations()
			.iter()
			.any(|port| matches!(port.id, "chatgpt" | "clean_mic")));
		let defaults = PatchbayConfig::default().connections;
		for (source, destination) in [
			("clean_mic", "chatgpt_in"),
			("clean_mic", "comms_send"),
			("comms", "chatgpt_in"),
			("chatgpt", "comms_send"),
		] {
			assert!(super::patch_reaches(&defaults, source, destination));
		}
		assert!(!super::patch_reaches(&defaults, "comms", "comms_send"));
		assert!(!super::patch_reaches(&defaults, "chatgpt", "chatgpt_in"));
		assert!(!super::patch_reaches(&defaults, "comms", "clean_mic"));
		assert!(!super::patch_reaches(&defaults, "chatgpt", "clean_mic"));
	}

	#[test]
	fn explicit_conversation_setup_removes_old_echo_paths_and_preserves_music_send() {
		let edges = [
			("comms", "chatgpt"),
			("clean_mic", "chatgpt"),
			("chatgpt", "clean_mic"),
			("music", "clean_mic"),
		]
		.into_iter()
		.map(|(source, destination)| PatchConnection {
			source: source.into(),
			destination: destination.into(),
		})
		.collect();
		let migrated = super::conversation_connections(edges).unwrap();
		assert!(super::patch_reaches(&migrated, "music", "comms_send"));
		assert!(!super::patch_reaches(&migrated, "comms", "comms_send"));
		assert!(!super::patch_reaches(&migrated, "chatgpt", "chatgpt_in"));
		assert_eq!(
			super::conversation_connections(migrated.clone()).unwrap(),
			migrated
		);
	}

	#[test]
	fn conversation_guard_blocks_direct_and_indirect_self_return() {
		for (source, sink) in [("comms", "comms_send"), ("chatgpt", "chatgpt_in")] {
			for through_music in [false, true] {
				let mut edges = PatchbayConfig::default().connections;
				edges.push(PatchConnection {
					source: source.into(),
					destination: if through_music {
						"music".into()
					} else {
						sink.into()
					},
				});
				if through_music {
					edges.push(PatchConnection {
						source: "music".into(),
						destination: sink.into(),
					});
				}
				assert!(validate_patch_connections(&edges).is_err());
			}
		}
	}

	#[test]
	fn legacy_send_name_deserializes_to_generic_comms_without_rewiring() {
		let edge: PatchConnection =
			toml::from_str("source = 'chatgpt'\ndestination = 'discord_send'\n").unwrap();
		assert_eq!(edge.source, "chatgpt");
		assert_eq!(edge.destination, "comms_send");
		let encoded = toml::to_string(&edge).unwrap();
		assert!(!encoded.contains("discord_send"));
		assert!(encoded.contains("comms_send"));
	}

	#[test]
	fn default_voice_app_policies_use_separate_input_and_output_buses() {
		let config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		for process in ["ChatGPT.exe", "Codex.exe"] {
			let route = config
				.routes
				.iter()
				.find(|route| route.process == process)
				.unwrap();
			assert_eq!(route.output.as_deref(), Some("chatgpt"));
			assert_eq!(route.input.as_deref(), Some("chatgpt_in"));
		}
		for process in ["Discord.exe", "Vesktop.exe"] {
			let route = config
				.routes
				.iter()
				.find(|route| route.process == process)
				.unwrap();
			assert_eq!(route.output.as_deref(), Some("comms"));
			assert_eq!(route.input.as_deref(), Some("comms_send"));
		}
		assert!(!super::patch_reaches(
			&config.patchbay.connections,
			"game",
			"chatgpt_in"
		));
	}

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
				destination: "comms_send".into(),
			},
			PatchConnection {
				source: "game".into(),
				destination: "monitor".into(),
			},
			PatchConnection {
				source: "music".into(),
				destination: "comms_send".into(),
			},
			PatchConnection {
				source: "chatgpt".into(),
				destination: "monitor".into(),
			},
			PatchConnection {
				source: "clean_mic".into(),
				destination: "chatgpt_in".into(),
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
