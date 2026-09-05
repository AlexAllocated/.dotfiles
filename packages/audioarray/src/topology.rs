//! Platform-neutral canvas projection. Fixed/policy edges are not patch commands.
use crate::{GraphSnapshot, PatchConnection};
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Port {
	pub id: String,
	pub label: String,
	pub direction: &'static str,
	pub editable: bool,
	pub signal: &'static str,
	pub fan_in: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
	pub id: String,
	pub title: String,
	pub kind: &'static str,
	pub detail: String,
	pub meter: Option<String>,
	pub inputs: Vec<Port>,
	pub outputs: Vec<Port>,
	pub effect: Option<&'static str>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Edge {
	pub id: String,
	pub source: String,
	pub target: String,
	pub source_handle: String,
	pub target_handle: String,
	pub kind: &'static str,
	pub meter: Option<String>,
	pub label: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct Topology {
	pub nodes: Vec<Node>,
	pub edges: Vec<Edge>,
}
fn port(id: &str, label: &str, direction: &'static str, editable: bool) -> Port {
	Port {
		id: id.into(),
		label: label.into(),
		direction,
		editable,
		signal: "PCM · negotiated stereo/mono",
		fan_in: direction == "input" && editable,
	}
}
fn edge(source: &str, target: &str, kind: &'static str, meter: Option<&str>, label: &str) -> Edge {
	Edge {
		id: format!("{kind}:{source}:{target}"),
		source: source.into(),
		target: target.into(),
		source_handle: "out".into(),
		target_handle: "in".into(),
		kind,
		meter: meter.map(Into::into),
		label: label.into(),
	}
}
pub fn project(
	graph: &GraphSnapshot,
	patches: &[PatchConnection],
	runtime: Option<&crate::control::Status>,
) -> Topology {
	let mut nodes = Vec::new();
	let mut edges = Vec::new();
	for (id, title, kind, detail, meter, input, output) in [
		(
			"physical_mic",
			"Main Input",
			"device",
			graph
				.session_input_override
				.as_deref()
				.or(graph.main_input.as_ref().map(|x| x.name.as_str()))
				.unwrap_or("No available microphone"),
			Some("physical-mic"),
			false,
			true,
		),
		(
			"noise_filter",
			"Noise Suppression",
			"processor",
			"Fixed microphone stage · select to adjust",
			Some("processed-mic"),
			true,
			true,
		),
		(
			"main_output",
			"Main Output",
			"device",
			graph
				.session_override
				.as_deref()
				.or(graph.main_output.as_ref().map(|x| x.name.as_str()))
				.unwrap_or("No available output"),
			Some("monitor"),
			true,
			false,
		),
		(
			"obs",
			"OBS Studio",
			"external",
			"Configured isolated stems · externally managed; session not verified",
			None,
			true,
			false,
		),
	] {
		nodes.push(Node {
			id: id.into(),
			title: title.into(),
			kind,
			detail: detail.into(),
			meter: meter.map(Into::into),
			inputs: if input {
				vec![port("in", "Signal in", "input", false)]
			} else {
				vec![]
			},
			outputs: if output {
				vec![port("out", "Signal out", "output", false)]
			} else {
				vec![]
			},
			effect: None,
		});
	}
	for (id, title, meter, detail, effect) in [
		(
			"game",
			"Game",
			"game",
			"Default application playback · VAC 01",
			Some("DTS Headphone:X · Windows endpoint effect"),
		),
		(
			"comms",
			"Comms In",
			"comms",
			"Received voice · VAC 02",
			None,
		),
		(
			"music",
			"Music",
			"music",
			"Media playback · VAC 03",
			Some("Dolby Atmos · Windows endpoint effect"),
		),
		(
			"clean_mic",
			"Clean Mic",
			"clean-mic",
			"Pure filtered microphone · VAC 04",
			None,
		),
		(
			"chatgpt",
			"ChatGPT Out",
			"chatgpt",
			"AI playback only · VAC 05",
			None,
		),
		(
			"chatgpt_in",
			"ChatGPT In",
			"chatgpt-in",
			"AI microphone mix · VAC 06",
			None,
		),
		(
			"comms_send",
			"Comms Send",
			"comms-send",
			"Outgoing voice mix · VAC 07",
			None,
		),
		(
			"monitor",
			"Listening Mix",
			"monitor",
			"Master affects only physical output",
			None,
		),
	] {
		let source = graph.patch_sources.iter().any(|p| p.id == id);
		let target = graph.patch_destinations.iter().any(|p| p.id == id);
		let mut inputs = if target {
			vec![port("in", "Mix in", "input", true)]
		} else {
			vec![]
		};
		if id == "clean_mic" {
			inputs.push(port("fixed", "Filtered mic", "input", false));
		}
		nodes.push(Node {
			id: id.into(),
			title: title.into(),
			kind: if matches!(id, "chatgpt_in" | "comms_send" | "monitor") {
				"mix"
			} else {
				"bus"
			},
			detail: detail.into(),
			meter: Some(meter.into()),
			inputs,
			outputs: if source {
				vec![port("out", "Signal out", "output", true)]
			} else {
				vec![port("out", "To consumer", "output", false)]
			},
			effect,
		});
	}
	for patch in patches {
		let mut e = edge(
			&patch.source,
			&patch.destination,
			"patch",
			Some(&patch.source.replace('_', "-")),
			"Unity gain",
		);
		e.meter = nodes
			.iter()
			.find(|n| n.id == patch.source)
			.and_then(|n| n.meter.clone());
		edges.push(e);
	}
	edges.push(edge(
		"physical_mic",
		"noise_filter",
		"fixed",
		Some("physical-mic"),
		"Microphone capture",
	));
	let mut mic = edge(
		"noise_filter",
		"clean_mic",
		"fixed",
		Some("processed-mic"),
		"Filtered microphone only",
	);
	mic.target_handle = "fixed".into();
	edges.push(mic);
	edges.push(edge(
		"monitor",
		"main_output",
		"fixed",
		Some("monitor"),
		"Master output",
	));
	for id in ["game", "comms", "music", "clean_mic"] {
		edges.push(edge(
			id,
			"obs",
			"policy",
			None,
			"Configured OBS stem; external consumer",
		));
	}
	for (id, title, details) in [
		(
			"ai_capture",
			"ChatGPT / Codex Input",
			"Application capture policy · no AI self-return",
		),
		(
			"comms_capture",
			"Voice App Input",
			"Comms Send selection · no received-voice return",
		),
	] {
		nodes.push(Node {
			id: id.into(),
			title: title.into(),
			kind: "external",
			detail: details.into(),
			meter: None,
			inputs: vec![port("in", "Capture policy", "input", false)],
			outputs: vec![],
			effect: None,
		});
	}
	edges.push(edge(
		"chatgpt_in",
		"ai_capture",
		"policy",
		None,
		"App input preference; explicit selection may override",
	));
	edges.push(edge(
		"comms_send",
		"comms_capture",
		"policy",
		None,
		"App input preference; explicit selection may override",
	));
	if let Some(active) = runtime.filter(|r| r.online && r.applied_revision.is_some()) {
		for node in &mut nodes {
			if node.id == "physical_mic" {
				node.detail = active.input_name.clone();
			}
			if node.id == "main_output" {
				node.detail = active.output_name.clone();
			}
		}
	}
	Topology { nodes, edges }
}
