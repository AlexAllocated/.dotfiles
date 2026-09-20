use crate::{control, BusSummary, Config, EndpointSummary, GraphSnapshot, MeterReading};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
	collections::{BTreeMap, BTreeSet},
	io::Read,
	path::PathBuf,
	process::{Child, Command, Stdio},
	sync::{
		atomic::{AtomicBool, Ordering},
		Arc, Mutex,
	},
	thread,
	time::{Duration, Instant},
};

const BUSES: [(&str, &str); 7] = [
	("game", "Game"),
	("music", "Media"),
	("comms", "Comms Audio"),
	("chatgpt", "AI Audio"),
	("chatgpt_in", "AI Mic"),
	("comms_send", "Comms Mic"),
	("clean_mic", "Clean Mic"),
];

fn command(program: &str, args: &[&str]) -> Result<String> {
	let output = Command::new(program)
		.args(args)
		.output()
		.with_context(|| format!("Starting {program}"))?;
	if !output.status.success() {
		bail!(
			"{program}: {}",
			String::from_utf8_lossy(&output.stderr).trim()
		);
	}
	Ok(String::from_utf8(output.stdout)?.trim().into())
}

fn dump() -> Result<Vec<Value>> {
	Ok(serde_json::from_str(&command("pw-dump", &[])?)?)
}

fn props(object: &Value) -> &Value {
	&object["info"]["props"]
}
fn text<'a>(value: &'a Value, key: &str) -> &'a str {
	value[key].as_str().unwrap_or("")
}
fn node<'a>(objects: &'a [Value], name: &str) -> Option<&'a Value> {
	objects
		.iter()
		.find(|o| o["type"] == "PipeWire:Interface:Node" && props(o)["node.name"] == name)
}
fn physical(p: &Value) -> bool {
	let name = text(p, "node.name");
	!name.starts_with("amps.")
		&& !name.starts_with("creator.bus.")
		&& !name.starts_with("creator.mic.")
		&& p["node.virtual"] != true
}

fn selected(objects: &[Value], input: bool) -> Option<EndpointSummary> {
	let key = if input {
		"default.audio.source"
	} else {
		"default.audio.sink"
	};
	let default = objects
		.iter()
		.filter_map(|o| o["metadata"].as_array())
		.flatten()
		.find(|m| m["key"] == key)
		.and_then(|m| m["value"]["name"].as_str());
	let class = if input { "Audio/Source" } else { "Audio/Sink" };
	let candidates: Vec<_> = objects
		.iter()
		.filter(|o| props(o)["media.class"] == class && physical(props(o)))
		.collect();
	let chosen = candidates
		.iter()
		.find(|o| Some(text(props(o), "node.name")) == default)
		.or_else(|| candidates.first())?;
	Some(endpoint(chosen, true))
}

fn endpoint(o: &Value, selected: bool) -> EndpointSummary {
	EndpointSummary {
		id: text(props(o), "node.name").into(),
		name: props(o)["node.description"]
			.as_str()
			.unwrap_or(text(props(o), "node.name"))
			.into(),
		selected,
	}
}

pub fn select_main_output(_: &Config, endpoint: &str) -> Result<()> {
	select(endpoint, false)
}
pub fn select_main_input(endpoint: &str) -> Result<()> {
	select(endpoint, true)
}
fn select(name: &str, input: bool) -> Result<()> {
	let objects = dump()?;
	let target = node(&objects, name).context("Audio device is no longer connected")?;
	let class = if input { "Audio/Source" } else { "Audio/Sink" };
	if props(target)["media.class"] != class || !physical(props(target)) {
		bail!("Select a physical audio device");
	}
	command("wpctl", &["set-default", &target["id"].to_string()])?;
	Ok(())
}

pub fn graph_snapshot(config: &Config) -> Result<GraphSnapshot> {
	let objects = dump()?;
	let main_input = selected(&objects, true);
	let main_output = selected(&objects, false);
	let devices = |input: bool| {
		objects
			.iter()
			.filter(|o| {
				props(o)["media.class"] == if input { "Audio/Source" } else { "Audio/Sink" }
					&& physical(props(o))
			})
			.map(|o| {
				endpoint(
					o,
					if input { &main_input } else { &main_output }
						.as_ref()
						.is_some_and(|e| e.id == text(props(o), "node.name")),
				)
			})
			.collect()
	};
	let online = BUSES
		.iter()
		.all(|(id, _)| node(&objects, &format!("amps.{id}")).is_some());
	Ok(GraphSnapshot {
		platform: "linux",
		engine_online: online,
		routing_ready: online,
		sample_rate: 48000,
		suppression: if config.noise_suppression.enabled {
			if config.noise_suppression.engine == "nvidia_afx" {
				"NVIDIA AFX (RTX)"
			} else {
				"DeepFilterNet3 (CPU)"
			}
		} else {
			"Bypassed"
		}
		.into(),
		suppression_engine: config.noise_suppression.engine.clone(),
		suppression_enabled: config.noise_suppression.enabled,
		suppression_intensity: crate::suppression_intensity(&config.noise_suppression),
		suppression_attenuation_limit_db: config.noise_suppression.attenuation_limit_db,
		input_devices: devices(true),
		output_devices: devices(false),
		main_input,
		main_output,
		devices: config.devices.clone(),
		session_override: None,
		session_input_override: None,
		buses: BUSES
			.iter()
			.map(|(id, name)| BusSummary {
				id,
				name: format!("AMPS {name}"),
				purpose: "PipeWire",
				spatial: None,
			})
			.collect(),
		patch_sources: crate::patch_sources(),
		patch_destinations: crate::patch_destinations(),
		patches: config.patchbay.connections.clone(),
		routes: config.routes.clone(),
		monitor_latency_ms: config.monitor.latency_ms,
		microphone_latency_ms: config.microphone.latency_ms,
	})
}

struct Process(Child);
impl Drop for Process {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
	}
}

fn bus(id: &str, name: &str) -> Result<Process> {
	let capture = json!({"adapter.auto-port-config":{"mode":"dsp","monitor":false,"position":"preserve"},"node.name":format!("amps.{id}.sink"),"node.description":format!("AMPS {name}"),
		"media.class":"Audio/Sink","node.virtual":true,"node.autoconnect":false,"priority.session":0});
	let playback = json!({"adapter.auto-port-config":{"mode":"dsp","monitor":false,"position":"preserve"},"node.name":format!("amps.{id}"),"node.description":format!("AMPS {name}"),
		"media.class":"Audio/Source","node.virtual":true,"node.autoconnect":false,"priority.session":0});
	Ok(Process(
		Command::new("pw-loopback")
			.args([
				"--name",
				&format!("amps-{id}"),
				"--latency",
				"20",
				"--capture-props",
				&capture.to_string(),
				"--playback-props",
				&playback.to_string(),
			])
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.spawn()?,
	))
}

fn filter_config(plugin: &str, engine: &str) -> Value {
	let mut value = json!({
		"context.properties": {"core.daemon":false},
		"context.spa-libs": {"audio.convert.*":"audioconvert/libspa-audioconvert","support.*":"support/libspa-support"},
		"context.modules": [
			{"name":"libpipewire-module-rt","flags":["ifexists","nofail"]},
			{"name":"libpipewire-module-protocol-native"},
			{"name":"libpipewire-module-client-node"},
			{"name":"libpipewire-module-adapter"},
			{"name":"libpipewire-module-filter-chain","args":{
				"node.description":"AMPS Noise Suppression","audio.rate":48000,"audio.channels":1,"audio.position":["MONO"],
				"capture.props":{"node.name":"amps.filter.input","node.autoconnect":false},
				"playback.props":{"node.name":"amps.filter.output","node.autoconnect":false},
				"filter.graph":{"nodes":[{"type":"ladspa","name":"denoise","plugin":plugin,"label":"deep_filter_mono",
					"control":{"Attenuation Limit (dB)":20.0,"Min processing threshold (dB)":-15.0,
						"Max ERB processing threshold (dB)":35.0,"Max DF processing threshold (dB)":35.0,
						"Min Processing Buffer (frames)":0.0,"Post Filter Beta":0.0}}],
					"inputs":["denoise:Audio In"],"outputs":["denoise:Audio Out"]}
			}}
		]
	});
	let args = &mut value["context.modules"][4]["args"];
	for side in ["capture.props", "playback.props"] {
		args[side]["adapter.auto-port-config"] =
			json!({"mode":"dsp","monitor":false,"position":"preserve"});
	}
	args["capture.props"]["node.name"] = format!("amps.filter.{engine}.input").into();
	args["playback.props"]["node.name"] = format!("amps.filter.{engine}.output").into();
	if engine == "nvidia_afx" {
		args["filter.graph"]["nodes"][0]["label"] = "linux_broadcast_bnr2".into();
		args["filter.graph"]["nodes"][0]["control"] = json!({"Intensity":0.5});
		args["filter.graph"]["inputs"] = json!(["denoise:Microphone Input"]);
		args["filter.graph"]["outputs"] = json!(["denoise:NVIDIA AFX Output"]);
	}
	value
}

type Links = BTreeSet<(u64, u64)>;
fn ports(objects: &[Value], name: &str, direction: &str) -> Vec<(u64, String)> {
	let Some(n) = node(objects, name) else {
		return vec![];
	};
	objects
		.iter()
		.filter(|o| {
			o["type"] == "PipeWire:Interface:Port"
				&& props(o)["node.id"] == n["id"]
				&& props(o)["port.direction"] == direction
		})
		.filter_map(|o| Some((o["id"].as_u64()?, text(props(o), "audio.channel").into())))
		.collect()
}
fn wire(objects: &[Value], source: &str, target: &str, links: &mut Links) -> bool {
	let outputs = ports(objects, source, "out");
	let inputs = ports(objects, target, "in");
	if outputs.is_empty() || inputs.is_empty() {
		return false;
	}
	for (input, channel) in &inputs {
		if let Some((output, _)) = outputs
			.iter()
			.find(|(_, c)| c == channel)
			.or_else(|| outputs.first())
		{
			links.insert((*output, *input));
		}
	}
	true
}
fn plan(config: &Config, objects: &[Value]) -> (Links, BTreeMap<String, String>) {
	let mut links = Links::new();
	let mut unavailable = BTreeMap::new();
	if let Some(input) = selected(objects, true) {
		if config.noise_suppression.enabled {
			let filter = format!("amps.filter.{}", config.noise_suppression.engine);
			wire(objects, &input.id, &format!("{filter}.input"), &mut links);
			wire(
				objects,
				&format!("{filter}.output"),
				"amps.clean_mic.sink",
				&mut links,
			);
		} else {
			wire(objects, &input.id, "amps.clean_mic.sink", &mut links);
		}
	}
	for patch in &config.patchbay.connections {
		let source = if patch.source == "phone" {
			objects
				.iter()
				.find(|o| {
					props(o)["media.class"] == "Audio/Source"
						&& text(props(o), "node.name").starts_with("bluez_input.")
						&& (props(o)["api.bluez5.profile"] == "a2dp-source"
							|| props(o)["factory.name"] == "api.bluez5.a2dp.source")
				})
				.map(|o| text(props(o), "node.name").into())
				.unwrap_or_default()
		} else if let Some(d) = config.devices.iter().find(|d| d.id == patch.source) {
			d.endpoint_id.clone()
		} else {
			format!("amps.{}", patch.source)
		};
		let target = if matches!(patch.destination.as_str(), "monitor" | "main_output") {
			selected(objects, false).map(|e| e.id).unwrap_or_default()
		} else if let Some(d) = config.devices.iter().find(|d| d.id == patch.destination) {
			d.endpoint_id.clone()
		} else {
			format!("amps.{}.sink", patch.destination)
		};
		if !wire(objects, &source, &target, &mut links) {
			unavailable.insert(
				format!("{}:{}", patch.source, patch.destination),
				"Waiting for audio device".into(),
			);
		}
	}
	(links, unavailable)
}

struct Backend {
	links: Links,
	config: Config,
	spatial_output: String,
	filter_state: String,
	routes: String,
}
impl Backend {
	fn apply(&mut self, config: &Config) -> Result<BTreeMap<String, String>> {
		let objects = dump()?;
		let routes = serde_json::to_string(&config.routes)?;
		if routes != self.routes {
			command(
				"pw-metadata",
				&[
					"-n",
					"default",
					"0",
					"amps.routes",
					&routes,
					"Spa:String:JSON",
				],
			)?;
			self.routes = routes;
		}
		let output = selected(&objects, false).map(|e| e.id).unwrap_or_default();
		let spatial_state = format!(
			"{output}:{:?}",
			["game", "music"]
				.map(|bus| node(&objects, &format!("amps.{bus}.sink"))
					.map(|n| n["info"]["state"].clone()))
		);
		if spatial_state != self.spatial_output {
			let headphones = output.starts_with("bluez_output.")
				|| output.contains("blue-yeti")
				|| output.contains("tx-hifi")
				|| node(&objects, &output).is_some_and(|n| {
					matches!(
						text(props(n), "device.form-factor"),
						"headphones" | "headset"
					)
				});
			for bus in ["game", "music"] {
				if let Some(node) = node(&objects, &format!("amps.{bus}.sink")) {
					if props(node)["amps.spatial"] != true {
						continue;
					}
					let wet = if headphones { 1.0 } else { 0.0 };
					let param = json!({"params":["selectL:Gain 1",wet,"selectL:Gain 2",1.0-wet,"selectR:Gain 1",wet,"selectR:Gain 2",1.0-wet]});
					command(
						"pw-cli",
						&[
							"set-param",
							&node["id"].to_string(),
							"Props",
							&param.to_string(),
						],
					)?;
				}
			}
			self.spatial_output = spatial_state;
		}
		let filter_name = format!("amps.filter.{}.input", config.noise_suppression.engine);
		if config.noise_suppression.enabled {
			if let Some(filter) = node(&objects, &filter_name) {
				if filter["info"]["state"] == "error" {
					bail!("Noise filter failed: {}", filter["info"]["error"]);
				}
			}
		}
		if config.noise_suppression.enabled && node(&objects, &filter_name).is_none() {
			bail!(
				"Selected noise filter is not running: {}",
				config.noise_suppression.engine
			);
		}
		let (desired, unavailable) = plan(config, &objects);
		let present: Links = objects
			.iter()
			.filter(|o| o["type"] == "PipeWire:Interface:Link")
			.filter_map(|o| {
				Some((
					o["info"]["output-port-id"].as_u64()?,
					o["info"]["input-port-id"].as_u64()?,
				))
			})
			.collect();
		self.links.retain(|link| present.contains(link));
		for (out, input) in self.links.difference(&desired).copied().collect::<Vec<_>>() {
			command("pw-link", &["-d", &out.to_string(), &input.to_string()])?;
			self.links.remove(&(out, input));
		}
		for (out, input) in desired.difference(&self.links).copied().collect::<Vec<_>>() {
			command("pw-link", &[&out.to_string(), &input.to_string()])?;
			self.links.insert((out, input));
		}
		if let Some(filter) = node(&objects, &filter_name) {
			let state = format!(
				"{}:{}:{}",
				filter_name, filter["id"], filter["info"]["state"]
			);
			if self.config.noise_suppression != config.noise_suppression || self.filter_state != state
			{
				let param = if config.noise_suppression.engine == "nvidia_afx" {
					json!({"params":["denoise:Intensity", crate::suppression_intensity(&config.noise_suppression) as f32 / 100.0]})
				} else {
					json!({"params":["denoise:Attenuation Limit (dB)", config.noise_suppression.attenuation_limit_db,
						"denoise:Post Filter Beta",config.noise_suppression.post_filter_beta]})
				};
				command(
					"pw-cli",
					&[
						"set-param",
						&filter["id"].to_string(),
						"Props",
						&param.to_string(),
					],
				)?;
				self.filter_state = state;
			}
		}
		self.config = config.clone();
		Ok(unavailable)
	}
}
impl control::Backend for Backend {
	type Staged = (Config, Config);
	fn stage(&mut self, previous: &Config, next: &Config) -> Result<Self::Staged> {
		if next.noise_suppression.enabled
			&& node(
				&dump()?,
				&format!("amps.filter.{}.input", next.noise_suppression.engine),
			)
			.is_none()
		{
			bail!(
				"Selected noise filter has not initialized: {}",
				next.noise_suppression.engine
			);
		}
		Ok((previous.clone(), next.clone()))
	}
	fn activate(&mut self, staged: &mut Self::Staged) -> Result<()> {
		self.apply(&staged.1).map(|_| ())
	}
	fn rollback(&mut self, staged: Self::Staged) -> Result<()> {
		self.apply(&staged.0).map(|_| ())
	}
	fn finish(&mut self, _: Self::Staged) {}
}

pub fn run(config: Config, path: PathBuf, stop: Arc<AtomicBool>) -> Result<()> {
	let _lock = control::EngineLock::acquire(&path)?;
	let existing = dump()?;
	if existing
		.iter()
		.any(|o| text(props(o), "node.name").starts_with("amps."))
	{
		bail!("AMPS nodes already exist; stop the other engine first");
	}
	let mut children: Vec<Process> = Vec::new();
	let spatial: Value = match std::env::var("AMPS_SPATIAL_FILTERS") {
		Ok(file) => serde_json::from_slice(&std::fs::read(file)?)?,
		Err(_) => json!({}),
	};
	for (id, name) in BUSES {
		if let Some(args) = spatial.get(id) {
			let mut args = args.clone();
			for (side, node_name, class) in [
				("capture.props", format!("amps.{id}.sink"), "Audio/Sink"),
				("playback.props", format!("amps.{id}"), "Audio/Source"),
			] {
				args[side]["node.name"] = node_name.into();
				args[side]["node.description"] = format!("AMPS {name}").into();
				args[side]["media.class"] = class.into();
				args[side]["node.autoconnect"] = false.into();
				args[side]["node.virtual"] = true.into();
				args[side]["node.passive"] = false.into();
				args[side]["priority.session"] = 0.into();
				args[side]["amps.spatial"] = true.into();
				args[side]["adapter.auto-port-config"] =
					json!({"mode":"dsp","monitor":false,"position":"preserve"});
			}
			let mut client = filter_config("", "spatial");
			client["context.modules"][4]["args"] = args;
			let file = path.with_file_name(format!("pipewire-{id}.conf"));
			control::atomic_write(&file, &serde_json::to_vec(&client)?)?;
			children.push(Process(
				Command::new("pipewire")
					.arg("-c")
					.arg(file)
					.stdin(Stdio::null())
					.stdout(Stdio::null())
					.spawn()?,
			));
		} else {
			children.push(bus(id, name)?);
		}
	}
	for (engine, variable) in [
		("deepfilternet3", "AMPS_DEEPFILTER_PLUGIN"),
		("nvidia_afx", "AMPS_NVIDIA_PLUGIN"),
	] {
		let plugin = std::env::var(variable).with_context(|| format!("Missing {variable}"))?;
		let filter_file = path.with_file_name(format!("pipewire-{engine}.conf"));
		control::atomic_write(
			&filter_file,
			&serde_json::to_vec(&filter_config(&plugin, engine))?,
		)?;
		children.push(Process(
			Command::new("pipewire")
				.arg("-c")
				.arg(&filter_file)
				.stdin(Stdio::null())
				.stdout(Stdio::null())
				.spawn()?,
		));
	}
	let mut ready = false;
	for _ in 0..600 {
		let objects = dump()?;
		if BUSES
			.iter()
			.all(|(id, _)| !ports(&objects, &format!("amps.{id}"), "out").is_empty())
			&& !ports(&objects, "amps.filter.nvidia_afx.input", "in").is_empty()
			&& !ports(&objects, "amps.filter.deepfilternet3.input", "in").is_empty()
		{
			ready = true;
			break;
		}
		thread::sleep(Duration::from_millis(50));
	}
	if !ready {
		bail!("PipeWire did not create all AMPS nodes");
	}
	let mut initial = config.clone();
	initial.noise_suppression.attenuation_limit_db = -1.0;
	let mut backend = Backend {
		links: Links::new(),
		config: initial,
		spatial_output: "uninitialized".into(),
		filter_state: String::new(),
		routes: String::new(),
	};
	let mut server = control::Server::new(&path, config.clone())?;
	server.status.unavailable_routes = backend.apply(&config)?;
	server.ready()?;
	let result = (|| -> Result<()> {
		while !stop.load(Ordering::Acquire) {
			for child in &mut children {
				if let Some(status) = child.0.try_wait()? {
					bail!("PipeWire audio worker exited: {status}");
				}
			}
			if let Some(request) = server.next_request()? {
				server.execute(&request, &mut backend)?;
			}
			server.status.unavailable_routes = backend.apply(server.config())?;
			let objects = dump()?;
			server.status.input_name = selected(&objects, true).map(|e| e.name).unwrap_or_default();
			server.status.output_name = selected(&objects, false)
				.map(|e| e.name)
				.unwrap_or_default();
			server.publish()?;
			thread::sleep(Duration::from_millis(250));
		}
		Ok(())
	})();
	let _ = control::mark_offline(&path);
	drop(children);
	result
}

pub fn print_devices() -> Result<()> {
	for object in dump()? {
		if physical(props(&object))
			&& matches!(
				text(props(&object), "media.class"),
				"Audio/Sink" | "Audio/Source"
			) {
			println!(
				"{}\t{}\t{}",
				text(props(&object), "media.class"),
				text(props(&object), "node.name"),
				text(props(&object), "node.description")
			);
		}
	}
	Ok(())
}

pub fn doctor(config: &Config) -> Result<()> {
	config.validate()?;
	let snapshot = graph_snapshot(config)?;
	if !snapshot.engine_online {
		bail!("AMPS PipeWire endpoints are not running");
	}
	if snapshot.main_input.is_none() || snapshot.main_output.is_none() {
		bail!("A physical input or output is missing");
	}
	println!("AMPS PipeWire graph online; input and output available");
	Ok(())
}
pub fn print_cable_endpoints(_: &Config) -> Result<()> {
	for (id, name) in BUSES {
		println!("{id}\tAMPS {name}\tamps.{id}.sink\tamps.{id}");
	}
	Ok(())
}
pub fn benchmark(_: &Config, _: u32) -> Result<()> {
	bail!("Use PipeWire profiler for native filter performance measurements")
}
pub fn levels(config: &Config, seconds: u32) -> Result<()> {
	let mut probe = MeterProbe::new(config)?;
	for _ in 0..seconds {
		thread::sleep(Duration::from_secs(1));
		println!("{}", serde_json::to_string(&probe.read())?);
	}
	Ok(())
}

pub struct CleanMicMonitor {
	_process: Process,
	output: String,
}
impl CleanMicMonitor {
	pub fn new(_: &Config) -> Result<Self> {
		let output = selected(&dump()?, false).context("No output connected")?;
		let process = Process(
			Command::new("pw-loopback")
				.args([
					"--name",
					"amps-mic-preview",
					"--capture",
					"amps.clean_mic",
					"--playback",
					&output.id,
					"--latency",
					"30",
				])
				.stdin(Stdio::null())
				.stdout(Stdio::null())
				.spawn()?,
		);
		Ok(Self {
			_process: process,
			output: output.name,
		})
	}
	pub fn output_name(&self) -> &str {
		&self.output
	}
}

pub struct MeterProbe {
	_processes: Vec<Process>,
	readings: Arc<Mutex<Vec<(Instant, MeterReading)>>>,
	identity: Vec<(String, String)>,
}
fn meter_targets(objects: &[Value], config: &Config) -> Vec<(String, String)> {
	let mut targets: Vec<_> = BUSES
		.iter()
		.filter(|(id, _)| node(objects, &format!("amps.{id}")).is_some())
		.map(|(id, _)| (id.replace('_', "-"), format!("amps.{id}")))
		.collect();
	if let Some(input) = selected(objects, true) {
		targets.push(("physical-mic".into(), input.id));
	}
	let processed = if config.noise_suppression.enabled {
		format!("amps.filter.{}.output", config.noise_suppression.engine)
	} else {
		selected(objects, true).map(|e| e.id).unwrap_or_default()
	};
	if !processed.is_empty() {
		targets.push(("processed-mic".into(), processed));
	}
	if let Some(output) = selected(objects, false) {
		targets.push(("monitor".into(), output.id));
	}
	for device in &config.devices {
		targets.push((device.id.clone(), device.endpoint_id.clone()));
	}
	targets
}
impl MeterProbe {
	pub fn new(config: &Config) -> Result<Self> {
		let objects = dump()?;
		let identity = meter_targets(&objects, config);
		let readings = Arc::new(Mutex::new(Vec::<(Instant, MeterReading)>::new()));
		let mut processes = Vec::new();
		for (id, target) in &identity {
			let sink = node(&objects, target).is_some_and(|n| props(n)["media.class"] == "Audio/Sink");
			let properties = format!(
				"{{ application.name = AMPS-Meter node.passive = true stream.capture.sink = {sink} }}"
			);
			let mut child = Command::new("pw-cat")
				.args([
					"--record",
					"--raw",
					"--format",
					"f32",
					"--rate",
					"48000",
					"--channels",
					"1",
					"--target",
					target,
					"--latency",
					"40ms",
					"--properties",
					&properties,
					"-",
				])
				.stdin(Stdio::null())
				.stdout(Stdio::piped())
				.stderr(Stdio::null())
				.spawn()?;
			let mut output = child.stdout.take().context("Missing meter pipe")?;
			processes.push(Process(child));
			let state = readings.clone();
			let id = id.clone();
			thread::spawn(move || {
				let mut bytes = [0u8; 4096];
				while output.read_exact(&mut bytes).is_ok() {
					let samples: Vec<f32> = bytes
						.chunks_exact(4)
						.map(|b| f32::from_le_bytes(b.try_into().unwrap()))
						.collect();
					let peak = samples.iter().fold(0.0f32, |p, s| p.max(s.abs()));
					let reading = MeterReading {
						id: id.clone(),
						peak,
						dbfs: 20.0 * peak.max(1e-9).log10(),
						waveform: samples
							.chunks(8)
							.map(|s| {
								s.iter()
									.copied()
									.max_by(|a, b| a.abs().total_cmp(&b.abs()))
									.unwrap_or(0.0)
							})
							.collect(),
					};
					if let Ok(mut readings) = state.lock() {
						readings.retain(|(_, r)| r.id != id);
						readings.push((Instant::now(), reading));
					}
				}
			});
		}
		Ok(Self {
			_processes: processes,
			readings,
			identity,
		})
	}
	pub fn read(&mut self) -> Vec<MeterReading> {
		self
			.readings
			.lock()
			.map(|readings| {
				readings
					.iter()
					.map(|(time, reading)| {
						let mut reading = reading.clone();
						if time.elapsed() > Duration::from_millis(250) {
							reading.peak = 0.0;
							reading.dbfs = -180.0;
							reading.waveform.fill(0.0);
						}
						reading
					})
					.collect()
			})
			.unwrap_or_default()
	}
	pub fn is_current(&self, config: &Config) -> Result<bool> {
		Ok(self.identity == meter_targets(&dump()?, config))
	}
}
pub fn meter_snapshot(config: &Config) -> Result<Vec<MeterReading>> {
	let mut probe = MeterProbe::new(config)?;
	thread::sleep(Duration::from_millis(100));
	Ok(probe.read())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn filter_does_not_autoconnect_or_create_a_server() {
		let filter = filter_config("/test/deepfilter.so", "deepfilternet3");
		assert_eq!(filter["context.properties"]["core.daemon"], false);
		let args = &filter["context.modules"][4]["args"];
		assert_eq!(args["capture.props"]["node.autoconnect"], false);
		assert_eq!(args["playback.props"]["node.autoconnect"], false);
	}
	#[test]
	fn nvidia_uses_native_afx_and_keeps_the_existing_engine_key() {
		let filter = filter_config("/test/afx.so", "nvidia_afx");
		let args = &filter["context.modules"][4]["args"];
		assert_eq!(
			args["capture.props"]["node.name"],
			"amps.filter.nvidia_afx.input"
		);
		assert_eq!(
			args["filter.graph"]["nodes"][0]["label"],
			"linux_broadcast_bnr2"
		);
		assert_eq!(
			args["filter.graph"]["nodes"][0]["control"]["Intensity"],
			0.5
		);
	}
	#[test]
	fn virtual_buses_cannot_be_selected_as_physical_devices() {
		assert!(!physical(&json!({"node.name":"amps.game"})));
		assert!(!physical(&json!({"node.name":"creator.mic.clean"})));
		assert!(physical(&json!({"node.name":"alsa_output.test"})));
	}
}
