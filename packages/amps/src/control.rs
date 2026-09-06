//! Local, bounded mailbox IPC. Only the engine owns persisted audio controls.
//! The mailbox inherits the user's private profile ACL; no network listener.
use crate::{
	load_runtime_controls, runtime_controls_path, Config, NoiseSuppressionConfig,
	NoiseSuppressionControls, PatchConnection, PatchbayControls, RuntimeControls,
};
use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
	fs::{self, File, OpenOptions},
	io::{Read, Write},
	path::{Path, PathBuf},
	sync::atomic::{AtomicU64, Ordering},
	thread,
	time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const LIMIT: usize = 64;
const MAX_BYTES: u64 = 65536;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
pub fn token() -> String {
	format!(
		"{}-{}-{}",
		std::process::id(),
		now(),
		SEQUENCE.fetch_add(1, Ordering::Relaxed)
	)
}
fn now() -> u64 {
	SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.unwrap_or_default()
		.as_millis() as u64
}
pub(crate) fn check_schema(version: u32) -> Result<()> {
	if version != 1 {
		bail!("Unsupported audio controls schema {version}; refusing to overwrite it");
	}
	Ok(())
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
	let parent = path.parent().context("Missing parent directory")?;
	fs::create_dir_all(parent)?;
	let mut file = tempfile::NamedTempFile::new_in(parent)?;
	file.write_all(bytes)?;
	file.as_file().sync_all()?;
	file.persist(path).map_err(|e| e.error)?;
	#[cfg(unix)]
	File::open(parent)?.sync_all()?;
	Ok(())
}
fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
	atomic_write(path, &serde_json::to_vec(value)?)
}
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
	let file = File::open(path)?;
	if file.metadata()?.len() > MAX_BYTES {
		bail!("Control message exceeds size limit");
	}
	let mut data = Vec::new();
	file.take(MAX_BYTES + 1).read_to_end(&mut data)?;
	Ok(serde_json::from_slice(&data)?)
}
fn directory(config: &Path) -> PathBuf {
	config.with_file_name("control-v1")
}
fn valid_id(id: &str) -> bool {
	!id.is_empty() && id.len() <= 80 && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
}

pub struct EngineLock {
	_file: File,
}
impl EngineLock {
	pub fn acquire(config: &Path) -> Result<Self> {
		let root = directory(config);
		fs::create_dir_all(&root)?;
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
		}
		let file = OpenOptions::new()
			.read(true)
			.write(true)
			.create(true)
			.truncate(false)
			.open(root.join("engine.lock"))?;
		file
			.try_lock_exclusive()
			.context("Another AMPS engine owns this configuration")?;
		Ok(Self { _file: file })
	}
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Edit {
	Connect {
		source: String,
		destination: String,
	},
	Disconnect {
		source: String,
		destination: String,
	},
	Replace {
		old: PatchConnection,
		new: PatchConnection,
	},
	Suppression {
		enabled: bool,
		intensity: u8,
		engine: String,
	},
	Undo,
	Redo,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
	pub id: String,
	pub session: String,
	pub expected_revision: u64,
	pub edit: Edit,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
	pub id: String,
	pub revision: u64,
	pub applied: bool,
	pub error: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
	pub schema_version: u32,
	pub session: String,
	pub revision: u64,
	pub applied_revision: Option<u64>,
	pub online: bool,
	pub updated_at: u64,
	pub patches: Vec<PatchConnection>,
	pub suppression: NoiseSuppressionConfig,
	pub can_undo: bool,
	pub can_redo: bool,
	pub error: Option<String>,
	pub pending: Option<String>,
	pub input_name: String,
	pub output_name: String,
}
pub fn status(config: &Path) -> Result<Status> {
	let mut value: Status = read_json(&directory(config).join("status.json"))?;
	check_schema(value.schema_version)?;
	if now().saturating_sub(value.updated_at) > 10_000 || EngineLock::acquire(config).is_ok() {
		value.online = false;
		value.applied_revision = None;
	}
	Ok(value)
}
pub fn mark_offline(config: &Path) -> Result<()> {
	let path = directory(config).join("status.json");
	if path.exists() {
		let Ok(mut value) = read_json::<Status>(&path) else {
			// This is a derived cache, never the committed user controls.
			fs::remove_file(path)?;
			return Ok(());
		};
		value.online = false;
		value.applied_revision = None;
		value.updated_at = now();
		write_json(&path, &value)?;
	}
	Ok(())
}
pub fn submit(config: &Path, request: &Request) -> Result<Reply> {
	if !valid_id(&request.id) {
		bail!("Invalid request identifier");
	}
	let current = status(config)?;
	if !current.online {
		bail!("AMPS is offline or waiting for devices; no routing changes were sent");
	}
	if request.session != current.session {
		bail!("The engine restarted; refresh before editing");
	}
	let root = directory(config);
	let response = root.join("replies").join(format!("{}.json", request.id));
	if response.exists() {
		return read_json(&response);
	}
	let inbox = root.join("requests");
	if fs::read_dir(&inbox)?.count() >= LIMIT {
		bail!("Routing command queue is full");
	}
	write_json(&inbox.join(format!("{}.json", request.id)), request)?;
	let start = Instant::now();
	while start.elapsed() < Duration::from_secs(12) {
		if response.exists() {
			return read_json(&response);
		}
		thread::sleep(Duration::from_millis(40));
	}
	bail!("Command {} has no acknowledgement yet; refresh state before retrying (do not assume it failed)",request.id)
}

/// Staging never makes a new route audible; rollback retains existing resources.
pub trait Backend {
	type Staged;
	fn stage(&mut self, previous: &Config, next: &Config) -> Result<Self::Staged>;
	fn activate(&mut self, staged: &mut Self::Staged) -> Result<()>;
	fn rollback(&mut self, staged: Self::Staged) -> Result<()>;
	fn finish(&mut self, staged: Self::Staged);
}
pub struct Server {
	path: PathBuf,
	root: PathBuf,
	config: Config,
	controls: RuntimeControls,
	undo: Vec<RuntimeControls>,
	redo: Vec<RuntimeControls>,
	pub status: Status,
}
impl Server {
	pub fn new(path: &Path, effective: Config) -> Result<Self> {
		let controls = load_runtime_controls(path)?;
		let root = directory(path);
		fs::create_dir_all(root.join("requests"))?;
		fs::create_dir_all(root.join("replies"))?;
		// A prepared journal never supersedes committed controls after a crash.
		if root.join("prepared.json").exists() {
			fs::remove_file(root.join("prepared.json"))?;
		}
		let status = Status {
			schema_version: 1,
			session: token(),
			revision: controls.revision,
			applied_revision: None,
			online: true,
			updated_at: now(),
			patches: effective.patchbay.connections.clone(),
			suppression: effective.noise_suppression.clone(),
			can_undo: false,
			can_redo: false,
			error: None,
			pending: None,
			input_name: effective.microphone.input.clone(),
			output_name: effective.monitor.output.clone(),
		};
		let value = Self {
			path: path.into(),
			root,
			config: effective,
			controls,
			undo: vec![],
			redo: vec![],
			status,
		};
		value.publish()?;
		Ok(value)
	}
	pub fn publish(&self) -> Result<()> {
		let mut status = self.status.clone();
		status.updated_at = now();
		write_json(&self.root.join("status.json"), &status)
	}
	pub fn ready(&mut self) -> Result<()> {
		self.status.applied_revision = Some(self.status.revision);
		self.publish()
	}
	pub fn config(&self) -> &Config {
		&self.config
	}
	pub fn next_request(&self) -> Result<Option<Request>> {
		let mut paths = fs::read_dir(self.root.join("requests"))?
			.filter_map(|x| x.ok())
			.map(|x| x.path())
			.filter(|x| x.extension().is_some_and(|x| x == "json"))
			.collect::<Vec<_>>();
		paths.sort();
		for path in paths.into_iter().take(LIMIT) {
			let id = path.file_stem().and_then(|x| x.to_str()).unwrap_or("");
			if !valid_id(id) {
				continue;
			}
			if self
				.root
				.join("replies")
				.join(format!("{id}.json"))
				.exists()
			{
				fs::remove_file(path)?;
				continue;
			}
			match read_json::<Request>(&path) {
				Ok(req) if req.id == id => return Ok(Some(req)),
				_ => {
					fs::remove_file(path)?;
				}
			}
		}
		Ok(None)
	}
	fn candidate(&self, edit: &Edit) -> Result<RuntimeControls> {
		let mut controls = self.controls.clone();
		let mut edges = self.config.patchbay.connections.clone();
		match edit {
			Edit::Connect {
				source,
				destination,
			} => edges.push(PatchConnection {
				source: source.clone(),
				destination: destination.clone(),
			}),
			Edit::Disconnect {
				source,
				destination,
			} => {
				if !edges
					.iter()
					.any(|e| &e.source == source && &e.destination == destination)
				{
					bail!("Connection no longer exists");
				}
				edges.retain(|e| &e.source != source || &e.destination != destination);
			}
			Edit::Replace { old, new } => {
				let index = edges
					.iter()
					.position(|e| e == old)
					.context("Original connection no longer exists")?;
				edges[index] = new.clone();
			}
			Edit::Suppression {
				enabled,
				intensity,
				engine,
			} => {
				if *intensity > 100 || !matches!(engine.as_str(), "nvidia_afx" | "deepfilternet3") {
					bail!("Invalid suppression settings");
				}
				controls.noise_suppression = Some(NoiseSuppressionControls {
					enabled: *enabled,
					intensity: *intensity,
					engine: Some(engine.clone()),
				});
			}
			Edit::Undo => {
				return self
					.undo
					.last()
					.cloned()
					.context("Nothing to undo in this engine session")
			}
			Edit::Redo => {
				return self
					.redo
					.last()
					.cloned()
					.context("Nothing to redo in this engine session")
			}
		}
		crate::validate_patch_connections(&edges)?;
		controls.patchbay = Some(PatchbayControls { connections: edges });
		Ok(controls)
	}
	fn effective(&self, controls: &RuntimeControls) -> Config {
		let mut config = self.config.clone();
		if let Some(patch) = &controls.patchbay {
			config.patchbay.connections = patch.connections.clone();
		}
		if let Some(noise) = &controls.noise_suppression {
			config.noise_suppression.enabled = noise.enabled;
			config.noise_suppression.attenuation_limit_db =
				crate::attenuation_for_intensity(noise.intensity);
			if let Some(engine) = &noise.engine {
				config.noise_suppression.engine = engine.clone();
			}
		}
		config
	}
	pub fn execute<B: Backend>(&mut self, request: &Request, backend: &mut B) -> Result<Reply> {
		if !valid_id(&request.id) {
			bail!("Invalid request identifier");
		}
		let response = self
			.root
			.join("replies")
			.join(format!("{}.json", request.id));
		if response.exists() {
			return read_json(&response);
		}
		let outcome = self.apply(request, backend);
		self.status.pending = None;
		self.status.error = outcome.as_ref().err().map(|e| format!("{e:#}"));
		let reply = Reply {
			id: request.id.clone(),
			revision: self.status.revision,
			applied: outcome.is_ok(),
			error: self.status.error.clone(),
		};
		self.publish()?;
		write_json(&response, &reply)?;
		let _ = fs::remove_file(
			self
				.root
				.join("requests")
				.join(format!("{}.json", request.id)),
		);
		let mut replies = fs::read_dir(self.root.join("replies"))?
			.filter_map(|e| e.ok())
			.collect::<Vec<_>>();
		replies.sort_by_key(|e| e.metadata().and_then(|m| m.modified()).ok());
		let excess = replies.len().saturating_sub(LIMIT);
		for entry in replies.into_iter().take(excess) {
			let _ = fs::remove_file(entry.path());
		}
		Ok(reply)
	}
	fn apply<B: Backend>(&mut self, request: &Request, backend: &mut B) -> Result<()> {
		if request.session != self.status.session || request.expected_revision != self.status.revision
		{
			bail!("Stale graph revision; refresh and retry your edit");
		}
		if load_runtime_controls(&self.path)? != self.controls {
			bail!("Controls changed outside the engine; restart Array to adopt them safely");
		}
		let mut next = self.candidate(&request.edit)?;
		// Materialize missing legacy defaults only in the transaction/history,
		// never by overwriting the imported file during startup.
		let mut previous = self.controls.clone();
		previous.patchbay = Some(PatchbayControls {
			connections: self.config.patchbay.connections.clone(),
		});
		previous.noise_suppression = Some(NoiseSuppressionControls {
			enabled: self.config.noise_suppression.enabled,
			intensity: crate::suppression_intensity(&self.config.noise_suppression),
			engine: Some(self.config.noise_suppression.engine.clone()),
		});
		next.revision = self
			.controls
			.revision
			.checked_add(1)
			.context("Revision exhausted")?;
		let config = self.effective(&next);
		config.validate()?;
		self.status.pending = Some(request.id.clone());
		self.publish()?;
		write_json(&self.root.join("prepared.json"), &next)?;
		let mut staged = backend.stage(&self.config, &config)?;
		if let Err(error) = backend.activate(&mut staged) {
			return Err(self.rollback_after(backend, staged, error));
		}
		let save = (|| -> Result<()> {
			// Recheck after resource staging so an external write is never lost.
			if load_runtime_controls(&self.path)? != self.controls {
				bail!("Controls changed during staging; old graph retained");
			}
			atomic_write(
				&self.root.join("last-good.toml"),
				toml::to_string_pretty(&self.controls)?.as_bytes(),
			)?;
			atomic_write(
				&runtime_controls_path(&self.path),
				toml::to_string_pretty(&next)?.as_bytes(),
			)
		})();
		if let Err(error) = save {
			return Err(self.rollback_after(backend, staged, error.context("Saving failed")));
		}
		backend.finish(staged);
		match request.edit {
			Edit::Undo => {
				self.undo.pop();
				self.redo.push(previous);
			}
			Edit::Redo => {
				self.redo.pop();
				self.undo.push(previous);
			}
			_ => {
				self.undo.push(previous);
				self.redo.clear();
			}
		}
		if self.undo.len() > LIMIT {
			self.undo.remove(0);
		}
		self.controls = next;
		self.config = config;
		self.status.revision = self.controls.revision;
		self.status.applied_revision = Some(self.controls.revision);
		self.status.patches = self.config.patchbay.connections.clone();
		self.status.suppression = self.config.noise_suppression.clone();
		self.status.can_undo = !self.undo.is_empty();
		self.status.can_redo = !self.redo.is_empty();
		let _ = fs::remove_file(self.root.join("prepared.json"));
		Ok(())
	}
	fn rollback_after<B: Backend>(
		&mut self,
		backend: &mut B,
		staged: B::Staged,
		error: anyhow::Error,
	) -> anyhow::Error {
		match backend.rollback(staged) {
			Ok(()) => error.context("Edit failed; previous routing restored"),
			Err(rollback) => {
				self.status.applied_revision = None;
				error.context(format!(
					"Rollback also failed ({rollback:#}); engine recovery required"
				))
			}
		}
	}
}
impl Drop for Server {
	fn drop(&mut self) {
		self.status.online = false;
		self.status.applied_revision = None;
		let _ = self.publish();
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[derive(Default)]
	struct Fake {
		active: Vec<PatchConnection>,
		fail_stage: bool,
		fail_activate: bool,
		staged: usize,
	}
	impl Backend for Fake {
		type Staged = (Vec<PatchConnection>, Vec<PatchConnection>);
		fn stage(&mut self, old: &Config, new: &Config) -> Result<Self::Staged> {
			self.staged += 1;
			if self.fail_stage {
				bail!("device missing")
			}
			Ok((
				old.patchbay.connections.clone(),
				new.patchbay.connections.clone(),
			))
		}
		fn activate(&mut self, s: &mut Self::Staged) -> Result<()> {
			self.active = s.1.clone();
			if self.fail_activate {
				bail!("partial failure")
			}
			Ok(())
		}
		fn rollback(&mut self, s: Self::Staged) -> Result<()> {
			self.active = s.0;
			Ok(())
		}
		fn finish(&mut self, _s: Self::Staged) {}
	}
	fn fixture() -> (tempfile::TempDir, Server, Fake) {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("config.toml");
		fs::write(&path, crate::DEFAULT_CONFIG).unwrap();
		let config = Config::load(&path).unwrap();
		let backend = Fake {
			active: config.patchbay.connections.clone(),
			..Default::default()
		};
		let mut server = Server::new(&path, config).unwrap();
		server.ready().unwrap();
		(dir, server, backend)
	}
	fn request(server: &Server, edit: Edit) -> Request {
		Request {
			id: token(),
			session: server.status.session.clone(),
			expected_revision: server.status.revision,
			edit,
		}
	}
	fn music() -> Edit {
		Edit::Connect {
			source: "music".into(),
			destination: "comms_send".into(),
		}
	}
	#[test]
	fn acknowledged_edit_undo_redo_preserves_defaults() {
		let (_dir, mut s, mut b) = fixture();
		let before = b.active.clone();
		let req = request(&s, music());
		assert!(s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.active.len(), 9);
		assert_eq!(
			Config::load(&s.path).unwrap().patchbay.connections,
			b.active
		);
		let undo = request(&s, Edit::Undo);
		assert!(s.execute(&undo, &mut b).unwrap().applied);
		assert_eq!(b.active, before);
		let redo = request(&s, Edit::Redo);
		assert!(s.execute(&redo, &mut b).unwrap().applied);
		assert_eq!(b.active.len(), 9);
	}
	#[test]
	fn stale_and_duplicate_requests_do_not_apply_twice() {
		let (_d, mut s, mut b) = fixture();
		let req = request(&s, music());
		assert!(s.execute(&req, &mut b).unwrap().applied);
		assert!(s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.staged, 1);
		let mut stale = req;
		stale.id = token();
		assert!(!s.execute(&stale, &mut b).unwrap().applied);
		assert_eq!(b.staged, 1);
	}
	#[test]
	fn failed_activation_rolls_back_without_persisting() {
		let (_d, mut s, mut b) = fixture();
		let before = b.active.clone();
		b.fail_activate = true;
		let req = request(&s, music());
		assert!(!s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.active, before);
		assert_eq!(s.status.revision, 0);
		assert!(!runtime_controls_path(&s.path).exists());
	}
	#[test]
	fn unavailable_device_leaves_graph_intact() {
		let (_d, mut s, mut b) = fixture();
		b.fail_stage = true;
		let before = b.active.clone();
		let req = request(&s, music());
		assert!(!s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.active, before);
	}
	#[test]
	fn self_return_is_rejected_before_backend() {
		let (_d, mut s, mut b) = fixture();
		let req = request(
			&s,
			Edit::Connect {
				source: "comms".into(),
				destination: "comms_send".into(),
			},
		);
		assert!(!s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.staged, 0);
	}
	#[test]
	fn unknown_schema_and_external_edits_are_preserved() {
		let (_d, mut s, mut b) = fixture();
		fs::write(runtime_controls_path(&s.path), "schema_version=99\n").unwrap();
		let req = request(&s, music());
		assert!(!s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(
			fs::read_to_string(runtime_controls_path(&s.path)).unwrap(),
			"schema_version=99\n"
		);
		assert_eq!(b.staged, 0);
	}
	#[test]
	fn mailbox_rejects_path_traversal() {
		assert!(!valid_id("../controls"));
		assert!(!valid_id("a/b"));
		assert!(valid_id("a-123"));
	}
	#[test]
	fn persistence_failure_restores_routes_without_acknowledging_candidate() {
		let (_d, mut s, mut b) = fixture();
		let before = b.active.clone();
		fs::create_dir(s.root.join("last-good.toml")).unwrap();
		let req = request(&s, music());
		let reply = s.execute(&req, &mut b).unwrap();
		assert!(!reply.applied);
		assert!(reply.error.unwrap().contains("restored"));
		assert_eq!(b.active, before);
		assert_eq!(s.status.revision, 0);
		assert!(!runtime_controls_path(&s.path).exists());
	}
	#[test]
	fn external_edit_during_staging_is_never_overwritten() {
		struct External {
			inner: Fake,
			path: PathBuf,
		}
		impl Backend for External {
			type Staged = (Vec<PatchConnection>, Vec<PatchConnection>);
			fn stage(&mut self, old: &Config, new: &Config) -> Result<Self::Staged> {
				let staged = self.inner.stage(old, new)?;
				fs::write(&self.path, "schema_version=1\nrevision=77\n")?;
				Ok(staged)
			}
			fn activate(&mut self, s: &mut Self::Staged) -> Result<()> {
				self.inner.activate(s)
			}
			fn rollback(&mut self, s: Self::Staged) -> Result<()> {
				self.inner.rollback(s)
			}
			fn finish(&mut self, s: Self::Staged) {
				self.inner.finish(s)
			}
		}
		let (_d, mut s, b) = fixture();
		let before = b.active.clone();
		let mut b = External {
			inner: b,
			path: runtime_controls_path(&s.path),
		};
		let req = request(&s, music());
		assert!(!s.execute(&req, &mut b).unwrap().applied);
		assert_eq!(b.inner.active, before);
		assert_eq!(load_runtime_controls(&s.path).unwrap().revision, 77);
	}
	#[test]
	fn prepared_crash_record_does_not_replace_committed_graph() {
		let (dir, s, _) = fixture();
		let path = s.path.clone();
		write_json(
			&s.root.join("prepared.json"),
			&serde_json::json!({"bad":"candidate"}),
		)
		.unwrap();
		drop(s);
		let restored = Server::new(&path, Config::load(&path).unwrap()).unwrap();
		assert_eq!(restored.status.patches.len(), 8);
		assert!(!directory(&path).join("prepared.json").exists());
		drop(dir);
	}
}
