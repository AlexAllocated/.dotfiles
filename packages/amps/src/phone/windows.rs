use super::recovery::RetryComponent;
use super::*;
use ::windows::{
	core::{BSTR, GUID, HSTRING, PROPVARIANT},
	Devices::Enumeration::{DeviceInformation, DeviceInformationUpdate, DeviceWatcher},
	Foundation::{AsyncStatus, IAsyncAction, TypedEventHandler},
	Media::Audio::{AudioPlaybackConnection, AudioPlaybackConnectionState},
	Win32::{
		Media::Audio::*,
		System::{
			Com::{StructuredStorage::*, *},
			Variant::VT_LPWSTR,
			WinRT::*,
		},
		UI::Shell::PropertiesSystem::*,
	},
};
use std::{path::PathBuf, time::Instant};
use winreg::{
	enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY},
	RegKey,
};

pub(super) fn key(pid: u32) -> PROPERTYKEY {
	PROPERTYKEY {
		fmtid: GUID::from_u128(0x24dbb0fc_9311_4b3d_9cf0_18ff155639d4),
		pid,
	}
}

fn check_wait(status: AsyncStatus, deadline: Instant, stop: &AtomicBool) -> Result<bool> {
	if stop.load(Ordering::Acquire) {
		bail!("Phone operation cancelled during shutdown");
	}
	if status != AsyncStatus::Started {
		return Ok(false);
	}
	if Instant::now() >= deadline {
		bail!("Windows Bluetooth operation timed out");
	}
	thread::sleep(Duration::from_millis(30));
	Ok(true)
}
fn wait_action(action: &IAsyncAction, stop: &AtomicBool) -> Result<()> {
	let deadline = Instant::now() + Duration::from_secs(15);
	loop {
		match check_wait(action.Status()?, deadline, stop) {
			Ok(true) => {}
			Ok(false) => return Ok(action.GetResults()?),
			Err(e) => {
				let _ = action.Cancel();
				return Err(e);
			}
		}
	}
}
fn discover(stop: &AtomicBool) -> Result<Vec<Device>> {
	let operation =
		DeviceInformation::FindAllAsyncAqsFilter(&AudioPlaybackConnection::GetDeviceSelector()?)?;
	let deadline = Instant::now() + Duration::from_secs(10);
	loop {
		match check_wait(operation.Status()?, deadline, stop) {
			Ok(true) => {}
			Ok(false) => break,
			Err(e) => {
				let _ = operation.Cancel();
				return Err(e);
			}
		}
	}
	let collection = operation.GetResults()?;
	let mut devices = Vec::new();
	for n in 0..collection.Size()? {
		let device = collection.GetAt(n)?;
		// This is an audio interface: IsPaired may be false even for a paired phone.
		devices.push(Device {
			id: device.Id()?.to_string(),
			name: device.Name()?.to_string(),
		});
	}
	devices.sort_by(|a, b| a.name.cmp(&b.name));
	Ok(devices)
}

fn capture_id(interface: &str) -> Result<String> {
	let instance = instance_id(interface)?;
	let root = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(
		r"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture",
		KEY_READ | KEY_WOW64_64KEY,
	)?;
	let mut matches = Vec::new();
	for name in root.enum_keys() {
		let name = name?;
		let properties = root.open_subkey(format!(r"{name}\Properties"))?;
		let Ok(stored): std::result::Result<String, _> =
			properties.get_value("{b3f8fa53-0004-438e-9003-51a46e139bfc},2")
		else {
			continue;
		};
		if stored
			.strip_prefix("{1}.")
			.unwrap_or(&stored)
			.eq_ignore_ascii_case(&instance)
		{
			matches.push(format!("{{0.0.1.00000000}}.{name}"));
		}
	}
	if matches.len() != 1 {
		bail!(
			"Cannot uniquely resolve this phone's private capture endpoint; playback stayed closed"
		);
	}
	Ok(matches.remove(0))
}

struct Session {
	connection: Option<AudioPlaybackConnection>,
	store: IPropertyStore,
	output: String,
	relay: Option<super::relay::Relay>,
	source_id: String,
	status_path: PathBuf,
	hub: Arc<super::hub::Hub>,
}
pub(super) fn disable_native_listen(config: &Path) -> Result<()> {
	let settings = Settings::load(&config.with_file_name("phone.toml"))?;
	let Some(id) = settings.device_id else {
		return Ok(());
	};
	unsafe {
		let _ = RoInitialize(RO_INIT_MULTITHREADED);
		let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
		let source = en.GetDevice(&HSTRING::from(capture_id(&id)?))?;
		let store = source.OpenPropertyStore(STGM_READWRITE)?;
		store.SetValue(&key(1), &PROPVARIANT::from(false))?;
		store.Commit()?;
	}
	Ok(())
}
impl Session {
	fn start(
		phone: &Device,
		target: &Device,
		config: &Path,
		stop: &AtomicBool,
		hub: Arc<super::hub::Hub>,
	) -> Result<Self> {
		unsafe {
			let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
			let capture_id = capture_id(&phone.id)?;
			// GetDevice can open this endpoint even though Windows hides it from its UI.
			let source = en.GetDevice(&HSTRING::from(&capture_id))?;
			let store = source.OpenPropertyStore(STGM_READWRITE)?;
			let backup = config.with_file_name(format!(
				"phone-listen-backup-{}.json",
				capture_id.rsplit('.').next().unwrap_or("endpoint")
			));
			if !backup.exists() {
				let old = store.GetValue(&key(0))?;
				let enabled = bool::try_from(&store.GetValue(&key(1))?).ok();
				crate::control::atomic_write(
					&backup,
					&serde_json::to_vec_pretty(&serde_json::json!({
						"captureId":capture_id, "output":BSTR::try_from(&old).ok().map(|s| s.to_string()),
						"enabled":enabled, "originalOutputVariant":format!("{old:?}")
					}))?,
				)?;
			}
			let mut session = Self {
				connection: None,
				store,
				output: String::new(),
				relay: None,
				source_id: capture_id,
				status_path: config.with_file_name("phone-buffer-status.json"),
				hub: hub.clone(),
			};
			// Explicit physical destination BEFORE enabling Listen or opening Bluetooth.
			session.route(target)?;
			session.store.SetValue(
				&key(1),
				&PROPVARIANT::from(hub.main_gate.load(Ordering::Acquire)),
			)?;
			session.store.Commit()?;
			let connection = AudioPlaybackConnection::TryCreateFromId(&HSTRING::from(&phone.id))?;
			session.connection = Some(connection.clone());
			// Retain the discovery ID. Do not call Connection.DeviceId (Windows API bug).
			wait_action(&connection.StartAsync()?, stop)?;
			Ok(session)
		}
	}
	fn route(&mut self, target: &Device) -> Result<()> {
		unsafe {
			let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
			let device = en.GetDevice(&HSTRING::from(&target.id))?;
			let mut state = 0;
			device.GetState(&mut state);
			if state != DEVICE_STATE_ACTIVE.0 {
				bail!("Listening output is unavailable; phone playback will disconnect");
			}
			if self.output == target.id {
				return Ok(());
			}
			let mut value = PROPVARIANT::new();
			// PROPVARIANT::from(&str) makes VT_BSTR, which this Windows property ignores.
			PropVariantChangeType(
				&mut value,
				&PROPVARIANT::from(target.id.as_str()),
				PVCHF_DEFAULT,
				VT_LPWSTR,
			)?;
			self.store.SetValue(&key(0), &value)?;
			self.store.Commit()?;
			let readback = BSTR::try_from(&self.store.GetValue(&key(0))?)?.to_string();
			if !readback.eq_ignore_ascii_case(&target.id) {
				bail!("Windows did not accept the private phone destination");
			}
			self.output.clone_from(&target.id);
			if let Some(relay) = &self.relay {
				relay.output(&target.id);
			}
			Ok(())
		}
	}
	fn is_open(&self) -> Result<bool> {
		Ok(self
			.connection
			.as_ref()
			.context("Phone receiver registration missing")?
			.State()?
			== AudioPlaybackConnectionState::Opened)
	}
	fn start_capture(&mut self) {
		if self.relay.is_none() {
			self.relay = Some(super::relay::Relay::start(
				self.source_id.clone(),
				self.output.clone(),
				self.status_path.clone(),
				self.hub.clone(),
			));
		}
	}
	fn stop_capture(&mut self) {
		drop(self.relay.take());
	}
	fn meter(&self) -> Result<Option<crate::MeterReading>> {
		self.relay.as_ref().map(|r| r.meter()).unwrap_or(Ok(None))
	}
	fn ready(&self) -> bool {
		self.is_open().unwrap_or(false) && self.relay.as_ref().is_some_and(|r| r.ready())
	}
}
impl Drop for Session {
	fn drop(&mut self) {
		drop(self.relay.take());
		unsafe {
			// Never restore "default output": that could expose phone audio to VAC.
			let _ = self
				.store
				.SetValue(&key(1), &PROPVARIANT::from(false))
				.and_then(|_| self.store.Commit());
		}
		if let Some(connection) = self.connection.take() {
			let _ = connection.Close();
		}
	}
}

fn schedule_reconnect(
	session: &mut Option<Session>,
	retry: &mut super::recovery::RetryBackoff,
	next_try: &mut Instant,
	state: &mut Snapshot,
	reason: String,
) {
	// Drop fully before restarting: two phone owners must never overlap.
	schedule_retry(
		session,
		retry,
		next_try,
		state,
		reason,
		RetryComponent::Registration,
	);
}

fn schedule_retry(
	session: &mut Option<Session>,
	retry: &mut super::recovery::RetryBackoff,
	next_try: &mut Instant,
	state: &mut Snapshot,
	reason: String,
	component: RetryComponent,
) {
	if component.withdraws_receiver() {
		*session = None;
	} else if component == RetryComponent::Capture {
		if let Some(current) = session.as_mut() {
			current.stop_capture();
		}
	}
	let delay = retry.failed();
	*next_try = Instant::now() + delay;
	let component = component.name();
	tracing::warn!(error = %reason, retry_seconds = delay.as_secs(), component, "retrying phone component");
	state.error = Some(format!(
		"{reason}. Retrying {component} in {} seconds.",
		delay.as_secs()
	));
}

fn publish_snapshot(path: &Path, state: &Snapshot, shared: &Mutex<Snapshot>) {
	*shared.lock().unwrap() = state.clone();
	if let Ok(bytes) = serde_json::to_vec_pretty(state) {
		if let Err(error) =
			crate::control::atomic_write(&path.with_file_name("phone-status.json"), &bytes)
		{
			tracing::warn!(%error, "could not publish phone status");
		}
	}
}

pub(super) fn run(
	config_path: PathBuf,
	receiver: mpsc::Receiver<Message>,
	shared: Arc<Mutex<Snapshot>>,
	levels: Arc<Mutex<Option<crate::MeterReading>>>,
	stop: Arc<AtomicBool>,
	wakeup: mpsc::Sender<Message>,
	hub: Arc<super::hub::Hub>,
) {
	let path = config_path.with_file_name("phone.toml");
	let result = || -> Result<()> {
		unsafe {
			RoInitialize(RO_INIT_MULTITHREADED)?;
		}
		let mut state = Snapshot {
			settings: Settings::load(&path)?,
			..Default::default()
		};
		state.wanted = state.settings.auto_connect;
		match discover(&stop) {
			Ok(devices) => state.devices = devices,
			Err(e) => state.error = Some(format!("{e:#}")),
		}
		// Event-driven discovery, including pairing/unpairing while the UI is hidden.
		let watcher =
			DeviceInformation::CreateWatcherAqsFilter(&AudioPlaybackConnection::GetDeviceSelector()?)?;
		let added = wakeup.clone();
		watcher.Added(&TypedEventHandler::<DeviceWatcher, DeviceInformation>::new(
			move |_, _| {
				let _ = added.send(Message::Discover);
				Ok(())
			},
		))?;
		watcher.Removed(
			&TypedEventHandler::<DeviceWatcher, DeviceInformationUpdate>::new(move |_, _| {
				let _ = wakeup.send(Message::Discover);
				Ok(())
			}),
		)?;
		watcher.Start()?;
		*shared.lock().unwrap() = state.clone();
		let mut session: Option<Session> = None;
		let mut output: Option<Device> = None;
		let mut next_try = Instant::now();
		let mut retry = super::recovery::RetryBackoff::default();
		let clock = Instant::now();
		let mut published = None;
		let telemetry = super::ipc::publisher();
		let mut next_output_check = Instant::now();
		while !stop.load(Ordering::Acquire) {
			if Instant::now() >= next_output_check {
				output = crate::Config::load(&config_path)
					.ok()
					.and_then(|config| crate::graph_snapshot(&config).ok())
					.and_then(|graph| {
						super::applied_output(&graph, crate::control::status(&config_path).ok().as_ref())
					});
				next_output_check = Instant::now() + Duration::from_secs(2);
			}
			let mut message = if session.is_some() {
				receiver.recv_timeout(Duration::from_millis(33)).ok()
			} else {
				receiver.recv_timeout(Duration::from_millis(250)).ok()
			};
			let mut receipt = None;
			if message.is_none() {
				if let Some(envelope) = super::ipc::next(&path)? {
					let (tx, rx) = mpsc::channel();
					message = Some(Message::Edit(envelope.request, tx));
					receipt = Some((envelope.id, rx));
				}
			}
			if let Some(message) = message {
				match message {
					Message::Stop => break,
					Message::Discover => {
						let previously_present = state
							.devices
							.iter()
							.any(|d| Some(&d.id) == state.settings.device_id.as_ref());
						match discover(&stop) {
							Ok(devices) => state.devices = devices,
							Err(e) => state.error = Some(format!("{e:#}")),
						}
						// Unrelated discovery events must not defeat failure backoff.
						if !previously_present
							&& state
								.devices
								.iter()
								.any(|d| Some(&d.id) == state.settings.device_id.as_ref())
						{
							retry.reset();
							next_try = Instant::now();
						}
					}
					Message::Restart => {
						session = None;
						retry.reset();
						next_try = Instant::now();
					}
					Message::Output(value) => {
						output = value;
					}
					Message::Edit(request, reply) => {
						let edit = || -> Result<()> {
							request.validate()?;
							if request.action == "quiesce" {
								state.wanted = false;
								session = None;
								return Ok(());
							}
							if request.action == "refresh" {
								state.devices = discover(&stop)?;
								return Ok(());
							}
							let mut settings = state.settings.clone();
							if let Some(id) = request.device_id {
								if !state.devices.iter().any(|d| d.id == id) {
									bail!("Select an available paired phone");
								}
								settings.device_id = Some(id);
							}
							if let Some(value) = request.auto_connect {
								settings.auto_connect = value;
							}
							if matches!(request.action.as_str(), "connect" | "reconnect")
								&& settings.device_id.is_none()
							{
								bail!("Select a paired phone first");
							}
							settings.save(&path)?;
							if settings.device_id != state.settings.device_id {
								session = None;
								retry.reset();
								next_try = Instant::now();
							}
							state.settings = settings;
							if matches!(request.action.as_str(), "connect" | "reconnect") {
								state.wanted = true;
								if request.action == "reconnect" {
									session = None;
								}
								retry.reset();
								next_try = Instant::now();
							}
							if request.action == "disconnect" {
								state.wanted = false;
								session = None;
								retry.reset();
							}
							state.error = None;
							Ok(())
						};
						let result = edit().map_err(|e| format!("{e:#}"));
						if let Err(error) = &result {
							state.error = Some(error.clone());
						}
						let _ = reply.send(result);
					}
				}
			}
			if let Some((id, rx)) = receipt {
				super::ipc::reply(
					&path,
					&id,
					rx.try_recv()
						.unwrap_or_else(|_| Err("Phone command did not complete".into())),
				)?;
			}
			if !state.wanted || output.is_none() {
				session = None;
			}
			if let (Some(current), Some(target)) = (session.as_mut(), output.as_ref()) {
				if let Err(error) = current.route(target) {
					schedule_reconnect(
						&mut session,
						&mut retry,
						&mut next_try,
						&mut state,
						format!("{error:#}"),
					);
				}
			}
			if state.wanted && session.is_none() && output.is_some() && Instant::now() >= next_try {
				state.phase = "connecting".into();
				state.connected = false;
				state.output = None;
				*levels.lock().unwrap() = None;
				super::ipc::publish(telemetry.as_ref(), None);
				publish_snapshot(&path, &state, &shared);
				published = Some(state.clone());
				let phone = state
					.devices
					.iter()
					.find(|d| Some(&d.id) == state.settings.device_id.as_ref());
				let result = phone
					.context("Selected phone is unavailable; refresh the paired device list")
					.and_then(|phone| {
						Session::start(phone, output.as_ref().unwrap(), &path, &stop, hub.clone())
					});
				match result {
					Ok(current) => {
						session = Some(current);
					}
					Err(error) => {
						schedule_reconnect(
							&mut session,
							&mut retry,
							&mut next_try,
							&mut state,
							format!("{error:#}"),
						);
					}
				}
			}
			if let Some(current) = session.as_mut() {
				match current.is_open() {
					Ok(false) => current.stop_capture(),
					Err(error) => schedule_reconnect(
						&mut session,
						&mut retry,
						&mut next_try,
						&mut state,
						format!("{error:#}"),
					),
					_ => {}
				}
			}
			if let Some(current) = session.as_mut() {
				if current.is_open().unwrap_or(false) && Instant::now() >= next_try {
					current.start_capture();
				}
			}
			*levels.lock().unwrap() = match session.as_ref().map(Session::meter).transpose() {
				Ok(reading) => reading.flatten(),
				Err(error) => {
					// A WASAPI failure is not a reason to withdraw Bluetooth service.
					schedule_retry(
						&mut session,
						&mut retry,
						&mut next_try,
						&mut state,
						format!("{error:#}"),
						RetryComponent::Capture,
					);
					None
				}
			};
			state.connected = session.as_ref().is_some_and(Session::ready);
			retry.observe(clock.elapsed(), state.connected);
			if state.connected {
				state.error = None;
			}
			super::ipc::publish(telemetry.as_ref(), levels.lock().unwrap().as_ref());
			state.output = if state.connected && hub.main_gate.load(Ordering::Acquire) {
				output.clone()
			} else {
				None
			};
			state.phase = if state.connected {
				"connected"
			} else if !state.wanted {
				"off"
			} else if output.is_none() {
				"waiting for Main Output"
			} else if session
				.as_ref()
				.is_some_and(|s| s.is_open().unwrap_or(false))
			{
				"receiver available — select PC and play audio on phone"
			} else if session.is_some() {
				"receiver available — connect from your phone"
			} else {
				"waiting for receiver registration"
			}
			.into();
			if published.as_ref() != Some(&state) {
				publish_snapshot(&path, &state, &shared);
				published = Some(state.clone());
			}
		}
		drop(session);
		let _ = watcher.Stop();
		Ok(())
	};
	if let Err(error) = result() {
		let mut state = shared.lock().unwrap();
		state.error = Some(format!("{error:#}"));
		state.phase = "unavailable".into();
	}
	*levels.lock().unwrap() = None;
	let mut state = shared.lock().unwrap();
	state.connected = false;
	state.output = None;
	if stop.load(Ordering::Acquire) {
		state.phase = "stopped".into();
	}
	if let Ok(bytes) = serde_json::to_vec_pretty(&*state) {
		let _ = crate::control::atomic_write(&path.with_file_name("phone-status.json"), &bytes);
	}
}
