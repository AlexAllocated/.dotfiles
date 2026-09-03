use std::{
	sync::mpsc::{self, Receiver, Sender, SyncSender},
	thread::{self, JoinHandle},
	time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use wasapi::{DeviceEnumerator, Direction as WasapiDirection};
use windows::{
	core::{implement, GUID, HSTRING, PCWSTR},
	Win32::{
		Media::Audio::{
			Endpoints::{
				IAudioEndpointVolume, IAudioEndpointVolumeCallback, IAudioEndpointVolumeCallback_Impl,
			},
			IMMDeviceEnumerator, MMDeviceEnumerator, AUDIO_VOLUME_NOTIFICATION_DATA,
		},
		System::Com::{CoCreateInstance, CLSCTX_ALL},
	},
};

const BRIDGE_EVENT_CONTEXT: GUID = GUID::from_u128(0xd7d9a7a8_5b42_47a9_a83f_47ae62a09531);
const DRIVER_SETTLE_TIME: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq)]
struct VolumeState {
	level: f32,
	muted: bool,
}

impl VolumeState {
	fn normalized(self) -> Self {
		Self {
			level: if self.level.is_finite() {
				self.level.clamp(0.0, 1.0)
			} else {
				1.0
			},
			muted: self.muted,
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EndpointSide {
	Control,
	Physical,
}

enum Message {
	Changed {
		side: EndpointSide,
		generation: u64,
		state: VolumeState,
	},
	Retarget {
		endpoint_id: String,
		reply: SyncSender<Result<()>>,
	},
	BeginGraphRebuild {
		reply: SyncSender<Result<()>>,
	},
	FinishGraphRebuild {
		reply: SyncSender<Result<()>>,
	},
	Stop,
}

#[implement(IAudioEndpointVolumeCallback)]
struct VolumeCallback {
	side: EndpointSide,
	generation: u64,
	sender: Sender<Message>,
}

#[allow(non_snake_case)]
impl IAudioEndpointVolumeCallback_Impl for VolumeCallback {
	fn OnNotify(
		&self,
		notification: *mut AUDIO_VOLUME_NOTIFICATION_DATA,
	) -> windows::core::Result<()> {
		if notification.is_null() {
			return Ok(());
		}
		let notification = unsafe { *notification };
		if notification.guidEventContext == BRIDGE_EVENT_CONTEXT {
			return Ok(());
		}
		let _ = self.sender.send(Message::Changed {
			side: self.side,
			generation: self.generation,
			state: VolumeState {
				level: notification.fMasterVolume,
				muted: notification.bMuted.as_bool(),
			}
			.normalized(),
		});
		Ok(())
	}
}

struct RegisteredEndpoint {
	volume: IAudioEndpointVolume,
	callback: IAudioEndpointVolumeCallback,
}

impl RegisteredEndpoint {
	fn open(
		endpoint_id: &str,
		side: EndpointSide,
		generation: u64,
		sender: Sender<Message>,
	) -> Result<Self> {
		let enumerator: IMMDeviceEnumerator =
			unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
				.context("could not enumerate Windows master-volume endpoints")?;
		let id = HSTRING::from(endpoint_id);
		let device = unsafe { enumerator.GetDevice(PCWSTR(id.as_ptr())) }
			.with_context(|| format!("could not open master-volume endpoint {endpoint_id}"))?;
		let volume: IAudioEndpointVolume = unsafe { device.Activate(CLSCTX_ALL, None) }
			.with_context(|| format!("could not activate master-volume endpoint {endpoint_id}"))?;
		let callback: IAudioEndpointVolumeCallback = VolumeCallback {
			side,
			generation,
			sender,
		}
		.into();
		unsafe { volume.RegisterControlChangeNotify(&callback) }
			.with_context(|| format!("could not subscribe to master-volume endpoint {endpoint_id}"))?;
		Ok(Self { volume, callback })
	}

	fn state(&self) -> Result<VolumeState> {
		Ok(VolumeState {
			level: unsafe { self.volume.GetMasterVolumeLevelScalar() }
				.context("could not read endpoint master volume")?,
			muted: unsafe { self.volume.GetMute() }
				.context("could not read endpoint mute state")?
				.as_bool(),
		}
		.normalized())
	}

	fn set_state(&self, state: VolumeState) -> Result<()> {
		let state = state.normalized();
		unsafe {
			self
				.volume
				.SetMasterVolumeLevelScalar(state.level, &BRIDGE_EVENT_CONTEXT)
		}
		.context("could not mirror endpoint master volume")?;
		unsafe { self.volume.SetMute(state.muted, &BRIDGE_EVENT_CONTEXT) }
			.context("could not mirror endpoint mute state")
	}
}

impl Drop for RegisteredEndpoint {
	fn drop(&mut self) {
		let _ = unsafe { self.volume.UnregisterControlChangeNotify(&self.callback) };
	}
}

pub(crate) struct MasterVolumeBridge {
	sender: Sender<Message>,
	worker: Option<JoinHandle<()>>,
	physical_endpoint_id: String,
}

impl MasterVolumeBridge {
	pub(crate) fn new(control_selector: &str, physical_selector: &str) -> Result<Self> {
		let control_endpoint_id = resolve_render_endpoint_id(control_selector)?;
		let physical_endpoint_id = resolve_render_endpoint_id(physical_selector)?;
		let (sender, receiver) = mpsc::channel();
		let worker_sender = sender.clone();
		let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
		let initial_physical_id = physical_endpoint_id.clone();
		let worker = thread::Builder::new()
			.name("audioarray-master-volume".into())
			.spawn(move || {
				let result = run_bridge(
					control_endpoint_id,
					initial_physical_id,
					worker_sender,
					receiver,
					ready_sender,
				);
				if let Err(error) = result {
					tracing::error!(error = %format!("{error:#}"), "master-volume bridge stopped");
				}
			})
			.context("could not start the AudioArray master-volume bridge")?;
		ready_receiver
			.recv_timeout(REQUEST_TIMEOUT)
			.context("master-volume bridge did not initialize")??;
		Ok(Self {
			sender,
			worker: Some(worker),
			physical_endpoint_id,
		})
	}

	pub(crate) fn retarget(&mut self, physical_selector: &str) -> Result<()> {
		let endpoint_id = resolve_render_endpoint_id(physical_selector)?;
		if endpoint_id == self.physical_endpoint_id {
			return Ok(());
		}
		self.request(|reply| Message::Retarget {
			endpoint_id: endpoint_id.clone(),
			reply,
		})?;
		self.physical_endpoint_id = endpoint_id;
		Ok(())
	}

	pub(crate) fn begin_graph_rebuild(&self) -> Result<()> {
		self.request(|reply| Message::BeginGraphRebuild { reply })
	}

	pub(crate) fn finish_graph_rebuild(&self) -> Result<()> {
		self.request(|reply| Message::FinishGraphRebuild { reply })
	}

	fn request(&self, message: impl FnOnce(SyncSender<Result<()>>) -> Message) -> Result<()> {
		let (reply_sender, reply_receiver) = mpsc::sync_channel(1);
		self
			.sender
			.send(message(reply_sender))
			.map_err(|_| anyhow!("master-volume bridge is not running"))?;
		reply_receiver
			.recv_timeout(REQUEST_TIMEOUT)
			.context("master-volume bridge request timed out")?
	}
}

impl Drop for MasterVolumeBridge {
	fn drop(&mut self) {
		let _ = self.sender.send(Message::Stop);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
	}
}

fn run_bridge(
	control_endpoint_id: String,
	physical_endpoint_id: String,
	sender: Sender<Message>,
	receiver: Receiver<Message>,
	ready: SyncSender<Result<()>>,
) -> Result<()> {
	let _ = wasapi::initialize_mta();
	let control = match RegisteredEndpoint::open(
		&control_endpoint_id,
		EndpointSide::Control,
		0,
		sender.clone(),
	) {
		Ok(endpoint) => endpoint,
		Err(error) => {
			let message = format!("{error:#}");
			let _ = ready.send(Err(anyhow!(message.clone())));
			return Err(anyhow!(message));
		}
	};
	let mut physical_generation = 1_u64;
	let mut physical = match RegisteredEndpoint::open(
		&physical_endpoint_id,
		EndpointSide::Physical,
		physical_generation,
		sender.clone(),
	) {
		Ok(endpoint) => endpoint,
		Err(error) => {
			let message = format!("{error:#}");
			let _ = ready.send(Err(anyhow!(message.clone())));
			return Err(anyhow!(message));
		}
	};
	let mut desired = match physical.state().and_then(|state| {
		control.set_state(state)?;
		Ok(state)
	}) {
		Ok(state) => state,
		Err(error) => {
			let message = format!("{error:#}");
			let _ = ready.send(Err(anyhow!(message.clone())));
			return Err(anyhow!(message));
		}
	};
	let mut physical_suspended = false;
	let mut ignore_physical_until: Option<Instant> = None;
	ready
		.send(Ok(()))
		.map_err(|_| anyhow!("master-volume bridge owner exited during initialization"))?;
	tracing::info!(
		level = desired.level,
		muted = desired.muted,
		"master-volume bridge started"
	);

	while let Ok(message) = receiver.recv() {
		match message {
			Message::Changed {
				side: EndpointSide::Control,
				state,
				..
			} => {
				desired = state;
				if !physical_suspended {
					if let Err(error) = physical.set_state(desired) {
						tracing::warn!(%error, "could not mirror Windows master volume; will retry after endpoint reconciliation");
					}
				}
				tracing::debug!(
					level = desired.level,
					muted = desired.muted,
					"mirrored Windows master volume to physical output"
				);
			}
			Message::Changed {
				side: EndpointSide::Physical,
				generation,
				state,
			} => {
				let settling = ignore_physical_until.is_some_and(|until| Instant::now() < until);
				if generation == physical_generation && !physical_suspended && !settling {
					desired = state;
					if let Err(error) = control.set_state(desired) {
						tracing::warn!(%error, "could not reflect physical output volume in the Windows master control");
					}
					tracing::debug!(
						level = desired.level,
						muted = desired.muted,
						"mirrored physical output volume to Windows master control"
					);
				}
			}
			Message::Retarget { endpoint_id, reply } => {
				let next_generation = physical_generation.wrapping_add(1);
				let result = RegisteredEndpoint::open(
					&endpoint_id,
					EndpointSide::Physical,
					next_generation,
					sender.clone(),
				)
				.and_then(|endpoint| {
					desired = endpoint.state()?;
					control.set_state(desired)?;
					physical_generation = next_generation;
					physical = endpoint;
					physical_suspended = false;
					ignore_physical_until = None;
					Ok(())
				});
				let _ = reply.send(result);
			}
			Message::BeginGraphRebuild { reply } => {
				physical_suspended = true;
				ignore_physical_until = None;
				let _ = reply.send(Ok(()));
			}
			Message::FinishGraphRebuild { reply } => {
				let result = physical.set_state(desired);
				if result.is_ok() {
					physical_suspended = false;
					ignore_physical_until = Some(Instant::now() + DRIVER_SETTLE_TIME);
				}
				let _ = reply.send(result);
			}
			Message::Stop => break,
		}
	}
	Ok(())
}

fn resolve_render_endpoint_id(selector: &str) -> Result<String> {
	let _ = wasapi::initialize_mta();
	let enumerator =
		DeviceEnumerator::new().context("could not enumerate Windows master-volume endpoints")?;
	let devices = enumerator
		.get_device_collection(&WasapiDirection::Render)
		.context("could not enumerate Windows render endpoint IDs")?;
	let mut matches = Vec::new();
	for device in &devices {
		let device = device?;
		let id = device.get_id()?;
		let name = device.get_friendlyname()?;
		if id.eq_ignore_ascii_case(selector)
			|| name.eq_ignore_ascii_case(selector)
			|| name
				.to_ascii_lowercase()
				.contains(&selector.to_ascii_lowercase())
		{
			matches.push((id, name));
		}
	}
	match matches.as_slice() {
		[(id, _)] => Ok(id.clone()),
		[] => Err(anyhow!(
			"master-volume render endpoint {selector:?} was not found"
		)),
		many => Err(anyhow!(
			"master-volume render selector {selector:?} is ambiguous: {}",
			many
				.iter()
				.map(|(_, name)| name.as_str())
				.collect::<Vec<_>>()
				.join(", ")
		)),
	}
}
