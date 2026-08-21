use std::{
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

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
pub struct NoiseSuppressionConfig {
	pub enabled: bool,
	pub engine: String,
	pub attenuation_limit_db: f32,
	pub post_filter_beta: f32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct RuntimeControls {
	noise_suppression: NoiseSuppressionControls,
}

impl Default for RuntimeControls {
	fn default() -> Self {
		Self {
			noise_suppression: NoiseSuppressionControls::default(),
		}
	}
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct NoiseSuppressionControls {
	enabled: bool,
	intensity: u8,
}

impl Default for NoiseSuppressionControls {
	fn default() -> Self {
		Self {
			enabled: NoiseSuppressionConfig::default().enabled,
			intensity: suppression_intensity(&NoiseSuppressionConfig::default()),
		}
	}
}

impl Default for NoiseSuppressionConfig {
	fn default() -> Self {
		Self {
			enabled: true,
			engine: "deepfilternet3".into(),
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
pub struct GraphSnapshot {
	pub platform: &'static str,
	pub engine_online: bool,
	pub routing_ready: bool,
	pub sample_rate: u32,
	pub suppression: String,
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
			if controls.noise_suppression.intensity > 100 {
				bail!("noise suppression intensity must be between 0 and 100");
			}
			config.noise_suppression.enabled = controls.noise_suppression.enabled;
			config.noise_suppression.attenuation_limit_db =
				attenuation_for_intensity(controls.noise_suppression.intensity);
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
		if self.noise_suppression.engine != "deepfilternet3" {
			bail!("the only supported suppression engine is deepfilternet3");
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

pub fn suppression_intensity(config: &NoiseSuppressionConfig) -> u8 {
	((config.attenuation_limit_db / MAX_SUPPRESSION_ATTENUATION_DB * 100.0)
		.round()
		.clamp(0.0, 100.0)) as u8
}

pub fn attenuation_for_intensity(intensity: u8) -> f32 {
	intensity.min(100) as f32 / 100.0 * MAX_SUPPRESSION_ATTENUATION_DB
}

pub fn save_suppression_controls(config_path: &Path, enabled: bool, intensity: u8) -> Result<()> {
	if intensity > 100 {
		bail!("noise suppression intensity must be between 0 and 100");
	}
	let controls_path = runtime_controls_path(config_path);
	if let Some(parent) = controls_path.parent() {
		fs::create_dir_all(parent).with_context(|| {
			format!(
				"could not create AudioArray controls directory {}",
				parent.display()
			)
		})?;
	}
	let controls = RuntimeControls {
		noise_suppression: NoiseSuppressionControls { enabled, intensity },
	};
	let text = toml::to_string_pretty(&controls)
		.context("could not serialize AudioArray suppression controls")?;
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
pub fn run(config: Config, stop: Arc<AtomicBool>) -> Result<()> {
	windows_audio::run(config, stop)
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
	app_routing::select_output(endpoint)
}

#[cfg(windows)]
pub fn select_main_input(endpoint: &str) -> Result<()> {
	app_routing::select_input(endpoint)
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
		attenuation_for_intensity, suppression_intensity, NoiseSuppressionConfig,
		MAX_SUPPRESSION_ATTENUATION_DB,
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
}
