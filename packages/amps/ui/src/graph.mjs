export const key = (source, destination) => `${source}:${destination}`;
export const colors = {
	game: "#2288ff",
	comms: "#e98181",
	music: "#ffbb33",
	chatgpt: "#cc99ff",
	clean_mic: "#94b300",
	chatgpt_in: "#cc99ff",
	comms_send: "#e98181",
	monitor: "#99ccff"
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
	const remaining = patches.filter(p => !replacing || key(p.source, p.destination) !== replacing);
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
