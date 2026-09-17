#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
	fs::{File, OpenOptions},
	io::Write,
	path::{Path, PathBuf},
	process::{Child, Command, Stdio},
	sync::{
		atomic::{AtomicBool, Ordering},
		Arc, Mutex, RwLock,
	},
	thread,
	time::{Duration, Instant},
};

use amps::{GraphSnapshot, MeterReading};
use serde::Serialize;
use tauri::{
	menu::{Menu, MenuItem},
	tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
	Emitter, Manager, RunEvent, WindowEvent,
};

#[cfg(windows)]
use std::os::windows::{io::AsRawHandle, process::CommandExt};

#[cfg(windows)]
use windows::core::w;

#[cfg(windows)]
use windows::Win32::{
	Foundation::{
		CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE, WAIT_FAILED, WAIT_OBJECT_0,
	},
	System::{
		JobObjects::{
			AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
			SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
			JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
		},
		Threading::{CreateEventW, CreateMutexW, SetEvent, WaitForSingleObject},
	},
};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[cfg(windows)]
struct InstanceGuard(HANDLE, HANDLE);

#[cfg(windows)]
impl InstanceGuard {
	fn acquire() -> std::io::Result<Option<Self>> {
		unsafe {
			// Stable across the AudioArray rename: never run both supervisors.
			let mutex = CreateMutexW(None, false, w!("Local\\HiveTech.AudioArray"))
				.map_err(|error| std::io::Error::other(error.to_string()))?;
			let primary = GetLastError() != ERROR_ALREADY_EXISTS;
			let show = CreateEventW(
				None,
				false,
				false,
				w!("Local\\HiveTech.AudioArray.ShowWindow"),
			)
			.map_err(|error| {
				let _ = CloseHandle(mutex);
				std::io::Error::other(error.to_string())
			})?;
			if primary {
				return Ok(Some(Self(mutex, show)));
			}

			let _ = CloseHandle(mutex);
			// Never reveal a hidden Tao/Tauri window with raw ShowWindow: that
			// bypasses the framework's visibility state used by close-to-tray.
			let signalled = SetEvent(show);
			let _ = CloseHandle(show);
			signalled.map_err(|error| std::io::Error::other(error.to_string()))?;
			Ok(None)
		}
	}
}

#[cfg(windows)]
impl Drop for InstanceGuard {
	fn drop(&mut self) {
		unsafe {
			let _ = CloseHandle(self.0);
			let _ = CloseHandle(self.1);
		}
	}
}

#[cfg(windows)]
struct EngineJob(HANDLE);

#[cfg(windows)]
impl EngineJob {
	fn new() -> std::io::Result<Self> {
		unsafe {
			let job = CreateJobObjectW(None, None)
				.map_err(|error| std::io::Error::other(error.to_string()))?;
			let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
			limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
			SetInformationJobObject(
				job,
				JobObjectExtendedLimitInformation,
				&limits as *const _ as *const std::ffi::c_void,
				std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
			)
			.map_err(|error| std::io::Error::other(error.to_string()))?;
			Ok(Self(job))
		}
	}

	fn assign(&self, child: &Child) -> std::io::Result<()> {
		unsafe {
			AssignProcessToJobObject(self.0, HANDLE(child.as_raw_handle() as isize))
				.map_err(|error| std::io::Error::other(error.to_string()))
		}
	}
}

#[cfg(windows)]
impl Drop for EngineJob {
	fn drop(&mut self) {
		unsafe {
			let _ = CloseHandle(self.0);
		}
	}
}

struct EngineControl {
	stop: AtomicBool,
	restart: AtomicBool,
	stopped: AtomicBool,
}

impl EngineControl {
	fn new() -> Self {
		Self {
			stop: AtomicBool::new(false),
			restart: AtomicBool::new(false),
			stopped: AtomicBool::new(false),
		}
	}
}
struct SupervisorFinished(Arc<EngineControl>);
impl Drop for SupervisorFinished {
	fn drop(&mut self) {
		self.0.stopped.store(true, Ordering::Release);
	}
}

struct UiState {
	config_path: PathBuf,
	meters: Arc<RwLock<Vec<MeterReading>>>,
	engine: Arc<EngineControl>,
	clean_mic_monitor: Mutex<Option<amps::CleanMicMonitor>>,
	phone: Arc<amps::phone::Client>,
}

fn load_config(state: &UiState) -> Result<amps::Config, String> {
	amps::Config::load(&state.config_path).map_err(|error| error.to_string())
}

#[tauri::command]
fn graph_snapshot(state: tauri::State<'_, UiState>) -> Result<GraphSnapshot, String> {
	let config = load_config(&state)?;
	amps::graph_snapshot(&config).map_err(|error| error.to_string())
}

#[derive(Serialize)]
struct CanvasSnapshot {
	graph: GraphSnapshot,
	runtime: Option<amps::control::Status>,
	topology: amps::topology::Topology,
	phone: amps::phone::Snapshot,
}

#[tauri::command]
fn routing_snapshot(state: tauri::State<'_, UiState>) -> Result<CanvasSnapshot, String> {
	let graph = graph_snapshot(state.clone())?;
	let runtime = amps::control::status(&state.config_path).ok();
	let patches = runtime
		.as_ref()
		.filter(|r| r.online && r.applied_revision.is_some())
		.map(|r| r.patches.as_slice())
		.unwrap_or(&graph.patches);
	let mut topology = amps::topology::project(&graph, patches, runtime.as_ref());
	let phone = state.phone.snapshot();
	amps::phone::append_topology(&mut topology, &phone);
	Ok(CanvasSnapshot {
		graph,
		runtime,
		topology,
		phone,
	})
}

#[tauri::command]
async fn phone_control(
	request: amps::phone::Request,
	state: tauri::State<'_, UiState>,
) -> Result<(), String> {
	let phone = state.phone.clone();
	tauri::async_runtime::spawn_blocking(move || phone.edit(request).map_err(|e| format!("{e:#}")))
		.await
		.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn edit_routing(
	request: amps::control::Request,
	state: tauri::State<'_, UiState>,
) -> Result<amps::control::Reply, String> {
	let path = state.config_path.clone();
	tauri::async_runtime::spawn_blocking(move || {
		amps::control::submit(&path, &request).map_err(|e| format!("{e:#}"))
	})
	.await
	.map_err(|e| e.to_string())?
}

#[tauri::command]
fn meter_snapshot(state: tauri::State<'_, UiState>) -> Result<Vec<MeterReading>, String> {
	state
		.meters
		.read()
		.map(|meters| meters.clone())
		.map_err(|_| "AMPS meter state is unavailable".to_string())
}

#[tauri::command]
async fn select_main_output(
	endpoint_id: String,
	state: tauri::State<'_, UiState>,
) -> Result<(), String> {
	let config = load_config(&state)?;
	tauri::async_runtime::spawn_blocking(move || {
		amps::select_main_output(&config, &endpoint_id).map_err(|error| error.to_string())
	})
	.await
	.map_err(|error| error.to_string())?
}

#[tauri::command]
fn select_main_input(endpoint_id: String) -> Result<(), String> {
	amps::select_main_input(&endpoint_id).map_err(|error| error.to_string())
}

#[tauri::command]
fn set_clean_mic_monitor(
	enabled: bool,
	state: tauri::State<'_, UiState>,
) -> Result<Option<String>, String> {
	let mut monitor = state
		.clean_mic_monitor
		.lock()
		.map_err(|_| "Clean Mic monitor state is unavailable".to_string())?;
	if enabled && monitor.is_none() {
		let config = load_config(&state)?;
		*monitor = Some(amps::CleanMicMonitor::new(&config).map_err(|error| error.to_string())?);
	} else if !enabled {
		*monitor = None;
	}
	Ok(monitor
		.as_ref()
		.map(|active| active.output_name().to_string()))
}

fn stop_clean_mic_monitor(state: &UiState) {
	if let Ok(mut monitor) = state.clean_mic_monitor.lock() {
		*monitor = None;
	}
}

fn show_main(app: &tauri::AppHandle) {
	if let Some(window) = app.get_webview_window("main") {
		let _ = window.show();
		let _ = window.unminimize();
		let _ = window.set_focus();
	}
}

#[cfg(windows)]
fn listen_for_show(event: isize, app: tauri::AppHandle, control: Arc<EngineControl>) {
	thread::spawn(move || {
		while !control.stop.load(Ordering::Acquire) {
			let result = unsafe { WaitForSingleObject(HANDLE(event), 1000) };
			if result == WAIT_FAILED {
				break;
			}
			if result == WAIT_OBJECT_0 {
				let target = app.clone();
				let _ = app.run_on_main_thread(move || show_main(&target));
			}
		}
	});
}

fn engine_log_path() -> PathBuf {
	std::env::var_os("LOCALAPPDATA")
		.map(PathBuf::from)
		.unwrap_or_else(std::env::temp_dir)
		.join("AMPS")
		.join("logs")
		.join("amps.log")
}

fn append_engine_log(log: &mut File, message: &str) {
	let _ = writeln!(log, "{message}");
}

fn spawn_engine(config_path: &Path, log: &File) -> std::io::Result<Child> {
	let engine_name = if cfg!(windows) { "amps.exe" } else { "amps" };
	let engine_path = std::env::current_exe()?
		.parent()
		.ok_or_else(|| std::io::Error::other("AMPS UI executable has no parent directory"))?
		.join(engine_name);
	let mut command = Command::new(engine_path);
	command
		.arg("--config")
		.arg(config_path)
		.arg("run")
		.stdin(Stdio::null())
		.stdout(Stdio::from(log.try_clone()?))
		.stderr(Stdio::from(log.try_clone()?));
	#[cfg(windows)]
	command.creation_flags(CREATE_NO_WINDOW);
	command.spawn()
}

fn supervise_engine(config_path: PathBuf, control: Arc<EngineControl>) {
	thread::Builder::new()
		.name("amps-engine-supervisor".into())
		.spawn(move || {
			let _finished = SupervisorFinished(control.clone());
			let log_path = engine_log_path();
			if let Some(parent) = log_path.parent() {
				let _ = std::fs::create_dir_all(parent);
			}
			let Ok(mut log) = OpenOptions::new().create(true).append(true).open(&log_path) else {
				return;
			};
			#[cfg(windows)]
			let job = match EngineJob::new() {
				Ok(job) => job,
				Err(error) => {
					append_engine_log(
						&mut log,
						&format!("AMPS engine job creation failed: {error}"),
					);
					return;
				}
			};
			while !control.stop.load(Ordering::Acquire) {
				control.restart.store(false, Ordering::Release);
				let mut child = match spawn_engine(&config_path, &log) {
					Ok(child) => child,
					Err(error) => {
						append_engine_log(&mut log, &format!("AMPS engine launch failed: {error}"));
						thread::sleep(Duration::from_secs(2));
						continue;
					}
				};
				#[cfg(windows)]
				if let Err(error) = job.assign(&child) {
					append_engine_log(
						&mut log,
						&format!("AMPS engine job assignment failed: {error}"),
					);
					let _ = child.kill();
					let _ = child.wait();
					thread::sleep(Duration::from_secs(2));
					continue;
				}
				loop {
					if control.stop.load(Ordering::Acquire)
						|| control.restart.swap(false, Ordering::AcqRel)
					{
						amps::phone::quiesce(&config_path);
						let _ = child.kill();
						let _ = child.wait();
						amps::phone::disable_native_listen(&config_path);
						break;
					}
					match child.try_wait() {
						Ok(Some(status)) => {
							append_engine_log(
								&mut log,
								&format!("AMPS engine exited with {status}; restarting"),
							);
							break;
						}
						Ok(None) => thread::sleep(Duration::from_millis(250)),
						Err(error) => {
							append_engine_log(&mut log, &format!("AMPS engine status failed: {error}"));
							let _ = child.kill();
							let _ = child.wait();
							break;
						}
					}
				}
				if !control.stop.load(Ordering::Acquire) {
					thread::sleep(Duration::from_millis(300));
				}
			}
		})
		.expect("AMPS could not start its engine supervisor");
}

fn main() {
	#[cfg(windows)]
	let _instance = match InstanceGuard::acquire() {
		Ok(Some(instance)) => instance,
		Ok(None) => return,
		Err(error) => panic!("AMPS could not establish its process lifecycle: {error}"),
	};

	let start_hidden = std::env::args().any(|argument| argument == "--tray");
	let config_path =
		amps::default_config_path().expect("AMPS could not determine its configuration path");
	let engine = Arc::new(EngineControl::new());
	let phone = Arc::new(amps::phone::Client::new(&config_path));
	let meter_phone = phone.clone();
	let meter_engine = engine.clone();

	let meters = Arc::new(RwLock::new(Vec::new()));
	let meter_state = meters.clone();
	let meter_config_path = config_path.clone();
	thread::Builder::new()
		.name("amps-ui-meters".into())
		.spawn(move || {
			let mut probe = None;
			let mut next_rebuild = Instant::now();
			while !meter_engine.stop.load(Ordering::Acquire) {
				if Instant::now() >= next_rebuild {
					if let Ok(config) = amps::Config::load(&meter_config_path) {
						let rebuild = probe.as_ref().is_none_or(|current: &amps::MeterProbe| {
							!current.is_current(&config).unwrap_or(false)
						});
						if rebuild {
							// Release the loopback telemetry socket before constructing its
							// replacement. Windows permits only one receiver on this local port.
							drop(probe.take());
							probe = amps::MeterProbe::new(&config).ok();
						}
					}
					next_rebuild = Instant::now() + Duration::from_secs(2);
				}
				if let Some(probe) = &mut probe {
					if let Ok(mut current) = meter_state.write() {
						*current = probe.read();
						if let Some(reading) = meter_phone.meter() {
							current.push(reading);
						}
					}
				}
				thread::sleep(Duration::from_millis(33));
			}
		})
		.expect("AMPS could not start its meter service");

	let shutdown = engine.clone();
	let setup_engine = engine.clone();
	let setup_config_path = config_path.clone();
	let app = tauri::Builder::default()
		.manage(UiState {
			config_path,
			meters,
			engine,
			clean_mic_monitor: Mutex::new(None),
			phone,
		})
		.setup(move |app| {
			supervise_engine(setup_config_path.clone(), setup_engine.clone());
			let show = MenuItem::with_id(app, "show", "Show AMPS", true, None::<&str>)?;
			let restart = MenuItem::with_id(app, "restart", "Restart AMPS", true, None::<&str>)?;
			let exit = MenuItem::with_id(app, "exit", "Exit AMPS", true, None::<&str>)?;
			let menu = Menu::with_items(app, &[&show, &restart, &exit])?;
			let icon = app
				.default_window_icon()
				.cloned()
				.ok_or("AMPS has no application icon")?;
			TrayIconBuilder::with_id("amps")
				.icon(icon)
				.tooltip("AMPS — online")
				.menu(&menu)
				.show_menu_on_left_click(false)
				.on_tray_icon_event(|tray, event| {
					if matches!(
						event,
						TrayIconEvent::Click {
							button: MouseButton::Right,
							button_state: MouseButtonState::Up,
							..
						}
					) {
						let _ = tray.app_handle().emit("amps-ui-feedback", "search");
					}
					if matches!(
						event,
						TrayIconEvent::Click {
							button: MouseButton::Left,
							button_state: MouseButtonState::Up,
							..
						}
					) {
						let _ = tray.app_handle().emit("amps-ui-feedback", "intrepid-key");
						show_main(tray.app_handle());
					}
				})
				.build(app)?;
			Ok(())
		})
		.on_menu_event(|app, event| match event.id().as_ref() {
			"show" => {
				let _ = app.emit("amps-ui-feedback", "intrepid-key");
				show_main(app);
			}
			"restart" => {
				let _ = app.emit("amps-ui-feedback", "confirm");
				let state = app.state::<UiState>();
				stop_clean_mic_monitor(&state);
				state.engine.restart.store(true, Ordering::Release);
			}
			"exit" => {
				let _ = app.emit("amps-ui-feedback", "key-02");
				let state = app.state::<UiState>();
				stop_clean_mic_monitor(&state);
				app.exit(0);
			}
			_ => {}
		})
		.on_window_event(|window, event| {
			if let WindowEvent::CloseRequested { api, .. } = event {
				api.prevent_close();
				let _ = window.emit("amps-ui-feedback", "key-02");
				let _ = window.hide();
				// Device teardown must not block the native window event loop.
				let app = window.app_handle().clone();
				tauri::async_runtime::spawn_blocking(move || {
					stop_clean_mic_monitor(&app.state::<UiState>())
				});
			}
		})
		.invoke_handler(tauri::generate_handler![
			graph_snapshot,
			meter_snapshot,
			select_main_output,
			select_main_input,
			routing_snapshot,
			edit_routing,
			set_clean_mic_monitor,
			phone_control,
		])
		.build(tauri::generate_context!())
		.expect("error while building AMPS interface");
	app.run(move |app, event| {
		if matches!(event, RunEvent::Ready) {
			#[cfg(windows)]
			listen_for_show(_instance.1 .0, app.clone(), shutdown.clone());
			if !start_hidden {
				show_main(app);
			}
		}
		if matches!(event, RunEvent::Exit | RunEvent::ExitRequested { .. }) {
			if !shutdown.stop.load(Ordering::Acquire) {
				let state = app.state::<UiState>();
				shutdown.stop.store(true, Ordering::Release);
				let until = Instant::now() + Duration::from_secs(3);
				while !shutdown.stopped.load(Ordering::Acquire) && Instant::now() < until {
					thread::sleep(Duration::from_millis(20));
				}
				amps::phone::disable_native_listen(&state.config_path);
			}
			shutdown.stop.store(true, Ordering::Release);
		}
	});
}
