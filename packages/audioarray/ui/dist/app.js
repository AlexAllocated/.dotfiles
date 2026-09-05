const invoke = window.__TAURI__?.core?.invoke;
const AUDIO_STORAGE_KEY = "audioarray:lcars-audio-muted";
const SVG_NAMESPACE = "http://www.w3.org/2000/svg";
const WAVEFORM_MAX_OFFSET = 24;
const WAVEFORM_PIXELS_PER_SAMPLE = 5;
const meterDefinitions = [
	["physical-mic", "Active Mic"],
	["clean-mic", "Clean Mic"],
	["game", "Game"],
	["comms", "Comms"],
	["music", "Music"],
	["chatgpt", "ChatGPT"],
	["monitor", "Main Output"]
];

const state = {
	snapshot: null,
	meters: new Map(),
	waveformRoutes: new Map(),
	refreshing: false,
	pollingMeters: false,
	applyingSuppression: false,
	editingSuppression: false,
	applyingCleanMicMonitor: false,
	applyingPatch: false,
	monitoringCleanMic: false,
	patchSignature: null,
	muted: localStorage.getItem(AUDIO_STORAGE_KEY) === "1",
	audioUnlocked: false,
	lastSoundAt: 0,
	keyIndex: 0
};

const elements = {
	engineStatus: document.getElementById("engineStatus"),
	platformValue: document.getElementById("platformValue"),
	formatValue: document.getElementById("formatValue"),
	sessionValue: document.getElementById("sessionValue"),
	filterValue: document.getElementById("filterValue"),
	routingState: document.getElementById("routingState"),
	mainOutput: document.getElementById("mainOutput"),
	mainInput: document.getElementById("mainInput"),
	mainOutputName: document.getElementById("mainOutputName"),
	mainInputName: document.getElementById("mainInputName"),
	mainInputPolicy: document.getElementById("mainInputPolicy"),
	suppressionControl: document.querySelector(".suppression-control"),
	suppressionEnabled: document.getElementById("suppressionEnabled"),
	suppressionEngine: document.getElementById("suppressionEngine"),
	suppressionState: document.getElementById("suppressionState"),
	suppressionIntensity: document.getElementById("suppressionIntensity"),
	suppressionIntensityValue: document.getElementById("suppressionIntensityValue"),
	cleanMicMonitor: document.getElementById("cleanMicMonitor"),
	cleanMicMonitorState: document.getElementById("cleanMicMonitorState"),
	monitorLatency: document.getElementById("monitorLatency"),
	micLatency: document.getElementById("micLatency"),
	graphOutputName: document.getElementById("graphOutputName"),
	graphMicName: document.getElementById("graphMicName"),
	graphSuppressionName: document.getElementById("graphSuppressionName"),
	graphSuppressionMode: document.getElementById("graphSuppressionMode"),
	suppressionNode: document.getElementById("suppressionNode"),
	meterBank: document.getElementById("meterBank"),
	patchMatrix: document.getElementById("patchMatrix"),
	patchLines: document.getElementById("patchLines"),
	routeTable: document.getElementById("routeTable"),
	errorConsole: document.getElementById("errorConsole"),
	refreshButton: document.getElementById("refreshButton"),
	audioToggle: document.getElementById("audioToggle")
};

function makeVoice(path, volume) {
	const audio = new Audio(path);
	audio.preload = "auto";
	audio.volume = volume;
	return audio;
}

const voices = {
	key: [makeVoice("./audio/intrepid-key.mp3", 0.25), makeVoice("./audio/key-02.mp3", 0.27)],
	confirm: [makeVoice("./audio/confirm.mp3", 0.3)],
	denied: [makeVoice("./audio/denied.mp3", 0.28)],
	search: [makeVoice("./audio/search.mp3", 0.2)]
};

function updateAudioUi() {
	document.body.dataset.audio = state.muted ? "muted" : state.audioUnlocked ? "online" : "armed";
	elements.audioToggle.textContent = state.muted ? "◖×" : "◖))";
	const label = state.muted ? "Enable interface sounds" : "Mute interface sounds";
	elements.audioToggle.setAttribute("aria-label", label);
	elements.audioToggle.setAttribute("title", label);
}

function playSound(kind) {
	if (state.muted || !state.audioUnlocked || document.hidden) return;
	const now = performance.now();
	if (now - state.lastSoundAt < 38) return;
	state.lastSoundAt = now;
	const bank = voices[kind] || voices.key;
	const index = kind === "key" ? state.keyIndex++ : 0;
	const voice = bank[index % bank.length];
	try {
		voice.currentTime = 0;
	} catch {}
	void voice.play().catch(() => {});
}

function unlockAudio() {
	if (state.audioUnlocked || state.muted) return;
	state.audioUnlocked = true;
	updateAudioUi();
}

function showError(error) {
	const message = String(error?.message || error || "Unknown AudioArray interface failure");
	elements.errorConsole.textContent = `SYSTEM ALERT / ${message}`;
	elements.errorConsole.hidden = false;
	playSound("denied");
}

function clearError() {
	elements.errorConsole.hidden = true;
	elements.errorConsole.textContent = "";
}

function shorten(value, length = 24) {
	if (!value) return "UNAVAILABLE";
	return value.length > length ? `${value.slice(0, length - 1)}…` : value;
}

function replaceOptions(select, devices) {
	const prior = select.value;
	select.replaceChildren();
	for (const device of devices) {
		const option = document.createElement("option");
		option.value = device.id;
		option.textContent = device.name;
		option.selected = device.selected;
		select.append(option);
	}
	if (!devices.some((device) => device.selected) && prior && devices.some((device) => device.id === prior)) {
		select.value = prior;
	}
}

function renderRoutes(routes) {
	elements.routeTable.replaceChildren();
	if (!routes.length) {
		const empty = document.createElement("div");
		empty.className = "route-empty";
		empty.textContent = "No explicit application policies. Unmatched apps inherit AudioArray Game.";
		elements.routeTable.append(empty);
		return;
	}
	for (const route of routes) {
		const row = document.createElement("div");
		row.className = "route-row";
		const process = document.createElement("strong");
		process.textContent = route.process;
		row.append(process);
		if (route.output) {
			const output = document.createElement("span");
			output.className = "route-chip";
			output.textContent = route.output;
			row.append(output);
		}
		if (route.input) {
			const input = document.createElement("span");
			input.className = "route-chip input";
			input.textContent = route.input.replace("_", " ");
			row.append(input);
		}
		elements.routeTable.append(row);
	}
}

function patchKey(source, destination) {
	return `${source}:${destination}`;
}

function patchWouldLoop(connections, source, destination) {
	if (destination === "monitor") return false;
	const adjacency = new Map();
	for (const patch of connections) {
		if (patch.destination === "monitor") continue;
		if (!adjacency.has(patch.source)) adjacency.set(patch.source, []);
		adjacency.get(patch.source).push(patch.destination);
	}
	const pending = [destination];
	const visited = new Set();
	while (pending.length) {
		const current = pending.pop();
		if (current === source) return true;
		if (visited.has(current)) continue;
		visited.add(current);
		pending.push(...(adjacency.get(current) || []));
	}
	return false;
}

function renderPatchMatrix(snapshot) {
	const active = new Set(snapshot.patches.map((patch) => patchKey(patch.source, patch.destination)));
	elements.patchMatrix.replaceChildren();
	elements.patchMatrix.style.gridTemplateColumns = `minmax(7rem, 1.15fr) repeat(${snapshot.patchDestinations.length}, minmax(5.5rem, 1fr))`;

	const corner = document.createElement("div");
	corner.className = "patch-corner";
	corner.textContent = "SOURCE → TARGET";
	elements.patchMatrix.append(corner);
	for (const destination of snapshot.patchDestinations) {
		const header = document.createElement("div");
		header.className = "patch-header";
		header.textContent = destination.name;
		elements.patchMatrix.append(header);
	}

	for (const source of snapshot.patchSources) {
		const label = document.createElement("div");
		label.className = `patch-source ${source.id.replace("_", "-")}`;
		label.textContent = source.name;
		elements.patchMatrix.append(label);
		for (const destination of snapshot.patchDestinations) {
			const key = patchKey(source.id, destination.id);
			const connected = active.has(key);
			const selfPatch = source.id === destination.id;
			const loop = !connected && !selfPatch && patchWouldLoop(snapshot.patches, source.id, destination.id);
			const button = document.createElement("button");
			button.type = "button";
			button.className = "patch-cell";
			button.dataset.source = source.id;
			button.dataset.destination = destination.id;
			button.setAttribute("aria-pressed", String(connected));
			button.classList.toggle("connected", connected);
			button.classList.toggle("blocked", selfPatch || loop);
			button.disabled = state.applyingPatch || !snapshot.engineOnline || selfPatch || loop;
			button.textContent = connected ? "LINKED" : selfPatch ? "—" : loop ? "LOOP" : "OPEN";
			button.title = connected
				? `Disconnect ${source.name} from ${destination.name}`
				: loop
					? "Blocked because this connection would create feedback"
					: selfPatch
						? "A bus cannot be connected to itself"
						: `Connect ${source.name} to ${destination.name}`;
			elements.patchMatrix.append(button);
		}
	}
}

function crossedPatchPath(patch, index) {
	const sourceY = { game: 159, comms: 223, music: 287, chatgpt: 351, clean_mic: 531 }[patch.source];
	if (!sourceY) return null;
	if (patch.destination === "monitor") {
		return `M684 ${sourceY} H754 Q770 ${sourceY} 770 ${sourceY - 16} V310 Q770 294 786 294 H894 V290`;
	}
	const destinationY = { game: 159, comms: 223, music: 287, chatgpt: 351, clean_mic: 531 }[patch.destination];
	if (!destinationY) return null;
	const laneY = 590 + index * 10;
	const rightX = 730 + index * 5;
	const leftX = 500 - index * 5;
	if (patch.destination === "clean_mic") {
		const entryX = 560 + (index % 4) * 28;
		return `M684 ${sourceY} H${rightX - 12} Q${rightX} ${sourceY} ${rightX} ${sourceY + 12} V${laneY - 12} Q${rightX} ${laneY} ${rightX - 12} ${laneY} H${entryX + 12} Q${entryX} ${laneY} ${entryX} ${laneY - 12} V562`;
	}
	return `M684 ${sourceY} H${rightX - 12} Q${rightX} ${sourceY} ${rightX} ${sourceY + 12} V${laneY - 12} Q${rightX} ${laneY} ${rightX - 12} ${laneY} H${leftX + 12} Q${leftX} ${laneY} ${leftX} ${laneY - 12} V${destinationY + 12} Q${leftX} ${destinationY} ${leftX + 12} ${destinationY} H520`;
}

function renderPatchGraph(patches) {
	const signature = patches
		.map((patch) => patchKey(patch.source, patch.destination))
		.sort()
		.join("|");
	if (state.patchSignature === signature) return;
	state.patchSignature = signature;
	const active = new Set(signature ? signature.split("|") : []);
	for (const path of document.querySelectorAll("#signalGraph [data-patch]")) {
		path.classList.toggle("disconnected", !active.has(path.dataset.patch));
	}
	elements.patchLines.replaceChildren();
	let crossedIndex = 0;
	for (const patch of patches) {
		const key = patchKey(patch.source, patch.destination);
		if (["game:monitor", "comms:monitor", "music:monitor"].includes(key)) continue;
		const geometry = crossedPatchPath(patch, crossedIndex++);
		if (!geometry) continue;
		const path = document.createElementNS(SVG_NAMESPACE, "path");
		path.setAttribute("class", `signal patch ${patch.source === "clean_mic" ? "mic" : patch.source}`);
		path.setAttribute("d", geometry);
		path.dataset.meter = patch.source.replace("_", "-");
		path.dataset.patch = key;
		elements.patchLines.append(path);
	}
	buildWaveformRoutes();
}

async function setPatchConnection(source, destination, enabled) {
	if (!invoke || state.applyingPatch) return;
	state.applyingPatch = true;
	renderPatchMatrix(state.snapshot);
	elements.routingState.textContent = "REPLOTTING PATCH BAY";
	elements.routingState.style.color = "var(--command-gold)";
	try {
		const snapshot = await invoke("set_patch_connection", { source, destination, enabled });
		state.applyingPatch = false;
		renderSnapshot(snapshot);
		playSound("confirm");
		window.setTimeout(() => void refreshSnapshot(), 350);
	} catch (error) {
		state.applyingPatch = false;
		showError(error);
		await refreshSnapshot();
	}
}

function renderSnapshot(snapshot) {
	state.snapshot = snapshot;
	elements.engineStatus.className = `status-cell ${snapshot.engineOnline ? "online" : "offline"}`;
	elements.engineStatus.querySelector("strong").textContent = snapshot.engineOnline ? "ONLINE" : "OFFLINE";
	elements.platformValue.textContent = snapshot.platform.toUpperCase();
	elements.formatValue.textContent = `${snapshot.sampleRate / 1000} KHZ`;
	const sessionName = `${snapshot.sessionOverride || ""} ${snapshot.sessionInputOverride || ""}`.toLowerCase();
	elements.sessionValue.textContent = sessionName.includes("oculus")
		? "QUEST LINK"
		: snapshot.sessionOverride
			? "REMOTE"
			: "LOCAL";
	elements.filterValue.textContent = snapshot.suppressionEnabled
		? `${snapshot.suppression.replace(" (RTX)", "")} ${snapshot.suppressionIntensity}%`
		: "BYPASSED";
	elements.routingState.textContent = snapshot.routingReady ? "ROUTING NOMINAL" : "POLICY TRANSITION";
	elements.routingState.style.color = snapshot.routingReady ? "var(--green-apple)" : "var(--command-gold)";
	elements.mainOutputName.textContent = snapshot.sessionOverride || snapshot.mainOutput?.name || "No physical output available";
	elements.mainInputName.textContent = snapshot.sessionInputOverride || snapshot.mainInput?.name || "No physical input available";
	elements.mainInputPolicy.textContent = snapshot.sessionInputOverride
		? "Quest microphone is the temporary raw source. Your local microphone preference is retained."
		: snapshot.suppressionEnabled
			? `This source feeds ${snapshot.suppression}, then becomes AudioArray Clean Mic.`
			: "This source bypasses suppression and feeds AudioArray Clean Mic unchanged.";
	elements.monitorLatency.textContent = `${snapshot.monitorLatencyMs} MS`;
	elements.micLatency.textContent = `${snapshot.microphoneLatencyMs} MS`;
	elements.graphOutputName.textContent = shorten(snapshot.sessionOverride || snapshot.mainOutput?.name, 21).toUpperCase();
	elements.graphMicName.textContent = shorten(snapshot.sessionInputOverride || snapshot.mainInput?.name, 21).toUpperCase();
	elements.graphSuppressionName.textContent = snapshot.suppressionEnabled
		? snapshot.suppression.toUpperCase()
		: "FILTER BYPASS";
	elements.graphSuppressionMode.textContent = snapshot.suppressionEnabled
		? `${snapshot.suppressionIntensity}% INTENSITY`
		: "RAW SIGNAL";
	elements.suppressionNode.classList.toggle("bypassed", !snapshot.suppressionEnabled);
	replaceOptions(elements.mainOutput, snapshot.outputDevices);
	replaceOptions(elements.mainInput, snapshot.inputDevices);
	const controlsEnabled = snapshot.engineOnline;
	elements.mainOutput.disabled = !controlsEnabled || snapshot.outputDevices.length === 0;
	elements.mainInput.disabled = !controlsEnabled || snapshot.inputDevices.length === 0;
	if (!state.applyingSuppression && !state.editingSuppression) {
		elements.suppressionEnabled.checked = snapshot.suppressionEnabled;
		elements.suppressionEngine.value = snapshot.suppressionEngine;
		elements.suppressionIntensity.value = String(snapshot.suppressionIntensity);
		updateSuppressionReadout();
	}
	elements.suppressionEnabled.disabled = !controlsEnabled || state.applyingSuppression;
	elements.suppressionEngine.disabled = !controlsEnabled || state.applyingSuppression;
	elements.suppressionIntensity.disabled = !controlsEnabled || state.applyingSuppression;
	elements.cleanMicMonitor.checked = state.monitoringCleanMic;
	elements.cleanMicMonitor.disabled = !controlsEnabled || state.applyingCleanMicMonitor;
	elements.suppressionControl.classList.toggle("bypassed", !snapshot.suppressionEnabled);
	elements.suppressionState.textContent = state.applyingSuppression
		? "APPLYING"
		: snapshot.suppressionEnabled
			? "ACTIVE"
			: "BYPASSED";
	renderPatchMatrix(snapshot);
	renderPatchGraph(snapshot.patches);
	renderRoutes(snapshot.routes);
}

function updateSuppressionReadout() {
	const intensity = Number(elements.suppressionIntensity.value);
	const attenuation = intensity * 0.4;
	const usingNvidia = elements.suppressionEngine.value === "nvidia_afx";
	elements.suppressionIntensityValue.textContent = usingNvidia
		? `${intensity}% · RTX RATIO`
		: `${intensity}% · ${attenuation.toFixed(0)} DB`;
}

async function applySuppression() {
	if (!invoke || state.applyingSuppression) return;
	state.editingSuppression = false;
	state.applyingSuppression = true;
	elements.suppressionEnabled.disabled = true;
	elements.suppressionEngine.disabled = true;
	elements.suppressionIntensity.disabled = true;
	elements.suppressionState.textContent = "APPLYING";
	elements.routingState.textContent = "UPDATING CLEAN MIC";
	elements.routingState.style.color = "var(--command-gold)";
	try {
		const snapshot = await invoke("set_noise_suppression", {
			enabled: elements.suppressionEnabled.checked,
			intensity: Number(elements.suppressionIntensity.value),
			engine: elements.suppressionEngine.value
		});
		state.applyingSuppression = false;
		renderSnapshot(snapshot);
		playSound("confirm");
		window.setTimeout(() => void refreshSnapshot(), 900);
	} catch (error) {
		state.applyingSuppression = false;
		showError(error);
		await refreshSnapshot();
	}
}

async function setCleanMicMonitor(enabled) {
	if (!invoke || state.applyingCleanMicMonitor) return;
	state.applyingCleanMicMonitor = true;
	elements.cleanMicMonitor.disabled = true;
	elements.cleanMicMonitorState.textContent = enabled ? "Opening filtered local sidetone…" : "Stopping local sidetone…";
	try {
		const output = await invoke("set_clean_mic_monitor", { enabled });
		state.monitoringCleanMic = Boolean(output);
		elements.cleanMicMonitor.checked = state.monitoringCleanMic;
		elements.cleanMicMonitorState.textContent = output
			? `Monitoring locally through ${shorten(output, 31)} · headphones recommended.`
			: "Local sidetone only · headphones recommended to prevent feedback.";
		playSound("confirm");
	} catch (error) {
		state.monitoringCleanMic = false;
		elements.cleanMicMonitor.checked = false;
		showError(error);
	} finally {
		state.applyingCleanMicMonitor = false;
		elements.cleanMicMonitor.disabled = !state.snapshot?.engineOnline;
	}
}

function buildMeters() {
	elements.meterBank.replaceChildren();
	for (const [id, label] of meterDefinitions) {
		const row = document.createElement("div");
		row.className = "meter-row";
		row.dataset.meter = id;
		const name = document.createElement("span");
		name.textContent = label;
		const segments = document.createElement("div");
		segments.className = "meter-segments";
		for (let index = 0; index < 24; index++) {
			const segment = document.createElement("i");
			if (index >= 19) segment.className = "warn";
			if (index >= 23) segment.className = "clip";
			segments.append(segment);
		}
		const output = document.createElement("output");
		output.textContent = "-∞ dB";
		row.append(name, segments, output);
		elements.meterBank.append(row);
		state.meters.set(id, { row, segments: [...segments.children], output, displayed: -96 });
	}
}

function buildWaveformRoutes() {
	for (const waveform of document.querySelectorAll("#signalGraph .signal.waveform")) waveform.remove();
	state.waveformRoutes.clear();
	const groupedPaths = new Map();
	for (const base of document.querySelectorAll("#signalGraph .signal-lines path.signal[data-meter]:not(.waveform):not(.disconnected)")) {
		const id = base.dataset.meter;
		if (!groupedPaths.has(id)) groupedPaths.set(id, []);
		groupedPaths.get(id).push(base);
	}
	for (const [id, bases] of groupedPaths) {
		const lengths = bases.map((base) => base.getTotalLength());
		let elapsed = 0;
		const routes = [];
		bases.forEach((base, routeIndex) => {
			const length = lengths[routeIndex];
			const pointCount = Math.max(24, Math.min(192, Math.round(length * 0.8)));
			const geometry = [];
			for (let index = 0; index < pointCount; index++) {
				const distance = pointCount === 1 ? 0 : (index / (pointCount - 1)) * length;
				const point = base.getPointAtLength(distance);
				const before = base.getPointAtLength(Math.max(0, distance - 0.75));
				const after = base.getPointAtLength(Math.min(length, distance + 0.75));
				const dx = after.x - before.x;
				const dy = after.y - before.y;
				const magnitude = Math.hypot(dx, dy) || 1;
				geometry.push({
					x: point.x,
					y: point.y,
					nx: -dy / magnitude,
					ny: dx / magnitude,
					distance: elapsed + distance
				});
			}
			const waveform = document.createElementNS(SVG_NAMESPACE, "path");
			waveform.setAttribute("class", `${base.getAttribute("class")} waveform`);
			if (base.dataset.patch) waveform.dataset.patch = base.dataset.patch;
			waveform.setAttribute("aria-hidden", "true");
			base.after(waveform);
			routes.push({ waveform, geometry });
			elapsed += length;
		});
		state.waveformRoutes.set(id, routes);
	}
}

function renderWaveform(reading) {
	const routes = state.waveformRoutes.get(reading.id);
	if (!routes?.length || !reading.waveform?.length) return;
	const activity = reading.waveform.reduce((peak, sample) => Math.max(peak, Math.abs(sample)), 0);
	for (const route of routes) {
		if (route.waveform.classList.contains("disconnected")) {
			route.waveform.style.opacity = "0";
			continue;
		}
		const points = route.geometry.map((point) => {
			// A crossed wire can be longer than the finite telemetry window. Cycle
			// through that live window instead of clamping to its final sample, which
			// would turn the remainder of a long route into a straight line.
			const unwrappedPosition = point.distance / WAVEFORM_PIXELS_PER_SAMPLE;
			const lowerPosition = Math.floor(unwrappedPosition);
			const lowerIndex = lowerPosition % reading.waveform.length;
			const upperIndex = (lowerIndex + 1) % reading.waveform.length;
			const blend = unwrappedPosition - lowerPosition;
			const interpolated = reading.waveform[lowerIndex] * (1 - blend) + reading.waveform[upperIndex] * blend;
			const sample = Math.max(-1, Math.min(1, interpolated));
			// Audio amplitude is logarithmic in practice. Cube-root display scaling
			// preserves the captured waveform while giving ordinary signal detail an
			// intentionally pronounced oscilloscope-like presentation.
			const offset = Math.sign(sample) * Math.cbrt(Math.abs(sample)) * WAVEFORM_MAX_OFFSET;
			return `${(point.x + point.nx * offset).toFixed(2)} ${(point.y + point.ny * offset).toFixed(2)}`;
		});
		route.waveform.setAttribute("d", points.map((point, index) => `${index ? "L" : "M"}${point}`).join(" "));
		route.waveform.style.opacity = activity < 0.002 ? "0" : String(Math.min(1, 0.92 + activity));
	}
}

function renderMeters(readings) {
	for (const reading of readings) {
		renderWaveform(reading);
		const meter = state.meters.get(reading.id);
		if (!meter) continue;
		meter.displayed = Math.max(reading.dbfs, meter.displayed - 4.5);
		const normalized = Math.max(0, Math.min(1, (meter.displayed + 60) / 60));
		const active = Math.round(normalized * meter.segments.length);
		meter.segments.forEach((segment, index) => segment.classList.toggle("active", index < active));
		meter.output.textContent = meter.displayed <= -95 ? "-∞ dB" : `${meter.displayed.toFixed(1)} dB`;
	}
}

async function refreshSnapshot({ sound = false } = {}) {
	if (state.refreshing || !invoke) return;
	state.refreshing = true;
	if (sound) playSound("search");
	try {
		const snapshot = await invoke("graph_snapshot");
		renderSnapshot(snapshot);
		clearError();
	} catch (error) {
		showError(error);
	} finally {
		state.refreshing = false;
	}
}

async function pollMeters() {
	if (!invoke || document.hidden || !state.snapshot?.engineOnline || state.pollingMeters) return;
	state.pollingMeters = true;
	try {
		renderMeters(await invoke("meter_snapshot"));
	} catch (error) {
		console.warn("AudioArray meter polling failed", error);
	} finally {
		state.pollingMeters = false;
	}
}

async function chooseEndpoint(command, select, display) {
	const endpointId = select.value;
	const endpointName = select.selectedOptions[0]?.textContent || "selected endpoint";
	select.disabled = true;
	display.textContent = `Routing to ${endpointName}…`;
	elements.routingState.textContent = "APPLYING ENDPOINT";
	elements.routingState.style.color = "var(--command-gold)";
	try {
		if (command === "select_main_output" && state.monitoringCleanMic) {
			await setCleanMicMonitor(false);
		}
		await invoke(command, { endpointId });
		playSound("confirm");
		window.setTimeout(() => void refreshSnapshot(), 1100);
	} catch (error) {
		showError(error);
		await refreshSnapshot();
	}
}

document.addEventListener("pointerdown", unlockAudio, { capture: true });
document.addEventListener("click", (event) => {
	const control = event.target instanceof Element ? event.target.closest("button, a") : null;
	if (!control || control === elements.audioToggle || control.dataset.sound === "search") return;
	playSound(control.dataset.sound || "key");
});

elements.audioToggle.addEventListener("click", () => {
	state.muted = !state.muted;
	localStorage.setItem(AUDIO_STORAGE_KEY, state.muted ? "1" : "0");
	if (!state.muted) {
		state.audioUnlocked = true;
		updateAudioUi();
		playSound("confirm");
	} else {
		for (const voice of Object.values(voices).flat()) voice.pause();
		updateAudioUi();
	}
});

elements.refreshButton.addEventListener("click", () => void refreshSnapshot({ sound: true }));
elements.mainOutput.addEventListener("change", () =>
	void chooseEndpoint("select_main_output", elements.mainOutput, elements.mainOutputName)
);
elements.mainInput.addEventListener("change", () =>
	void chooseEndpoint("select_main_input", elements.mainInput, elements.mainInputName)
);
elements.suppressionEnabled.addEventListener("change", () => void applySuppression());
elements.suppressionEngine.addEventListener("change", () => void applySuppression());
elements.suppressionIntensity.addEventListener("pointerdown", () => {
	state.editingSuppression = true;
});
elements.suppressionIntensity.addEventListener("input", () => {
	state.editingSuppression = true;
	updateSuppressionReadout();
});
elements.suppressionIntensity.addEventListener("change", () => void applySuppression());
elements.suppressionIntensity.addEventListener("blur", () => {
	if (!state.editingSuppression || state.applyingSuppression) return;
	state.editingSuppression = false;
	void refreshSnapshot();
});
elements.cleanMicMonitor.addEventListener("change", () =>
	void setCleanMicMonitor(elements.cleanMicMonitor.checked)
);
elements.patchMatrix.addEventListener("click", (event) => {
	const button = event.target instanceof Element ? event.target.closest("button.patch-cell") : null;
	if (!button || button.disabled) return;
	void setPatchConnection(button.dataset.source, button.dataset.destination, button.getAttribute("aria-pressed") !== "true");
});
document.addEventListener("visibilitychange", () => {
	if (document.hidden && state.monitoringCleanMic) void setCleanMicMonitor(false);
});

buildMeters();
buildWaveformRoutes();
updateAudioUi();
if (!invoke) {
	showError("Tauri bridge unavailable. Launch the native AudioArray application instead of opening index.html directly.");
} else {
	void refreshSnapshot();
	window.setInterval(() => void refreshSnapshot(), 2000);
	window.setInterval(() => void pollMeters(), 33);
}
