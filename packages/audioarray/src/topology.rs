//! Platform-neutral canvas projection of AudioArray-owned routes and processing.
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
			"Comms Audio",
			"comms",
			"Received voice · VAC 02",
			None,
		),
		(
			"music",
			"Media",
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
			"AI Audio",
			"chatgpt",
			"AI playback only · VAC 05",
			None,
		),
		(
			"chatgpt_in",
			"AI Mic",
			"chatgpt-in",
			"AI microphone mix · VAC 06",
			None,
		),
		(
			"comms_send",
			"Comms Mic",
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
			} else if id == "monitor" {
				vec![port("out", "To device", "output", false)]
			} else {
				vec![]
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

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn canvas_contains_only_owned_routes_devices_and_processing() {
		let graph = GraphSnapshot {
			platform: "test",
			engine_online: false,
			routing_ready: false,
			sample_rate: 48000,
			suppression: String::new(),
			suppression_engine: String::new(),
			suppression_enabled: false,
			suppression_intensity: 0,
			suppression_attenuation_limit_db: 0.0,
			main_input: None,
			main_output: None,
			input_devices: vec![],
			output_devices: vec![],
			session_override: None,
			session_input_override: None,
			buses: vec![],
			patch_sources: crate::patch_sources(),
			patch_destinations: crate::patch_destinations(),
			patches: vec![],
			routes: vec![],
			monitor_latency_ms: 0,
			microphone_latency_ms: 0,
		};
		let patches = crate::PatchbayConfig::default().connections;
		let topology = project(&graph, &patches, None);
		assert_eq!(topology.nodes.len(), 11);
		for (id, title, meter) in [
			("music", "Media", "music"),
			("comms", "Comms Audio", "comms"),
			("comms_send", "Comms Mic", "comms-send"),
			("chatgpt", "AI Audio", "chatgpt"),
			("chatgpt_in", "AI Mic", "chatgpt-in"),
		] {
			let node = topology.nodes.iter().find(|n| n.id == id).unwrap();
			assert_eq!(node.title, title);
			assert_eq!(node.meter.as_deref(), Some(meter));
		}
		assert!(topology.nodes.iter().all(|n| n.kind != "external"));
		assert_eq!(topology.edges.len(), patches.len() + 3);
		assert_eq!(
			topology.edges.iter().filter(|e| e.kind == "patch").count(),
			patches.len()
		);
		for e in &topology.edges {
			assert!(matches!(e.kind, "patch" | "fixed"));
			let source = topology.nodes.iter().find(|n| n.id == e.source).unwrap();
			let target = topology.nodes.iter().find(|n| n.id == e.target).unwrap();
			assert!(source.outputs.iter().any(|p| p.id == e.source_handle));
			assert!(target.inputs.iter().any(|p| p.id == e.target_handle));
			assert_eq!(e.meter, source.meter);
		}
		for id in ["chatgpt_in", "comms_send"] {
			let node = topology.nodes.iter().find(|n| n.id == id).unwrap();
			assert!(
				node.outputs.is_empty(),
				"No illustrative external-consumer port"
			);
			assert!(node.inputs.iter().any(|p| p.editable));
		}
		let monitor = topology.nodes.iter().find(|n| n.id == "monitor").unwrap();
		assert!(monitor.inputs.iter().any(|p| p.editable));
		assert!(topology
			.edges
			.iter()
			.any(|e| e.source == "monitor" && e.target == "main_output"));
	}
}
