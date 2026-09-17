export const key = (source, destination) => `${source}:${destination}`;
export const visibleDestination = destination =>
	destination === "monitor" ? "main_output" : destination;
export const edgeRoute = edge => ({
	source: edge.source,
	destination: edge.routeDestination ?? edge.target
});
export function connectionRoute(connection, replacing) {
	if (replacing && connection.target === replacing.target)
		return { source: connection.source, destination: edgeRoute(replacing).destination };
	return {
		source: connection.source,
		destination:
			connection.target === "main_output" && connection.source !== "phone" ?
				"monitor"
			:	connection.target
	};
}
export const colors = {
	game: "#2288ff",
	comms: "#e98181",
	music: "#ffbb33",
	chatgpt: "#cc99ff",
	clean_mic: "#94b300",
	chatgpt_in: "#cc99ff",
	comms_send: "#e98181",
	monitor: "#99ccff",
	phone: "#66cccc"
};
export function reaches(edges, from, to) {
	const queue = [from],
		seen = new Set();
	while (queue.length) {
		const node = queue.pop();
		if (node === to) return true;
		if (seen.has(node)) continue;
		seen.add(node);
		for (const e of edges) if (e.source === node) queue.push(e.destination ?? e.target);
	}
	return false;
}
export function validateConnection(topology, patches, connection, replacing) {
	const source = topology.nodes.find(n => n.id === connection.source),
		target = topology.nodes.find(n => n.id === connection.target);
	if (
		!source?.outputs.some(p => p.id === connection.sourceHandle && p.editable) ||
		!target?.inputs.some(p => p.id === connection.targetHandle && p.editable)
	)
		return "This port is part of a fixed pipeline, not an editable audio connection.";
	const remaining = patches
		.filter(p => !replacing || key(p.source, p.destination) !== replacing)
		.map(p => ({ ...p, destination: visibleDestination(p.destination) }));
	if (connection.source === connection.target) return "A bus cannot feed itself.";
	if (remaining.some(p => p.source === source.id && p.destination === target.id))
		return "That connection already exists.";
	if (reaches(remaining, target.id, source.id)) return "That connection creates a feedback loop.";
	const next = [...remaining, { source: source.id, destination: target.id }];
	for (const [from, to] of [
		["comms", "comms_send"],
		["chatgpt", "chatgpt_in"]
	])
		if (reaches(next, from, to))
			return `Blocked self-return: ${from === "comms" ? "Comms Audio → Comms Mic" : "AI Audio → AI Mic"}.`;
	return null;
}
export function trace(topology, id) {
	if (!id) return new Set(topology.edges.map(e => e.id));
	return new Set(
		topology.edges
			.filter(
				e => reaches(topology.edges, id, e.source) || reaches(topology.edges, e.target, id)
			)
			.map(e => e.id)
	);
}

// Nodes and wires must describe the same selected signal path. Null nodeIds
// means overview (including unwired nodes), not an empty/fully dimmed graph.
export function focusTrace(topology, nodeId, edgeId) {
	const node = topology.nodes.find(n => n.id === nodeId);
	const edge = topology.edges.find(e => e.id === edgeId);
	if (!node && !edge) return { edgeIds: trace(topology, null), nodeIds: null };
	const edgeIds = edge ? new Set([edge.id]) : trace(topology, node.id);
	const nodeIds = new Set(edge ? [] : [node.id]);
	for (const e of topology.edges) {
		if (edgeIds.has(e.id)) {
			nodeIds.add(e.source);
			nodeIds.add(e.target);
		}
	}
	return { edgeIds, nodeIds };
}
// Audio samples are interpolated by path distance, not squeezed into one period
// per edge. Silent/missing samples never become a synthetic travelling signal.
export function waveformPoints(geometry, samples, peak) {
	if (!samples?.length || !geometry.length || peak < 0.002) return "";
	return geometry
		.map((p, i) => {
			const position = p.distance / 5,
				lo = Math.floor(position) % samples.length,
				blend = position - Math.floor(position);
			const sample = samples[lo] * (1 - blend) + samples[(lo + 1) % samples.length] * blend;
			const taper = Math.min(1, p.distance / 24, (geometry.at(-1).distance - p.distance) / 24);
			const offset = Math.tanh(sample * 10) * 18 * Math.max(0, taper);
			return `${i ? "L" : "M"}${(p.x + p.nx * offset).toFixed(1)},${(p.y + p.ny * offset).toFixed(1)}`;
		})
		.join(" ");
}
export function loadLayout(storage) {
	try {
		const value = JSON.parse(storage.getItem("audioarray:layout:v1") || "null");
		return value?.version === 1 && typeof value.positions === "object" ? value : null;
	} catch {
		return null;
	}
}

// ELK computes a complete layout, but saved positions override individual nodes.
// Mixing those coordinate sets can put a new node on top of a saved one. Preserve
// valid saved positions first, then move only colliding nodes down into free space.
export function reconcilePositions(children, saved = {}, gap = 54) {
	const positions = {},
		occupied = [];
	const valid = p => Number.isFinite(p?.x) && Number.isFinite(p?.y);
	const ordered = [
		...children.filter(n => valid(saved[n.id])),
		...children.filter(n => !valid(saved[n.id]))
	];
	for (const n of ordered) {
		const preferred = valid(saved[n.id]) ? saved[n.id] : n;
		const spot = { x: preferred.x, y: preferred.y, width: n.width, height: n.height };
		let collision;
		while (
			(collision = occupied.find(
				o =>
					spot.x < o.x + o.width + gap &&
					spot.x + spot.width + gap > o.x &&
					spot.y < o.y + o.height + gap &&
					spot.y + spot.height + gap > o.y
			))
		) {
			spot.y = collision.y + collision.height + gap;
		}
		positions[n.id] = { x: spot.x, y: spot.y };
		occupied.push(spot);
	}
	return positions;
}
