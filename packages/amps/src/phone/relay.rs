//! Dedicated phone-only WASAPI pump. Slow Bluetooth discovery/control calls must
//! never block this thread or the game/microphone engine's existing audio threads.
use super::{
	buffer::{Buffer, RATE},
	*,
};
use ::windows::{
	core::{w, HSTRING, PROPVARIANT},
	Win32::{
		Foundation::HANDLE,
		Media::Audio::*,
		System::{
			Com::*,
			Threading::{AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW},
			WinRT::*,
		},
	},
};
use std::{path::PathBuf, time::Instant};

#[derive(Default)]
struct State {
	meter: Option<crate::MeterReading>,
	error: Option<String>,
	health: Option<serde_json::Value>,
	ready: bool,
}
pub(super) struct Relay {
	stop: Arc<AtomicBool>,
	output: Arc<Mutex<String>>,
	state: Arc<Mutex<State>>,
	status_path: PathBuf,
	last_publish: Mutex<Instant>,
	worker: Option<thread::JoinHandle<()>>,
}
impl Relay {
	pub fn start(
		source: String,
		output_id: String,
		status: PathBuf,
		hub: Arc<super::hub::Hub>,
	) -> Self {
		let stop = Arc::new(AtomicBool::new(false));
		let output = Arc::new(Mutex::new(output_id));
		let state = Arc::new(Mutex::new(State::default()));
		let (halt, target, shared) = (stop.clone(), output.clone(), state.clone());
		let worker = thread::Builder::new()
			.name("amps-phone-capture".into())
			.spawn(move || {
				if let Err(error) = run(source, target, &shared, &halt, &hub) {
					let mut state = shared.lock().unwrap();
					state.ready = false;
					state.meter = None;
					state.error = Some(format!("Phone receiver: {error:#}"));
					if let Some(health) = state.health.as_mut() {
						health["captureReady"] = false.into();
						health["mode"] = "receiver failed".into();
						health["error"] = format!("{error:#}").into();
						health["updatedAt"] = unix_seconds().into();
					}
				}
			})
			.expect("could not start phone buffer");
		Self {
			stop,
			output,
			state,
			status_path: status,
			last_publish: Mutex::new(Instant::now()),
			worker: Some(worker),
		}
	}
	pub fn output(&self, id: &str) {
		*self.output.lock().unwrap() = id.into();
	}
	pub fn ready(&self) -> bool {
		self.state.lock().unwrap().ready
	}
	pub fn meter(&self) -> Result<Option<crate::MeterReading>> {
		let state = self.state.lock().unwrap();
		let (meter, health, error) = (
			state.meter.clone(),
			state.health.clone(),
			state.error.clone(),
		);
		drop(state);
		// Diagnostic writes happen on the control thread, never the audio pump.
		let mut last = self.last_publish.lock().unwrap();
		if last.elapsed() >= Duration::from_secs(1) || error.is_some() {
			if let Some(health) = health {
				if let Ok(bytes) = serde_json::to_vec_pretty(&health) {
					let _ = crate::control::atomic_write(&self.status_path, &bytes);
				}
			}
			*last = Instant::now();
		}
		if let Some(error) = error {
			bail!("{error}");
		}
		Ok(meter)
	}
}
impl Drop for Relay {
	fn drop(&mut self) {
		self.stop.store(true, Ordering::Release);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
	}
}
struct Client(IAudioClient);
struct ListenGuard(::windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore);
impl ListenGuard {
	unsafe fn enable(&self, enabled: bool) -> Result<()> {
		self
			.0
			.SetValue(&super::windows::key(1), &PROPVARIANT::from(enabled))?;
		self.0.Commit()?;
		if bool::try_from(&self.0.GetValue(&super::windows::key(1))?)? != enabled {
			bail!("Windows did not accept the phone playback mode");
		}
		Ok(())
	}
}
impl Drop for ListenGuard {
	fn drop(&mut self) {
		unsafe {
			let _ = self.enable(false);
		}
	}
}
fn measure(samples: &[f32], peak: &mut f32, waveform: &mut Vec<f32>) {
	for &sample in samples {
		*peak = peak.max(sample.abs());
	}
	*waveform = samples
		.chunks_exact(2)
		.step_by((samples.len() / 2 / 128).max(1))
		.take(128)
		.map(|v| (v[0] + v[1]) * 0.5)
		.collect();
}
struct AudioPriority(Option<HANDLE>);
impl Drop for AudioPriority {
	fn drop(&mut self) {
		if let Some(handle) = self.0 {
			unsafe {
				let _ = AvRevertMmThreadCharacteristics(handle);
			}
		}
	}
}
impl Drop for Client {
	fn drop(&mut self) {
		unsafe {
			let _ = self.0.Stop();
		}
	}
}
unsafe fn client(device: &IMMDevice, duration: i64) -> Result<Client> {
	let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
	let format = WAVEFORMATEX {
		wFormatTag: 3,
		nChannels: 2,
		nSamplesPerSec: RATE as u32,
		nAvgBytesPerSec: (RATE * 8) as u32,
		nBlockAlign: 8,
		wBitsPerSample: 32,
		cbSize: 0,
	};
	client.Initialize(
		AUDCLNT_SHAREMODE_SHARED,
		AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
		duration,
		0,
		&format,
		None,
	)?;
	Ok(Client(client))
}
struct Render {
	client: Client,
	service: IAudioRenderClient,
	frames: u32,
	started: bool,
}
unsafe fn render(en: &IMMDeviceEnumerator, id: &str) -> Result<Render> {
	// Always explicit: no default endpoint lookup, VAC route, or silent fallback.
	let device = en.GetDevice(&HSTRING::from(id))?;
	// The jitter reservoir cannot protect samples already handed to WASAPI from
	// a missed scheduling deadline. Give the phone's final render queue 100 ms
	// too; this does not change latency for any game or microphone stream.
	let client = client(&device, 1_000_000)?;
	let service = client.0.GetService()?;
	let frames = client.0.GetBufferSize()?;
	Ok(Render {
		client,
		service,
		frames,
		started: false,
	})
}
fn run(
	source_id: String,
	output: Arc<Mutex<String>>,
	shared: &Mutex<State>,
	stop: &AtomicBool,
	hub: &super::hub::Hub,
) -> Result<()> {
	unsafe {
		RoInitialize(RO_INIT_MULTITHREADED)?;
		let mut task = 0;
		let _priority = AudioPriority(AvSetMmThreadCharacteristicsW(w!("Audio"), &mut task).ok());
		let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
		let source = en.GetDevice(&HSTRING::from(&source_id))?;
		let listen = ListenGuard(source.OpenPropertyStore(STGM_READWRITE)?);
		let started_at = Instant::now();
		let mut endpoint_watch = super::recovery::EndpointWatch::default();
		while !stop.load(Ordering::Acquire) {
			let mut active = 0;
			source.GetState(&mut active);
			let waiting =
				endpoint_watch.observe(started_at.elapsed(), active == DEVICE_STATE_ACTIVE.0);
			shared.lock().unwrap().health = Some(serde_json::json!({
				"mode": "waiting for phone playback", "receivedFrames": 0,
				"captureReady": false, "endpointState": active,
				"waitingForPlayback": waiting,
				"updatedAt": unix_seconds(),
			}));
			if active == DEVICE_STATE_ACTIVE.0 {
				break;
			}
			thread::sleep(Duration::from_millis(50));
		}
		if stop.load(Ordering::Acquire) {
			return Ok(());
		}
		// Hold capture open before reconciling the private native Listen route.
		let input = client(&source, 3_000_000)?;
		let capture: IAudioCaptureClient = input.0.GetService()?;
		input.0.Start()?;
		let mut target = output.lock().unwrap().clone();
		let mut audible = hub.main_gate.load(Ordering::Acquire);
		listen.enable(audible)?;
		{
			let mut state = shared.lock().unwrap();
			state.ready = true;
			state.health = Some(serde_json::json!({
				"mode": "direct", "receivedFrames": 0, "captureReady": true,
				"endpointState": DEVICE_STATE_ACTIVE.0, "updatedAt": unix_seconds(),
				"outputId": target, "mainOutputConnected": audible,
			}));
		}
		let mut report = Instant::now();
		let mut endpoint_check = Instant::now();
		let mut capture_ready = true;
		let mut meter_tick = Instant::now();
		let mut peak = 0f32;
		let mut waveform = Vec::new();
		let mut received = 0u64;
		let mut last_pump = Instant::now();
		let mut max_pump_gap_ms = 0u128;
		let mut capture_position_gaps = 0u64;
		let mut expected_capture_position = None;
		while !stop.load(Ordering::Acquire) {
			if endpoint_check.elapsed() >= Duration::from_millis(250) {
				let mut active = 0;
				source.GetState(&mut active);
				let ready = active == DEVICE_STATE_ACTIVE.0;
				capture_ready = ready;
				let mut state = shared.lock().unwrap();
				state.ready = ready;
				if !ready {
					state.meter = None;
					state.health = Some(serde_json::json!({
						"mode": "waiting for phone playback", "receivedFrames": received,
						"captureReady": false, "endpointState": active,
						"waitingForPlayback": true,
						"updatedAt": unix_seconds(),
					}));
				}
				drop(state);
				// Idle/paused is not proof of a dead transport. Real capture API
				// errors restart this pump, without unregistering Bluetooth.
				endpoint_check = Instant::now();
			}
			if !capture_ready {
				thread::sleep(Duration::from_millis(50));
				continue;
			}
			max_pump_gap_ms = max_pump_gap_ms.max(last_pump.elapsed().as_millis());
			last_pump = Instant::now();
			let desired = output.lock().unwrap().clone();
			let desired_audible = hub.main_gate.load(Ordering::Acquire);
			if desired != target || desired_audible != audible {
				audible = desired_audible;
				listen.enable(audible)?;
				target = desired;
			}
			while capture.GetNextPacketSize()? > 0 {
				let mut data = std::ptr::null_mut();
				let mut frames = 0;
				let mut flags = 0;
				let mut position = 0;
				capture.GetBuffer(
					&mut data,
					&mut frames,
					&mut flags,
					Some(&mut position),
					None,
				)?;
				if flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0 as u32 == 0 {
					if expected_capture_position.is_some_and(|expected| expected != position) {
						capture_position_gaps += 1;
					}
					expected_capture_position = Some(position + frames as u64);
				} else {
					expected_capture_position = None;
				}
				if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || data.is_null() {
					let silence = vec![0.0; frames as usize * 2];
					hub.publish(&silence);
					waveform.clear();
				} else {
					let samples = std::slice::from_raw_parts(data.cast::<f32>(), frames as usize * 2);
					hub.publish(samples);
					measure(samples, &mut peak, &mut waveform);
				}
				received += frames as u64;
				capture.ReleaseBuffer(frames)?;
			}
			if meter_tick.elapsed() >= Duration::from_millis(33) {
				shared.lock().unwrap().meter = Some(crate::MeterReading {
					id: "phone".into(),
					peak,
					dbfs: if peak > 0.0 {
						20.0 * peak.log10()
					} else {
						f32::NEG_INFINITY
					},
					waveform: waveform.clone(),
				});
				peak = 0.0;
				waveform.clear();
				meter_tick = Instant::now();
			}
			if report.elapsed() >= Duration::from_secs(5) {
				// Aggregate health only. Never persist PCM or notification contents.
				shared.lock().unwrap().health = Some(serde_json::json!({
					"mode": "direct", "receivedFrames": received,
					"captureReady": true, "endpointState": DEVICE_STATE_ACTIVE.0,
					"mainOutputConnected": audible,
					"maxPumpGapMs": max_pump_gap_ms, "capturePositionGaps": capture_position_gaps,
					"outputId": target, "updatedAt": unix_seconds()
				}));
				report = Instant::now();
			}
			thread::sleep(Duration::from_millis(3));
		}
		Ok(())
	}
}

fn unix_seconds() -> u64 {
	std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap_or_default()
		.as_secs()
}

/// One phone cross-patch render clock. The shared receiver never waits for it.
pub(crate) struct Fanout {
	stop: Arc<AtomicBool>,
	worker: Option<thread::JoinHandle<()>>,
	#[cfg(test)]
	rendered: Arc<std::sync::atomic::AtomicU64>,
}
impl Drop for Fanout {
	fn drop(&mut self) {
		self.stop.store(true, Ordering::Release);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
	}
}
impl Fanout {
	pub fn start(
		hub: Arc<super::hub::Hub>,
		output: String,
		gate: Arc<AtomicBool>,
		failed: Arc<AtomicBool>,
	) -> Result<Self> {
		let subscription = hub.subscribe()?;
		let stop = Arc::new(AtomicBool::new(false));
		let halt = stop.clone();
		#[cfg(test)]
		let rendered = Arc::new(std::sync::atomic::AtomicU64::new(0));
		#[cfg(test)]
		let rendered_worker = rendered.clone();
		let (ready, receipt) = mpsc::channel();
		let worker = thread::Builder::new()
			.name("amps-phone-patch".into())
			.spawn(move || {
				let result = (|| -> Result<()> {
					unsafe {
						RoInitialize(RO_INIT_MULTITHREADED)?;
						let mut task = 0;
						let _priority =
							AudioPriority(AvSetMmThreadCharacteristicsW(w!("Audio"), &mut task).ok());
						let en: IMMDeviceEnumerator =
							CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
						let mut render = render(&en, &output)?;
						let mut buffer = Buffer::new(100);
						let mut last = Instant::now();
						let _ = ready.send(Ok(()));
						let mut input = Vec::with_capacity(RATE * 2);
						while !halt.load(Ordering::Acquire) {
							let ms = 100;
							buffer.set_target(ms);
							input.clear();
							while let Some(frame) = subscription.queue.pop() {
								input.extend_from_slice(&frame);
							}
							if !input.is_empty() {
								buffer.push(&input);
								last = Instant::now();
							}
							let padding = render.client.0.GetCurrentPadding()?;
							let available = render.frames.saturating_sub(padding);
							if available > 0 {
								let data = render.service.GetBuffer(available)?;
								let samples = std::slice::from_raw_parts_mut(
									data.cast::<f32>(),
									available as usize * 2,
								);
								buffer.render(samples, last.elapsed() > Duration::from_millis(ms as u64));
								if !gate.load(Ordering::Acquire) {
									samples.fill(0.0);
								}
								render.service.ReleaseBuffer(available, 0)?;
								#[cfg(test)]
								rendered_worker.fetch_add(available as u64, Ordering::Relaxed);
								if !render.started {
									render.client.0.Start()?;
									render.started = true;
								}
							}
							thread::sleep(Duration::from_millis(3));
						}
						Ok(())
					}
				})();
				if let Err(error) = result {
					let _ = ready.send(Err(format!("{error:#}")));
					failed.store(true, Ordering::Release);
				}
			})?;
		let mut route = Self {
			stop,
			worker: Some(worker),
			#[cfg(test)]
			rendered,
		};
		match receipt.recv_timeout(Duration::from_secs(5)) {
			Ok(Ok(())) => Ok(route),
			other => {
				route.stop.store(true, Ordering::Release);
				if let Some(worker) = route.worker.take() {
					let _ = worker.join();
				}
				bail!("Phone output could not be staged: {other:?}")
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	#[ignore = "requires AMPS_TEST_OUTPUT_A/B endpoint IDs; renders silence only"]
	fn two_native_outputs_render_independently_without_private_audio() {
		let hub = super::super::hub::Hub::new();
		let gate = Arc::new(AtomicBool::new(false));
		let failed_a = Arc::new(AtomicBool::new(false));
		let failed_b = Arc::new(AtomicBool::new(false));
		let a = Fanout::start(
			hub.clone(),
			std::env::var("AMPS_TEST_OUTPUT_A").unwrap(),
			gate.clone(),
			failed_a.clone(),
		)
		.unwrap();
		let b = Fanout::start(
			hub.clone(),
			std::env::var("AMPS_TEST_OUTPUT_B").unwrap(),
			gate.clone(),
			failed_b.clone(),
		)
		.unwrap();
		for _ in 0..100 {
			hub.publish(&[0.0; 882]);
			thread::sleep(Duration::from_millis(10));
		}
		assert!(!failed_a.load(Ordering::Acquire) && !failed_b.load(Ordering::Acquire));
		assert!(a.rendered.load(Ordering::Acquire) > RATE as u64 / 2);
		assert!(b.rendered.load(Ordering::Acquire) > RATE as u64 / 2);
		drop(a);
		let before = b.rendered.load(Ordering::Acquire);
		thread::sleep(Duration::from_millis(100));
		assert!(b.rendered.load(Ordering::Acquire) > before);
	}
}
