use std::{
	path::PathBuf,
	sync::{
		atomic::{AtomicBool, Ordering},
		Arc,
	},
};

use amps::{default_config_path, Config, DEFAULT_CONFIG};
#[cfg(not(windows))]
use anyhow::bail;
#[cfg(windows)]
use anyhow::Context;
use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(about = "Seven-bus Windows audio router", version)]
struct Cli {
	#[arg(long, global = true, value_name = "FILE")]
	config: Option<PathBuf>,

	#[command(subcommand)]
	command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
	/// Inspect desired and applied control revisions without changing anything.
	ControlStatus,
	/// Submit a revisioned request from a JSON file to the running engine.
	Control {
		#[arg(long)]
		request: PathBuf,
	},
	/// Export the native canvas snapshot for diagnostics and UI fixtures.
	Snapshot,
	/// Explicitly configure isolated ChatGPT and communications mixes.
	SetupConversation,
	/// Persist legacy control names without changing the selected routes.
	MigrateControlNames,
	/// Run the audio graph until interrupted.
	Run,
	/// Validate the configuration and required audio endpoints.
	Doctor,
	/// List the audio endpoints visible to AMPS.
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
	/// Print the seven resolved VAC endpoint IDs as tab-separated records.
	Endpoints,
	/// Measure the configured suppression backend with speech-like noisy audio.
	Benchmark {
		#[arg(long, default_value_t = 10)]
		seconds: u32,
	},
	/// Measure live peak levels at the physical input and all seven buses.
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
				.unwrap_or_else(|_| "amps=info".into()),
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
		return amps::print_devices();
		#[cfg(not(windows))]
		bail!("AMPS device enumeration runs on Windows; build and run amps.exe");
	}

	let config_path = cli.config.map(Ok).unwrap_or_else(default_config_path)?;
	if matches!(cli.command, Command::ControlStatus) {
		println!(
			"{}",
			serde_json::to_string_pretty(&amps::control::status(&config_path)?)?
		);
		return Ok(());
	}
	if let Command::Control { request } = &cli.command {
		let request: amps::control::Request = serde_json::from_slice(&std::fs::read(request)?)?;
		println!(
			"{}",
			serde_json::to_string_pretty(&amps::control::submit(&config_path, &request)?)?
		);
		return Ok(());
	}
	if matches!(cli.command, Command::SetupConversation) {
		amps::setup_conversation(&config_path)?;
		println!("Isolated conversation routes saved; other controls preserved.");
		return Ok(());
	}
	if matches!(cli.command, Command::MigrateControlNames) {
		amps::migrate_control_names(&config_path)?;
		println!("Control names migrated; selected routes preserved.");
		return Ok(());
	}
	let config = Config::load(&config_path)?;

	#[cfg(windows)]
	{
		match cli.command {
			Command::Snapshot => {
				let graph = amps::graph_snapshot(&config)?;
				let runtime = amps::control::status(&config_path).ok();
				let topology = amps::topology::project(
					&graph,
					runtime
						.as_ref()
						.filter(|r| r.online && r.applied_revision.is_some())
						.map(|r| r.patches.as_slice())
						.unwrap_or(&graph.patches),
					runtime.as_ref(),
				);
				println!(
					"{}",
					serde_json::to_string_pretty(
						&serde_json::json!({"graph":graph,"runtime":runtime,"topology":topology})
					)?
				);
				Ok(())
			}
			Command::Run => {
				let stop = Arc::new(AtomicBool::new(false));
				let stop_handler = stop.clone();
				ctrlc::set_handler(move || stop_handler.store(true, Ordering::Release))
					.context("could not install the shutdown handler")?;
				amps::run(config, config_path, stop)
			}
			Command::Doctor => amps::doctor(&config),
			Command::SelectOutput { endpoint } => amps::select_main_output(&endpoint),
			Command::SelectInput { endpoint } => amps::select_main_input(&endpoint),
			Command::Endpoints => amps::print_cable_endpoints(&config),
			Command::Benchmark { seconds } => amps::benchmark(&config, seconds),
			Command::Levels { seconds } => amps::levels(&config, seconds),
			Command::Devices => unreachable!(),
			Command::ExampleConfig
			| Command::SetupConversation
			| Command::MigrateControlNames
			| Command::ControlStatus
			| Command::Control { .. } => {
				unreachable!()
			}
		}
	}

	#[cfg(not(windows))]
	{
		let _ = (config, Arc::new(AtomicBool::new(false)), Ordering::Relaxed);
		match cli.command {
			Command::Doctor
			| Command::Snapshot
			| Command::SelectOutput { .. }
			| Command::SelectInput { .. }
			| Command::Endpoints
			| Command::Benchmark { .. }
			| Command::Levels { .. }
			| Command::Run => {
				bail!("AMPS's live audio graph runs on Windows; build and run amps.exe")
			}
			Command::Devices
			| Command::ExampleConfig
			| Command::SetupConversation
			| Command::MigrateControlNames => unreachable!(),
			Command::ControlStatus | Command::Control { .. } => unreachable!(),
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
