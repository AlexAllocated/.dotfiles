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

use audioarray::{GraphSnapshot, MeterReading, PatchConnection};
use tauri::{
	menu::{Menu, MenuItem},
	tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
	Manager, RunEvent, WindowEvent,
};

#[cfg(windows)]
use std::os::windows::{io::AsRawHandle, process::CommandExt};

#[cfg(windows)]
use windows::core::w;

#[cfg(windows)]
use windows::Win32::{
	Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE},
	System::{
		JobObjects::{
			AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
			SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
			JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
		},
		Threading::CreateMutexW,
	},
	UI::WindowsAndMessaging::{FindWindowW, SetForegroundWindow, ShowWindow, SW_RESTORE},
};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[cfg(windows)]
struct InstanceGuard(HANDLE);

#[cfg(windows)]
impl InstanceGuard {
	fn acquire() -> std::io::Result<Option<Self>> {
		unsafe {
			let mutex = CreateMutexW(None, false, w!("Local\\HiveTech.AudioArray"))
				.map_err(|error| std::io::Error::other(error.to_string()))?;
			if GetLastError() != ERROR_ALREADY_EXISTS {
				return Ok(Some(Self(mutex)));
			}

			let _ = CloseHandle(mutex);
			for _ in 0..20 {
				let window = FindWindowW(None, w!("AudioArray / LCARS 47-A"));
				if window.0 != 0 {
					let _ = ShowWindow(window, SW_RESTORE);
					let _ = SetForegroundWindow(window);
					break;
				}
				thread::sleep(Duration::from_millis(100));
			}
			Ok(None)
		}
	}
}

#[cfg(windows)]
impl Drop for InstanceGuard {
	fn drop(&mut self) {
		unsafe {
			let _ = CloseHandle(self.0);
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
}

impl EngineControl {
	fn new() -> Self {
		Self {
			stop: AtomicBool::new(false),
			restart: AtomicBool::new(false),
		}
	}
}

struct UiState {
	config_path: PathBuf,
	meters: Arc<RwLock<Vec<MeterReading>>>,
	engine: Arc<EngineControl>,
	controls: Mutex<()>,
	clean_mic_monitor: Mutex<Option<audioarray::CleanMicMonitor>>,
}

fn load_config(state: &UiState) -> Result<audioarray::Config, String> {
	audioarray::Config::load(&state.config_path).map_err(|error| error.to_string())
}

#[tauri::command]
fn graph_snapshot(state: tauri::State<'_, UiState>) -> Result<GraphSnapshot, String> {
	let config = load_config(&state)?;
	audioarray::graph_snapshot(&config).map_err(|error| error.to_string())
}

#[tauri::command]
fn meter_snapshot(state: tauri::State<'_, UiState>) -> Result<Vec<MeterReading>, String> {
	state
		.meters
		.read()
		.map(|meters| meters.clone())
		.map_err(|_| "AudioArray meter state is unavailable".to_string())
}

#[tauri::command]
fn select_main_output(endpoint_id: String) -> Result<(), String> {
	audioarray::select_main_output(&endpoint_id).map_err(|error| error.to_string())
}

#[tauri::command]
fn select_main_input(endpoint_id: String) -> Result<(), String> {
	audioarray::select_main_input(&endpoint_id).map_err(|error| error.to_string())
}

#[tauri::command]
fn set_noise_suppression(
	enabled: bool,
	intensity: u8,
	engine: String,
	state: tauri::State<'_, UiState>,
) -> Result<GraphSnapshot, String> {
	let _guard = state
		.controls
		.lock()
		.map_err(|_| "AudioArray control state is unavailable".to_string())?;
	audioarray::save_suppression_controls(&state.config_path, enabled, intensity, &engine)
		.map_err(|error| error.to_string())?;
	let updated = load_config(&state)?;
	audioarray::graph_snapshot(&updated).map_err(|error| error.to_string())
}

#[tauri::command]
fn set_patch_connection(
	source: String,
	destination: String,
	enabled: bool,
	state: tauri::State<'_, UiState>,
) -> Result<GraphSnapshot, String> {
	let _guard = state
		.controls
		.lock()
		.map_err(|_| "AudioArray control state is unavailable".to_string())?;
	let current = load_config(&state)?;
	let mut connections = current.patchbay.connections;
	let matches = |patch: &PatchConnection| {
		patch.source == source && patch.destination == destination
	};
	if enabled && !connections.iter().any(matches) {
		connections.push(PatchConnection {
			source,
			destination,
		});
	} else if !enabled {
		connections.retain(|patch| !matches(patch));
	}
	audioarray::save_patch_connections(&state.config_path, connections)
		.map_err(|error| error.to_string())?;
	let updated = load_config(&state)?;
	audioarray::graph_snapshot(&updated).map_err(|error| error.to_string())
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
		*monitor = Some(audioarray::CleanMicMonitor::new(&config).map_err(|error| error.to_string())?);
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

fn engine_log_path() -> PathBuf {
	std::env::var_os("LOCALAPPDATA")
		.map(PathBuf::from)
		.unwrap_or_else(std::env::temp_dir)
		.join("AudioArray")
		.join("logs")
		.join("audioarray.log")
}

fn append_engine_log(log: &mut File, message: &str) {
	let _ = writeln!(log, "{message}");
}

fn spawn_engine(config_path: &Path, log: &File) -> std::io::Result<Child> {
	let engine_name = if cfg!(windows) {
		"audioarray.exe"
	} else {
		"audioarray"
	};
	let engine_path = std::env::current_exe()?
		.parent()
		.ok_or_else(|| std::io::Error::other("AudioArray UI executable has no parent directory"))?
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
		.name("audioarray-engine-supervisor".into())
		.spawn(move || {
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
						&format!("AudioArray engine job creation failed: {error}"),
					);
					return;
				}
			};
			while !control.stop.load(Ordering::Acquire) {
				control.restart.store(false, Ordering::Release);
				let mut child = match spawn_engine(&config_path, &log) {
					Ok(child) => child,
					Err(error) => {
						append_engine_log(
							&mut log,
							&format!("AudioArray engine launch failed: {error}"),
						);
						thread::sleep(Duration::from_secs(2));
						continue;
					}
				};
				#[cfg(windows)]
				if let Err(error) = job.assign(&child) {
					append_engine_log(
						&mut log,
						&format!("AudioArray engine job assignment failed: {error}"),
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
						let _ = child.kill();
						let _ = child.wait();
						break;
					}
					match child.try_wait() {
						Ok(Some(status)) => {
							append_engine_log(
								&mut log,
								&format!("AudioArray engine exited with {status}; restarting"),
							);
							break;
						}
						Ok(None) => thread::sleep(Duration::from_millis(250)),
						Err(error) => {
							append_engine_log(
								&mut log,
								&format!("AudioArray engine status failed: {error}"),
							);
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
		.expect("AudioArray could not start its engine supervisor");
}

fn main() {
	#[cfg(windows)]
	let _instance = match InstanceGuard::acquire() {
		Ok(Some(instance)) => instance,
		Ok(None) => return,
		Err(error) => panic!("AudioArray could not establish its process lifecycle: {error}"),
	};

	let start_hidden = std::env::args().any(|argument| argument == "--tray");
	let config_path = audioarray::default_config_path()
		.expect("AudioArray could not determine its configuration path");
	let engine = Arc::new(EngineControl::new());

	let meters = Arc::new(RwLock::new(Vec::new()));
	let meter_state = meters.clone();
	let meter_config_path = config_path.clone();
	thread::Builder::new()
		.name("audioarray-ui-meters".into())
		.spawn(move || {
			let mut probe = None;
			let mut next_rebuild = Instant::now();
			loop {
				if Instant::now() >= next_rebuild {
					if let Ok(config) = audioarray::Config::load(&meter_config_path) {
						let rebuild = probe
							.as_ref()
							.is_none_or(|current: &audioarray::MeterProbe| {
								!current.is_current(&config).unwrap_or(false)
							});
						if rebuild {
							// Release the loopback telemetry socket before constructing its
							// replacement. Windows permits only one receiver on this local port.
							drop(probe.take());
							probe = audioarray::MeterProbe::new(&config).ok();
						}
					}
					next_rebuild = Instant::now() + Duration::from_secs(2);
				}
				if let Some(probe) = &mut probe {
					if let Ok(mut current) = meter_state.write() {
						*current = probe.read();
					}
				}
				thread::sleep(Duration::from_millis(33));
			}
		})
		.expect("AudioArray could not start its meter service");

	let shutdown = engine.clone();
	let setup_engine = engine.clone();
	let setup_config_path = config_path.clone();
	let app = tauri::Builder::default()
		.manage(UiState {
			config_path,
			meters,
			engine,
			controls: Mutex::new(()),
			clean_mic_monitor: Mutex::new(None),
		})
		.setup(move |app| {
			supervise_engine(setup_config_path.clone(), setup_engine.clone());
			let show = MenuItem::with_id(app, "show", "Show AudioArray", true, None::<&str>)?;
			let restart = MenuItem::with_id(app, "restart", "Restart Array", true, None::<&str>)?;
			let exit = MenuItem::with_id(app, "exit", "Exit AudioArray", true, None::<&str>)?;
			let menu = Menu::with_items(app, &[&show, &restart, &exit])?;
			let icon = app
				.default_window_icon()
				.cloned()
				.ok_or("AudioArray has no application icon")?;
			TrayIconBuilder::with_id("audioarray")
				.icon(icon)
				.tooltip("AudioArray — online")
				.menu(&menu)
				.show_menu_on_left_click(false)
				.on_tray_icon_event(|tray, event| {
					if matches!(
						event,
						TrayIconEvent::Click {
							button: MouseButton::Left,
							button_state: MouseButtonState::Up,
							..
						}
					) {
						show_main(tray.app_handle());
					}
				})
				.build(app)?;
			if !start_hidden {
				show_main(app.handle());
			}
			Ok(())
		})
		.on_menu_event(|app, event| match event.id().as_ref() {
			"show" => show_main(app),
			"restart" => {
				let state = app.state::<UiState>();
				stop_clean_mic_monitor(&state);
				state.engine.restart.store(true, Ordering::Release);
			}
			"exit" => {
				let state = app.state::<UiState>();
				stop_clean_mic_monitor(&state);
				state.engine.stop.store(true, Ordering::Release);
				app.exit(0);
			}
			_ => {}
		})
		.on_window_event(|window, event| {
			if let WindowEvent::CloseRequested { api, .. } = event {
				api.prevent_close();
				stop_clean_mic_monitor(&window.state::<UiState>());
				let _ = window.hide();
			}
		})
		.invoke_handler(tauri::generate_handler![
			graph_snapshot,
			meter_snapshot,
			select_main_output,
			select_main_input,
			set_noise_suppression,
			set_patch_connection,
			set_clean_mic_monitor,
		])
		.build(tauri::generate_context!())
		.expect("error while building AudioArray interface");
	app.run(move |_app, event| {
		if matches!(event, RunEvent::Exit | RunEvent::ExitRequested { .. }) {
			shutdown.stop.store(true, Ordering::Release);
		}
	});
}
