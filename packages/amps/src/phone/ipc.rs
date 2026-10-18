//! Bounded local commands and volatile localhost meter telemetry. No PCM on disk.
use super::*;
use std::{net::UdpSocket, path::PathBuf, time::Instant};
const TELEMETRY: &str = "127.0.0.1:47848";
#[derive(Serialize, Deserialize)]
pub(super) struct Envelope {
	pub id: String,
	pub session: String,
	pub expires: u64,
	pub request: Request,
}
#[derive(Serialize, Deserialize)]
struct Reply {
	error: Option<String>,
}
fn root(config: &Path) -> PathBuf {
	config.with_file_name("phone-v1")
}
#[cfg(any(windows, test))]
fn valid(id: &str) -> bool {
	!id.is_empty() && id.len() <= 80 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn now() -> u64 {
	std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap_or_default()
		.as_millis() as u64
}
#[cfg(any(windows, test))]
pub(super) fn next(config: &Path) -> Result<Option<Envelope>> {
	let folder = root(config).join("requests");
	std::fs::create_dir_all(&folder)?;
	for entry in std::fs::read_dir(folder)?.take(64) {
		let entry = entry?;
		let path = entry.path();
		let Some(id) = path.file_stem().and_then(|v| v.to_str()) else {
			continue;
		};
		if path.extension().is_none_or(|v| v != "json") || !valid(id) {
			continue;
		}
		if entry.metadata()?.len() > 8192 {
			std::fs::remove_file(path)?;
			continue;
		}
		let request: Envelope = match serde_json::from_slice(&std::fs::read(&path)?) {
			Ok(r) => r,
			Err(_) => {
				std::fs::remove_file(path)?;
				continue;
			}
		};
		if request.id != id {
			std::fs::remove_file(path)?;
			continue;
		}
		if root(config)
			.join("replies")
			.join(format!("{id}.json"))
			.exists()
		{
			std::fs::remove_file(path)?;
			continue;
		}
		if request.expires < now()
			|| !crate::control::status(config).is_ok_and(|s| s.online && s.session == request.session)
		{
			reply(
				config,
				id,
				Err("Phone command expired or belongs to a previous engine session".into()),
			)?;
			continue;
		}
		if let Err(error) = request.request.validate() {
			reply(config, id, Err(error.to_string()))?;
			continue;
		}
		return Ok(Some(request));
	}
	Ok(None)
}
#[cfg(any(windows, test))]
pub(super) fn reply(
	config: &Path,
	id: &str,
	result: std::result::Result<(), String>,
) -> Result<()> {
	if !valid(id) {
		bail!("Invalid phone command ID");
	}
	crate::control::atomic_write(
		&root(config).join("replies").join(format!("{id}.json")),
		&serde_json::to_vec(&Reply {
			error: result.err(),
		})?,
	)?;
	let _ = std::fs::remove_file(root(config).join("requests").join(format!("{id}.json")));
	let mut entries = std::fs::read_dir(root(config).join("replies"))?
		.filter_map(|v| v.ok())
		.collect::<Vec<_>>();
	entries.sort_by_key(|e| e.metadata().and_then(|m| m.modified()).ok());
	for e in entries.iter().take(entries.len().saturating_sub(64)) {
		let _ = std::fs::remove_file(e.path());
	}
	Ok(())
}
#[cfg(windows)]
pub(super) fn publisher() -> Option<UdpSocket> {
	let socket = UdpSocket::bind("127.0.0.1:0").ok()?;
	socket.connect(TELEMETRY).ok()?;
	socket.set_nonblocking(true).ok()?;
	Some(socket)
}
#[cfg(windows)]
pub(super) fn publish(socket: Option<&UdpSocket>, meter: Option<&crate::MeterReading>) {
	if let (Some(socket), Some(meter)) = (socket, meter) {
		if let Ok(bytes) = serde_json::to_vec(meter) {
			let _ = socket.send(&bytes);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn commands_are_session_bound_and_expire_without_replay() {
		let temp = tempfile::tempdir().unwrap();
		let path = temp.path().join("custom-config.toml");
		std::fs::write(&path, crate::DEFAULT_CONFIG).unwrap();
		let _lock = crate::control::EngineLock::acquire(&path).unwrap();
		let mut server =
			crate::control::Server::new(&path, crate::Config::load(&path).unwrap()).unwrap();
		server.ready().unwrap();
		let mut envelope = Envelope {
			id: "fixture-command".into(),
			session: "stale-session".into(),
			expires: now() + 10000,
			request: Request {
				action: "connect".into(),
				device_id: None,
				auto_connect: None,
			},
		};
		let request = root(&path).join("requests/fixture-command.json");
		crate::control::atomic_write(&request, &serde_json::to_vec(&envelope).unwrap()).unwrap();
		assert!(next(&path).unwrap().is_none());
		assert!(!request.exists());
		envelope.session = server.status.session.clone();
		envelope.id = "valid-command".into();
		let request = root(&path).join("requests/valid-command.json");
		crate::control::atomic_write(&request, &serde_json::to_vec(&envelope).unwrap()).unwrap();
		assert!(next(&path).unwrap().is_some());
		reply(&path, &envelope.id, Ok(())).unwrap();
		crate::control::atomic_write(&request, &serde_json::to_vec(&envelope).unwrap()).unwrap();
		assert!(next(&path).unwrap().is_none());
		envelope.id = "expired-command".into();
		envelope.expires = 0;
		crate::control::atomic_write(
			&root(&path).join("requests/expired-command.json"),
			&serde_json::to_vec(&envelope).unwrap(),
		)
		.unwrap();
		assert!(next(&path).unwrap().is_none());
		assert!(reply(&path, "../escape", Ok(())).is_err());
		assert!(Request {
			action: "arbitrary".into(),
			device_id: None,
			auto_connect: None
		}
		.validate()
		.is_err());
	}
}
pub struct Client {
	path: PathBuf,
	meter: Mutex<Option<(UdpSocket, Option<(Instant, crate::MeterReading)>)>>,
}
impl Client {
	pub fn new(config: &Path) -> Self {
		let meter = UdpSocket::bind(TELEMETRY).ok().and_then(|s| {
			s.set_nonblocking(true).ok()?;
			Some((s, None))
		});
		Self {
			path: config.into(),
			meter: Mutex::new(meter),
		}
	}
	pub fn snapshot(&self) -> Snapshot {
		let mut snapshot: Snapshot = std::fs::read(self.path.with_file_name("phone-status.json"))
			.ok()
			.and_then(|b| serde_json::from_slice(&b).ok())
			.unwrap_or_default();
		if !crate::control::status(&self.path).is_ok_and(|r| r.online) {
			snapshot.connected = false;
			snapshot.output = None;
			snapshot.phase = "engine offline".into();
		}
		snapshot
	}
	pub fn edit(&self, request: Request) -> Result<()> {
		self.edit_timeout(request, Duration::from_secs(45))
	}
	pub(super) fn edit_timeout(&self, request: Request, timeout: Duration) -> Result<()> {
		request.validate()?;
		let status = crate::control::status(&self.path)?;
		if !status.online {
			bail!("AMPS is offline");
		}
		let directory = root(&self.path).join("requests");
		std::fs::create_dir_all(&directory)?;
		if std::fs::read_dir(&directory)?.count() >= 64 {
			bail!("Phone command queue is full");
		}
		let id = crate::control::token();
		crate::control::atomic_write(
			&directory.join(format!("{id}.json")),
			&serde_json::to_vec(&Envelope {
				id: id.clone(),
				session: status.session,
				expires: now() + timeout.as_millis() as u64,
				request,
			})?,
		)?;
		let start = Instant::now();
		while start.elapsed() < timeout {
			if let Ok(bytes) =
				std::fs::read(root(&self.path).join("replies").join(format!("{id}.json")))
			{
				let reply: Reply = serde_json::from_slice(&bytes)?;
				return reply.error.map_or(Ok(()), |e| Err(anyhow::anyhow!(e)));
			}
			thread::sleep(Duration::from_millis(40));
		}
		bail!("Phone command has no acknowledgement; refresh before retrying")
	}
	pub fn meter(&self) -> Option<crate::MeterReading> {
		let mut guard = self.meter.lock().ok()?;
		let (socket, latest) = guard.as_mut()?;
		let mut bytes = [0u8; 8192];
		for _ in 0..64 {
			let Ok(size) = socket.recv(&mut bytes) else {
				break;
			};
			if let Ok(reading) = serde_json::from_slice::<crate::MeterReading>(&bytes[..size]) {
				if reading.id == "phone"
					&& reading.waveform.len() <= 256
					&& reading.peak.is_finite()
					&& reading.waveform.iter().all(|s| s.is_finite())
				{
					*latest = Some((Instant::now(), reading));
				}
			}
		}
		latest
			.as_ref()
			.filter(|(t, _)| t.elapsed() < Duration::from_millis(300))
			.map(|(_, r)| r.clone())
	}
}
