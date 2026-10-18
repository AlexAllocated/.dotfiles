use super::{EngineControl, SupervisorFinished};
use fs2::FileExt;
use std::{fs::{self, File, OpenOptions}, path::PathBuf, process::Command, sync::{Arc, atomic::Ordering}, thread, time::Duration};

pub struct InstanceGuard { _file: File }
impl InstanceGuard {
	pub fn acquire() -> std::io::Result<Option<Self>> {
		let path = amps::default_config_path().map_err(std::io::Error::other)?;
		fs::create_dir_all(path.parent().unwrap())?;
		let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path.with_file_name("ui.lock"))?;
		match file.try_lock_exclusive() {
			Ok(()) => Ok(Some(Self { _file: file })),
			Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
				fs::write(path.with_file_name("show-ui"), b"show")?;
				Ok(None)
			},
			Err(error) => Err(error),
		}
	}
}

pub fn service(action: &str) -> Result<(), String> {
	let output = Command::new("systemctl").args([action, "amps.service"]).output().map_err(|e| e.to_string())?;
	if !output.status.success() { return Err(String::from_utf8_lossy(&output.stderr).into()); }
	Ok(())
}

pub fn supervise(app: tauri::AppHandle, path: PathBuf, control: Arc<EngineControl>) {
	thread::spawn(move || {
		let _finished = SupervisorFinished(control.clone());
		if let Err(error) = service("start") { eprintln!("AMPS start failed: {error}"); }
		while !control.stop.load(Ordering::Acquire) {
			if control.restart.swap(false, Ordering::AcqRel) {
				if let Err(error) = service("restart") { eprintln!("AMPS restart failed: {error}"); }
			}
			if fs::remove_file(path.with_file_name("show-ui")).is_ok() { super::show_main(&app); }
			thread::sleep(Duration::from_millis(200));
		}
	});
}
