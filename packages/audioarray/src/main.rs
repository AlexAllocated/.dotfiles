use std::{
	path::PathBuf,
	sync::{
		atomic::{AtomicBool, Ordering},
		Arc,
	},
};

#[cfg(not(windows))]
use anyhow::bail;
#[cfg(windows)]
use anyhow::Context;
use anyhow::Result;
use audioarray::{default_config_path, Config, DEFAULT_CONFIG};
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(about = "Four-bus Windows audio router", version)]
struct Cli {
	#[arg(long, global = true, value_name = "FILE")]
	config: Option<PathBuf>,

	#[command(subcommand)]
	command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
	/// Run the audio graph until interrupted.
	Run,
	/// Validate the configuration and required audio endpoints.
	Doctor,
	/// List the audio endpoints visible to AudioArray.
	Devices,
	/// Select a temporary Windows playback endpoint for the complete bus mix.
	SelectOutput {
		#[arg(value_name = "ENDPOINT")]
		endpoint: String,
	},
	/// Select a temporary Windows recording endpoint for the Clean Mic source.
	SelectInput {
		#[arg(value_name = "ENDPOINT")]
		endpoint: String,
	},
	/// Print the four resolved VAC endpoint IDs as tab-separated records.
	Endpoints,
	/// Measure DeepFilterNet3 throughput with speech-like noisy audio.
	Benchmark {
		#[arg(long, default_value_t = 10)]
		seconds: u32,
	},
	/// Measure live peak levels at the physical input and all four buses.
	Levels {
		#[arg(long, default_value_t = 6)]
		seconds: u32,
	},
	/// Print a documented starter configuration.
	ExampleConfig,
}

fn main() -> Result<()> {
	tracing_subscriber::fmt()
		.with_env_filter(
			tracing_subscriber::EnvFilter::try_from_default_env()
				.unwrap_or_else(|_| "audioarray=info".into()),
		)
		.with_ansi(false)
		.with_target(false)
		.init();

	let cli = Cli::parse();
	if matches!(cli.command, Command::ExampleConfig) {
		print!("{DEFAULT_CONFIG}");
		return Ok(());
	}
	if matches!(cli.command, Command::Devices) {
		#[cfg(windows)]
		return audioarray::print_devices();
		#[cfg(not(windows))]
		bail!("AudioArray device enumeration runs on Windows; build and run audioarray.exe");
	}

	let config_path = cli.config.map(Ok).unwrap_or_else(default_config_path)?;
	let config = Config::load(&config_path)?;

	#[cfg(windows)]
	{
		match cli.command {
			Command::Run => {
				let stop = Arc::new(AtomicBool::new(false));
				let stop_handler = stop.clone();
				ctrlc::set_handler(move || stop_handler.store(true, Ordering::Release))
					.context("could not install the shutdown handler")?;
				audioarray::run(config, stop)
			}
			Command::Doctor => audioarray::doctor(&config),
			Command::SelectOutput { endpoint } => audioarray::select_main_output(&endpoint),
			Command::SelectInput { endpoint } => audioarray::select_main_input(&endpoint),
			Command::Endpoints => audioarray::print_cable_endpoints(&config),
			Command::Benchmark { seconds } => audioarray::benchmark(&config, seconds),
			Command::Levels { seconds } => audioarray::levels(&config, seconds),
			Command::Devices => unreachable!(),
			Command::ExampleConfig => unreachable!(),
		}
	}

	#[cfg(not(windows))]
	{
		let _ = (config, Arc::new(AtomicBool::new(false)), Ordering::Relaxed);
		match cli.command {
			Command::Doctor
			| Command::SelectOutput { .. }
			| Command::SelectInput { .. }
			| Command::Endpoints
			| Command::Benchmark { .. }
			| Command::Levels { .. }
			| Command::Run => {
				bail!("AudioArray's live audio graph runs on Windows; build and run audioarray.exe")
			}
			Command::Devices | Command::ExampleConfig => unreachable!(),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn example_config_is_valid() {
		let config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		config.validate().unwrap();
	}

	#[test]
	fn duplicate_cables_are_rejected() {
		let mut config: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
		config.cables.music = config.cables.game.clone();
		assert!(config.validate().is_err());
	}
}
