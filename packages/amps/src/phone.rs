//! Phone reception and explicit graph fan-out. Private Main Output by default.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
	path::Path,
	sync::{
		atomic::{AtomicBool, Ordering},
		mpsc, Arc, Mutex,
	},
	thread,
	time::Duration,
};

#[cfg(any(windows, test))]
mod buffer;
#[cfg(any(windows, test))]
pub(crate) mod hub;
#[cfg(any(windows, test))]
mod recovery;
#[cfg(windows)]
mod relay;
#[cfg(windows)]
pub(crate) use relay::Fanout;
mod ipc;
#[cfg(windows)]
mod windows;
pub use ipc::Client;

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Device {
	pub id: String,
	pub name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
	pub schema_version: u32,
	pub device_id: Option<String>,
	pub auto_connect: bool,
}
impl Default for Settings {
	fn default() -> Self {
		Self {
			schema_version: 1,
			device_id: None,
			auto_connect: false,
		}
	}
}
#[cfg(any(windows, test))]
impl Settings {
	fn load(path: &Path) -> Result<Self> {
		let settings: Self = match std::fs::read_to_string(path) {
			Ok(text) => toml::from_str(&text).context("Invalid phone settings; retained unchanged")?,
			Err(e) if e.kind() == std::io::ErrorKind::NotFound => Self::default(),
			Err(e) => return Err(e.into()),
		};
		crate::control::check_schema(settings.schema_version)?;
		Ok(settings)
	}
	fn save(&self, path: &Path) -> Result<()> {
		crate::control::atomic_write(path, toml::to_string_pretty(self)?.as_bytes())
	}
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
	pub supported: bool,
	pub devices: Vec<Device>,
	pub settings: Settings,
	pub wanted: bool,
	pub connected: bool,
	pub phase: String,
	pub output: Option<Device>,
	pub error: Option<String>,
}
impl Default for Snapshot {
	fn default() -> Self {
		Self {
			supported: cfg!(windows),
			devices: vec![],
			settings: Settings::default(),
			wanted: false,
			connected: false,
			phase: "off".into(),
			output: None,
			error: None,
		}
	}
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
	pub action: String,
	pub device_id: Option<String>,
	pub auto_connect: Option<bool>,
}
impl Request {
	fn validate(&self) -> Result<()> {
		if ![
			"connect",
			"reconnect",
			"disconnect",
			"refresh",
			"settings",
			"quiesce",
		]
		.contains(&self.action.as_str())
		{
			bail!("Unknown phone action");
		}
		if self.device_id.as_ref().is_some_and(|id| id.len() > 4096) {
			bail!("Invalid phone device ID");
		}
		Ok(())
	}
}

/// Best-effort graceful shutdown before the supervisor terminates the engine.
pub fn quiesce(config: &Path) {
	let client = Client::new(config);
	let _ = client.edit_timeout(
		Request {
			action: "quiesce".into(),
			device_id: None,
			auto_connect: None,
		},
		Duration::from_secs(2),
	);
}
/// Fail closed even after an engine crash; never restore the default/VAC route.
pub fn disable_native_listen(config: &Path) {
	#[cfg(windows)]
	let _ = windows::disable_native_listen(config);
	#[cfg(not(windows))]
	let _ = config;
}

enum Message {
	Output(Option<Device>),
	Edit(Request, mpsc::Sender<std::result::Result<(), String>>),
	Restart,
	#[cfg(windows)]
	Discover,
	Stop,
}

/// The engine owns reception and routing. The tray talks to it via local IPC.
pub struct Service {
	#[cfg(windows)]
	pub(crate) hub: Arc<hub::Hub>,
	sender: mpsc::Sender<Message>,
	snapshot: Arc<Mutex<Snapshot>>,
	meter: Arc<Mutex<Option<crate::MeterReading>>>,
	worker: Mutex<Option<thread::JoinHandle<()>>>,
	stop: Arc<AtomicBool>,
}
impl Service {
	pub fn start(config_path: &Path) -> Self {
		let (sender, receiver) = mpsc::channel();
		let snapshot = Arc::new(Mutex::new(Snapshot::default()));
		let meter = Arc::new(Mutex::new(None));
		#[cfg(not(windows))]
		let path = config_path.with_file_name("phone.toml");
		#[cfg(windows)]
		let source_config = config_path.to_path_buf();
		#[cfg(windows)]
		let hub = hub::Hub::new();
		#[cfg(windows)]
		let worker_hub = hub.clone();
		let state = snapshot.clone();
		let levels = meter.clone();
		let stop = Arc::new(AtomicBool::new(false));
		let stopped = stop.clone();
		#[cfg(windows)]
		let wakeup = sender.clone();
		let worker = thread::Builder::new()
			.name("amps-phone".into())
			.spawn(move || {
				#[cfg(windows)]
				windows::run(
					source_config,
					receiver,
					state,
					levels,
					stopped,
					wakeup,
					worker_hub,
				);
				#[cfg(not(windows))]
				{
					let _ = (path, levels, stopped);
					while let Ok(message) = receiver.recv() {
						match message {
							Message::Stop => break,
							Message::Edit(request, reply) => {
								let _ = request;
								let _ = reply.send(Err("Phone playback requires Windows".into()));
							}
							Message::Output(output) => {
								let _ = output;
							}
							_ => {
								let _ = &state;
							}
						}
					}
				}
			})
			.expect("could not start the AMPS phone receiver");
		Self {
			#[cfg(windows)]
			hub,
			sender,
			snapshot,
			meter,
			worker: Mutex::new(Some(worker)),
			stop,
		}
	}
	pub fn snapshot(&self) -> Snapshot {
		self.snapshot.lock().unwrap().clone()
	}
	pub fn meter(&self) -> Option<crate::MeterReading> {
		self.meter.lock().unwrap().clone()
	}
	pub fn output(&self, output: Option<Device>) {
		let _ = self.sender.send(Message::Output(output));
	}
	pub fn edit(&self, request: Request) -> Result<()> {
		request.validate()?;
		let (sender, receiver) = mpsc::channel();
		self.sender.send(Message::Edit(request, sender))?;
		receiver
			.recv_timeout(Duration::from_secs(45))
			.context("Phone command timed out")?
			.map_err(anyhow::Error::msg)
	}
	pub fn restart(&self) {
		let _ = self.sender.send(Message::Restart);
	}
	pub fn stop(&self) {
		self.stop.store(true, Ordering::Release);
		let _ = self.sender.send(Message::Stop);
		if let Some(worker) = self.worker.lock().unwrap().take() {
			let _ = worker.join();
		}
	}
}
impl Drop for Service {
	fn drop(&mut self) {
		self.stop();
	}
}

/// Only a unique currently applied listening endpoint is eligible. Never use a
/// Windows default, desired-but-not-applied selection, or arbitrary VAC endpoint.
pub fn applied_output(
	graph: &crate::GraphSnapshot,
	runtime: Option<&crate::control::Status>,
) -> Option<Device> {
	let runtime = runtime.filter(|r| r.online && r.applied_revision.is_some())?;
	let mut matches = graph
		.output_devices
		.iter()
		.filter(|d| d.name.eq_ignore_ascii_case(&runtime.output_name));
	let device = matches.next()?;
	if matches.next().is_some() {
		return None;
	}
	Some(Device {
		id: device.id.clone(),
		name: device.name.clone(),
	})
}

/// Match device-instance identity, not user-visible names or Bluetooth addresses.
#[cfg(any(windows, test))]
fn instance_id(interface: &str) -> Result<String> {
	let parts: Vec<_> = interface
		.strip_prefix(r"\\?\")
		.context("Unexpected phone interface")?
		.split('#')
		.collect();
	if parts.len() != 4
		|| !parts[0].eq_ignore_ascii_case("BTHENUM")
		|| !parts[3].to_ascii_uppercase().ends_with(r"\SNK")
	{
		bail!("Unsupported Bluetooth audio interface; refusing to guess a capture endpoint");
	}
	Ok(parts[..3].join(r"\").to_ascii_uppercase())
}

pub fn append_topology(topology: &mut crate::topology::Topology, phone: &Snapshot) {
	if !phone.supported {
		return;
	}
	if let Some(node) = topology.nodes.iter_mut().find(|n| n.id == "phone") {
		node.detail = phone
			.devices
			.iter()
			.find(|d| Some(&d.id) == phone.settings.device_id.as_ref())
			.map(|d| format!("{} · {}", d.name, phone.phase))
			.unwrap_or_else(|| "Select a paired phone · private by default".into());
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn receiver_never_initiates_a_bluetooth_connection() {
		let source = include_str!("phone/windows.rs");
		assert!(source.contains("connection.StartAsync()?"));
		assert!(!source.contains(".OpenAsync("));
		assert!(!source.contains(".Open("));
	}
	#[test]
	fn maps_exact_bluetooth_instance() {
		assert_eq!(
			instance_id(r"\\?\BTHENUM#{source}_VID&1234#A&B&0&INSTANCE#{class}\SNK").unwrap(),
			r"BTHENUM\{SOURCE}_VID&1234\A&B&0&INSTANCE"
		);
		assert!(instance_id("My Phone").is_err());
		assert!(instance_id(r"\\?\SWD#foo#bar#{class}\SNK").is_err());
	}
	#[test]
	fn settings_roundtrip_and_future_schema_protected() {
		let temp = tempfile::tempdir().unwrap();
		let path = temp.path().join("phone.toml");
		assert!(!Settings::load(&path).unwrap().auto_connect);
		let settings = Settings {
			device_id: Some("fixture".into()),
			auto_connect: true,
			..Default::default()
		};
		settings.save(&path).unwrap();
		assert_eq!(Settings::load(&path).unwrap().device_id, settings.device_id);
		let legacy = format!(
			"{}\nbufferMs = 500\n",
			toml::to_string_pretty(&settings).unwrap()
		);
		std::fs::write(&path, legacy).unwrap();
		assert_eq!(Settings::load(&path).unwrap(), settings);
		assert!(!toml::to_string_pretty(&settings)
			.unwrap()
			.contains("buffer"));
		std::fs::write(&path, "schemaVersion = 2").unwrap();
		assert!(Settings::load(&path).is_err());
		assert_eq!(std::fs::read_to_string(&path).unwrap(), "schemaVersion = 2");
	}
	#[test]
	fn phone_status_does_not_invent_routes() {
		let mut topology = crate::topology::Topology {
			nodes: vec![],
			edges: vec![],
		};
		let phone = Snapshot {
			supported: true,
			connected: true,
			output: Some(Device {
				id: "test".into(),
				name: "Headphones".into(),
			}),
			..Default::default()
		};
		append_topology(&mut topology, &phone);
		assert!(topology.nodes.is_empty());
		assert!(topology.edges.is_empty());
	}
}
