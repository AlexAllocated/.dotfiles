import React, {
	createContext,
	memo,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState
} from "react";
import { createRoot } from "react-dom/client";
import {
	ReactFlow,
	ReactFlowProvider,
	Background,
	Controls,
	Handle,
	Position,
	BaseEdge,
	getSmoothStepPath,
	MarkerType,
	applyNodeChanges,
	useReactFlow
} from "@xyflow/react";
import ELK from "elkjs/lib/elk-api.js";
import workerUrl from "elkjs/lib/elk-worker.min.js?url";
import "@xyflow/react/dist/style.css";
import "./style.css";
import { colors, key, validateConnection, trace, waveformPoints, loadLayout } from "./graph.mjs";
import type { GraphNode, GraphEdge, Snapshot, Meter } from "./model";

declare global {
	interface Window {
		__TAURI__?: { core: { invoke: (cmd: string, args?: any) => Promise<any> } };
		__AMPS_TEST__?: { invoke: (cmd: string, args?: any) => Promise<any> };
	}
}
const invoke = window.__TAURI__?.core.invoke ?? window.__AMPS_TEST__?.invoke;
const elk = new ELK({ workerUrl });
const meters = new Map<string, Meter>();
const subscribers = new Set<() => void>();
const MeterContext = createContext(0);
function useMeter(id?: string) {
	useContext(MeterContext);
	return id ? meters.get(id) : null;
}
function Peak({ id }: { id?: string }) {
	const m = useMeter(id);
	const db = m?.dbfs;
	const percent =
		typeof db === "number" && Number.isFinite(db) ?
			Math.max(0, Math.min(100, ((db + 60) / 60) * 100))
		:	0;
	return (
		<div
			className="peak"
			aria-label={`${id ?? "Signal"} level ${db?.toFixed?.(1) ?? "unavailable"} decibels`}
		>
			<span style={{ width: `${percent}%` }} />
			<small>{percent ? `${db.toFixed(1)} dB` : "—"}</small>
		</div>
	);
}
const SignalNode = memo(function SignalNode({ data, selected }: any) {
	const n: GraphNode = data.node;
	return (
		<article
			className={`signal-node ${selected ? "chosen" : ""} ${n.kind}`}
			style={
				{
					"--signal": colors[n.id] ?? (n.kind === "processor" ? "#ffbb33" : "#828cad")
				} as React.CSSProperties
			}
		>
			<header className="node-drag">
				<small>{n.kind.toUpperCase()}</small>
				<h3>{n.title}</h3>
			</header>
			<p>{n.detail}</p>
			{n.effect && (
				<div
					className="attachment"
					title="This Windows endpoint effect cannot be moved to another wire"
				>
					🔒 {n.effect}
				</div>
			)}
			<div className="ports">
				<div>
					{n.inputs.map((p, i) => (
						<div
							className="port-label input"
							key={p.id}
						>
							<Handle
								type="target"
								id={p.id}
								position={Position.Left}
								isConnectable={p.editable && !data.busy}
								style={{ top: `${data.portStart + i * 28}px` }}
								aria-label={`${n.title}: ${p.label}`}
							/>
							<span>
								{p.editable ? "●" : "◇"} {p.label}
							</span>
						</div>
					))}
				</div>
				<div>
					{n.outputs.map((p, i) => (
						<div
							className="port-label output"
							key={p.id}
						>
							<span>
								{p.label} {p.editable ? "●" : "◇"}
							</span>
							<Handle
								type="source"
								id={p.id}
								position={Position.Right}
								isConnectable={p.editable && !data.busy}
								style={{ top: `${data.portStart + i * 28}px` }}
								aria-label={`${n.title}: ${p.label}`}
							/>
						</div>
					))}
				</div>
			</div>
			{n.meter && <Peak id={n.meter} />}
		</article>
	);
});

const SignalEdge = memo(function SignalEdge(props: any) {
	const {
		data,
		id,
		sourceX,
		sourceY,
		targetX,
		targetY,
		sourcePosition,
		targetPosition,
		markerEnd
	} = props;
	const [path] = getSmoothStepPath({
		sourceX,
		sourceY,
		targetX,
		targetY,
		sourcePosition,
		targetPosition,
		borderRadius: 18,
		centerX:
			sourceX < targetX - 90 ? sourceX + 34 + (targetX - sourceX - 68) * data.lane : undefined,
		offset: 32
	});
	const base = useRef<SVGPathElement>(null),
		wave = useRef<SVGPathElement>(null),
		geometry = useRef<any[]>([]);
	useEffect(() => {
		if (!base.current) return;
		const p = base.current,
			total = p.getTotalLength(),
			points = [];
		for (let d = 0; d <= total; d += 4) {
			const point = p.getPointAtLength(d),
				prev = p.getPointAtLength(Math.max(0, d - 1)),
				next = p.getPointAtLength(Math.min(total, d + 1)),
				length = Math.hypot(next.x - prev.x, next.y - prev.y) || 1;
			points.push({
				x: point.x,
				y: point.y,
				nx: -(next.y - prev.y) / length,
				ny: (next.x - prev.x) / length,
				distance: d
			});
		}
		geometry.current = points;
	}, [path]);
	useEffect(() => {
		const render = () => {
			const m = meters.get(data.edge.meter);
			if (wave.current)
				wave.current.setAttribute(
					"d",
					data.online && !data.reducedMotion && m ?
						waveformPoints(geometry.current, m.waveform, m.peak)
					:	""
				);
		};
		subscribers.add(render);
		render();
		return () => {
			subscribers.delete(render);
		};
	}, [data.edge.meter, data.online, data.reducedMotion]);
	const color =
		colors[data.edge.source] ??
		(data.edge.source === "noise_filter" ? colors.clean_mic : "#828cad");
	return (
		<g className={`wire ${data.traced ? "" : "dimmed"}`}>
			<BaseEdge
				id={id}
				path={path}
				markerEnd={markerEnd}
				interactionWidth={24}
				style={{
					stroke: color,
					strokeWidth: props.selected ? 3 : 1.8,
					strokeDasharray: data.online ? undefined : "3 5"
				}}
			/>
			<path
				ref={base}
				d={path}
				fill="none"
				stroke="none"
			/>
			<path
				ref={wave}
				className="wave"
				fill="none"
				stroke={color}
				strokeWidth={2.5}
				pointerEvents="none"
			/>
			{props.selected && <title>{data.edge.label}</title>}
		</g>
	);
});
const nodeTypes = { signal: SignalNode },
	edgeTypes = { signal: SignalEdge };

function Console() {
	const [snapshot, setSnapshot] = useState<Snapshot | null>(null),
		[nodes, setNodes] = useState<any[]>([]),
		[selection, setSelection] = useState<string | null>(null),
		[edgeSelection, setEdgeSelection] = useState<string | null>(null);
	const [busy, setBusy] = useState(false),
		[message, setMessage] = useState("Connecting to engine…"),
		[error, setError] = useState(""),
		[tick, setTick] = useState(0);
	const [source, setSource] = useState("clean_mic"),
		[target, setTarget] = useState("comms_send"),
		[monitoring, setMonitoring] = useState(false);
	const [muted, setMuted] = useState(localStorage.getItem("audioarray:lcars-audio-muted") === "1"),
		[reducedMotion, setReducedMotion] = useState(
			matchMedia("(prefers-reduced-motion: reduce)").matches
		);
	const [noise, setNoise] = useState({ enabled: true, intensity: 50, engine: "nvidia_afx" }),
		[noiseDirty, setNoiseDirty] = useState(false),
		[devicePending, setDevicePending] = useState<string | null>(null);
	const flow = useReactFlow(),
		reconnecting = useRef<GraphEdge | null>(null),
		snapshotRef = useRef<Snapshot | null>(null),
		busyRef = useRef(false),
		positions = useRef(loadLayout(localStorage)?.positions ?? {}),
		lastTopology = useRef("");
	const refresh = useCallback(async () => {
		if (!invoke) return;
		const next: Snapshot = await invoke("routing_snapshot");
		snapshotRef.current = next;
		setSnapshot(next);
		return next;
	}, []);
	const sound = useCallback(
		(name: string) => {
			if (muted) return;
			const audio = new Audio(`./audio/${name}.mp3`);
			audio.volume = 0.2;
			void audio.play().catch(() => {});
		},
		[muted]
	);
	useEffect(() => {
		const listener = () =>
			setReducedMotion(matchMedia("(prefers-reduced-motion: reduce)").matches);
		const media = matchMedia("(prefers-reduced-motion: reduce)");
		media.addEventListener("change", listener);
		return () => media.removeEventListener("change", listener);
	}, []);
	useEffect(() => {
		let active = true,
			inflight = false;
		const poll = async () => {
			if (inflight || document.hidden) return;
			inflight = true;
			try {
				const data = await refresh();
				if (active && data)
					setMessage(
						data.runtime?.online ? "Engine connected" : "Engine offline / waiting for devices"
					);
			} catch (e) {
				if (active) setError(String(e));
			} finally {
				inflight = false;
			}
		};
		void poll();
		const timer = setInterval(poll, 1500);
		document.addEventListener("visibilitychange", poll);
		return () => {
			active = false;
			clearInterval(timer);
			document.removeEventListener("visibilitychange", poll);
		};
	}, [refresh]);
	useEffect(() => {
		if (!invoke) {
			setError("No native AMPS bridge. This page cannot change routing.");
			return;
		}
		let active = true,
			inflight = false;
		const timer = setInterval(async () => {
			if (document.hidden || inflight) return;
			inflight = true;
			try {
				const values: Meter[] = await invoke("meter_snapshot");
				if (!active) return;
				meters.clear();
				for (const value of values) meters.set(value.id, value);
				for (const notify of subscribers) notify();
				setTick(n => (n + 1) % 100000);
			} catch {
			} finally {
				inflight = false;
			}
		}, 50);
		return () => {
			active = false;
			clearInterval(timer);
		};
	}, []);
	useEffect(() => {
		if (!snapshot?.runtime || noiseDirty || busy) return;
		const n = snapshot.runtime.suppression;
		setNoise({
			enabled: n.enabled,
			intensity: Math.round((n.attenuation_limit_db / 40) * 100),
			engine: n.engine
		});
	}, [snapshot?.runtime?.revision, noiseDirty, busy]);
	const online = !!snapshot?.runtime?.online && snapshot.runtime.appliedRevision !== null;
	const layout = useCallback(
		async (topology: Snapshot["topology"], reset = false) => {
			const children = topology.nodes.map(n => ({
				id: n.id,
				width: 260,
				height: n.effect ? 224 : 190,
				layoutOptions: { "elk.portConstraints": "FIXED_SIDE" },
				ports: [
					...n.inputs.map(p => ({
						id: `${n.id}:${p.id}:in`,
						width: 12,
						height: 12,
						layoutOptions: { "elk.port.side": "WEST" }
					})),
					...n.outputs.map(p => ({
						id: `${n.id}:${p.id}:out`,
						width: 12,
						height: 12,
						layoutOptions: { "elk.port.side": "EAST" }
					}))
				]
			}));
			const result = await elk.layout({
				id: "audio",
				layoutOptions: {
					"elk.algorithm": "layered",
					"elk.direction": "RIGHT",
					"elk.spacing.nodeNode": "54",
					"elk.layered.spacing.nodeNodeBetweenLayers": "180",
					"elk.edgeRouting": "ORTHOGONAL"
				},
				children,
				edges: topology.edges.map(e => ({
					id: e.id,
					sources: [`${e.source}:${e.sourceHandle}:out`],
					targets: [`${e.target}:${e.targetHandle}:in`]
				}))
			});
			setNodes(
				topology.nodes.map(n => {
					const spot = result.children.find(c => c.id === n.id);
					const position =
						!reset && positions.current[n.id] ?
							positions.current[n.id]
						:	{ x: spot.x, y: spot.y };
					positions.current[n.id] = position;
					return {
						id: n.id,
						type: "signal",
						position,
						dragHandle: ".node-drag",
						data: { node: n, busy: busyRef.current, portStart: n.effect ? 170 : 138 },
						ariaLabel: `${n.title}, ${n.detail}`
					};
				})
			);
			localStorage.setItem(
				"audioarray:layout:v1",
				JSON.stringify({ version: 1, positions: positions.current })
			);
			setTimeout(
				() => flow.fitView({ padding: 0.08, maxZoom: 1, duration: reducedMotion ? 0 : 200 }),
				80
			);
		},
		[flow, reducedMotion]
	);
	useEffect(() => {
		if (!snapshot) return;
		const signature = JSON.stringify(snapshot.topology.nodes.map(n => n.id));
		if (signature !== lastTopology.current) {
			lastTopology.current = signature;
			void layout(snapshot.topology).catch(e => setError(`Layout: ${e}`));
		} else {
			setNodes(current =>
				current.map(n => ({
					...n,
					data: { ...n.data, node: snapshot.topology.nodes.find(x => x.id === n.id), busy }
				}))
			);
		}
	}, [snapshot, layout, busy]);
	const transact = useCallback(
		async (edit: any) => {
			if (busyRef.current) return;
			const current = snapshotRef.current?.runtime;
			if (!current?.online) return;
			busyRef.current = true;
			setBusy(true);
			setError("");
			setMessage("Validating and applying…");
			try {
				const reply = await invoke("edit_routing", {
					request: {
						id: crypto.randomUUID(),
						session: current.session,
						expectedRevision: current.revision,
						edit
					}
				});
				await refresh();
				if (!reply.applied) throw new Error(reply.error ?? "The engine rejected this edit");
				if (["suppression", "undo", "redo"].includes(edit.kind)) setNoiseDirty(false);
				setMessage(`Applied and saved · revision ${reply.revision}`);
				sound("confirm");
			} catch (e) {
				setError(String(e));
				setMessage("Edit not confirmed — current engine state retained");
				sound("denied");
				await refresh().catch(() => {});
			} finally {
				busyRef.current = false;
				setBusy(false);
			}
		},
		[refresh, sound]
	);
	const connect = useCallback(
		(connection: any, replacing?: GraphEdge) => {
			const s = snapshotRef.current;
			if (!s) return;
			const issue = validateConnection(
				s.topology,
				s.runtime?.patches ?? s.graph.patches,
				connection,
				replacing ? key(replacing.source, replacing.target) : undefined
			);
			if (issue) {
				setError(issue);
				sound("denied");
				return;
			}
			void transact(
				replacing ?
					{
						kind: "replace",
						old: { source: replacing.source, destination: replacing.target },
						new: { source: connection.source, destination: connection.target }
					}
				:	{ kind: "connect", source: connection.source, destination: connection.target }
			);
		},
		[transact, sound]
	);
	const selected = snapshot?.topology.nodes.find(n => n.id === selection),
		selectedEdge = snapshot?.topology.edges.find(e => e.id === edgeSelection);
	const highlighted = useMemo(
		() => (snapshot ? trace(snapshot.topology, selection) : new Set()),
		[snapshot?.topology, selection]
	);
	const edges = useMemo(
		() =>
			snapshot?.topology.edges.map((e, index, all) => ({
				...e,
				selected: e.id === edgeSelection,
				type: "signal",
				reconnectable: e.kind === "patch" && online && !busy,
				selectable: true,
				deletable: false,
				markerEnd: {
					type: MarkerType.ArrowClosed,
					color: colors[e.source] ?? "#a5aec9",
					width: 18,
					height: 18
				},
				data: {
					edge: e,
					lane: (index + 1) / (all.length + 1),
					traced: edgeSelection ? e.id === edgeSelection : highlighted.has(e.id),
					online,
					reducedMotion
				},
				ariaLabel: `${e.source} to ${e.target}: ${e.kind === "patch" ? "editable audio route" : e.label}`
			})) ?? [],
		[snapshot?.topology, highlighted, edgeSelection, online, busy, reducedMotion]
	);
	const remove = useCallback(() => {
		if (selectedEdge?.kind === "patch")
			void transact({
				kind: "disconnect",
				source: selectedEdge.source,
				destination: selectedEdge.target
			});
	}, [selectedEdge, transact]);
	useEffect(() => {
		const keyboard = (e: KeyboardEvent) => {
			if ((e.target as HTMLElement)?.closest("input,select,textarea")) return;
			if (e.ctrlKey && e.key.toLowerCase() === "z") {
				e.preventDefault();
				void transact({ kind: e.shiftKey ? "redo" : "undo" });
			}
			if (e.key === "Delete" || e.key === "Backspace") {
				if (selectedEdge?.kind === "patch") {
					e.preventDefault();
					remove();
				}
			}
		};
		window.addEventListener("keydown", keyboard);
		return () => window.removeEventListener("keydown", keyboard);
	}, [transact, selectedEdge, remove]);
	const device = async (direction: "input" | "output", id: string) => {
		setDevicePending(direction);
		setError("");
		try {
			await invoke(direction === "input" ? "select_main_input" : "select_main_output", {
				endpointId: id
			});
			setMessage("Device preference sent; waiting for active binding…");
			await refresh();
			sound("confirm");
		} catch (e) {
			setError(String(e));
		} finally {
			setDevicePending(null);
		}
	};
	const inputOptions = snapshot?.graph.inputDevices ?? [],
		outputOptions = snapshot?.graph.outputDevices ?? [];
	const deviceValue = (direction: string) => {
		const options = direction === "input" ? inputOptions : outputOptions,
			actual =
				direction === "input" ? snapshot?.runtime?.inputName : snapshot?.runtime?.outputName;
		return options.find(p => p.name === actual)?.id ?? "";
	};
	return (
		<MeterContext.Provider value={tick}>
			<div className="console">
				<header className="masthead">
					<div className="registry">
						<strong>47</strong>
						<span>AUDIO OPERATIONS</span>
					</div>
					<div className="identity">
						<small>INTREPID-CLASS / SIGNAL SYSTEMS</small>
						<h1>Audio Mixing and Processing Subsystem</h1>
					</div>
					<div className="connection-state">
						<span className={`status-dot ${online ? "online" : ""}`} />
						{online ? "AMPS ONLINE" : "AMPS OFFLINE"}
						<small>
							{snapshot?.runtime ?
								`REV ${snapshot.runtime.revision} · ${snapshot.runtime.appliedRevision === snapshot.runtime.revision ? "ROUTES APPLIED" : "NOT APPLIED"}`
							:	"AWAITING ENGINE"}
						</small>
					</div>
					<div
						className="header-stripe"
						aria-hidden="true"
					>
						<i />
						<i />
						<i />
						<i />
					</div>
				</header>
				<nav
					className="toolbar"
					aria-label="Graph actions"
				>
					<span className="section-name">01 / ROUTING</span>
					<button onClick={() => flow.fitView({ padding: 0.08, maxZoom: 1 })}>
						Fit graph
					</button>
					<button onClick={() => snapshot && void layout(snapshot.topology, true)}>
						Arrange
					</button>
					<button
						disabled={!selection}
						onClick={() =>
							flow.fitView({
								nodes: [{ id: selection }],
								padding: 0.6,
								minZoom: 0.75,
								maxZoom: 1
							})
						}
					>
						Focus node
					</button>
					<button
						disabled={!online || busy || !snapshot?.runtime?.canUndo}
						onClick={() => void transact({ kind: "undo" })}
					>
						Undo
					</button>
					<button
						disabled={!online || busy || !snapshot?.runtime?.canRedo}
						onClick={() => void transact({ kind: "redo" })}
					>
						Redo
					</button>
					<button
						aria-pressed={muted}
						onClick={() => {
							setMuted(!muted);
							localStorage.setItem("audioarray:lcars-audio-muted", !muted ? "1" : "0");
						}}
					>
						Sounds {muted ? "off" : "on"}
					</button>
					<span className="toolbar-hint">
						Drag ports to connect · select a node to inspect
					</span>
				</nav>
				<div className="workspace">
					<main
						className="canvas"
						aria-label="Audio routing canvas"
					>
						<ReactFlow
							nodes={nodes}
							edges={edges}
							nodeTypes={nodeTypes}
							edgeTypes={edgeTypes}
							onNodesChange={changes => setNodes(n => applyNodeChanges(changes, n))}
							onNodeDragStop={(_e, n) => {
								positions.current[n.id] = n.position;
								localStorage.setItem(
									"audioarray:layout:v1",
									JSON.stringify({ version: 1, positions: positions.current })
								);
							}}
							onNodeClick={(_e, n) => {
								setSelection(n.id);
								setEdgeSelection(null);
								sound("intrepid-key");
							}}
							onEdgeClick={(_e, e) => {
								setEdgeSelection(e.id);
								setSelection(null);
							}}
							onPaneClick={() => {
								setSelection(null);
								setEdgeSelection(null);
							}}
							onConnect={c => connect(c)}
							onReconnect={(e, c) => connect(c, e.data.edge as GraphEdge)}
							onReconnectStart={(_event, edge) => {
								reconnecting.current = edge.data.edge as GraphEdge;
							}}
							onReconnectEnd={() => {
								reconnecting.current = null;
							}}
							isValidConnection={c =>
								!!snapshot &&
								online &&
								!busy &&
								!validateConnection(
									snapshot.topology,
									snapshot.runtime?.patches ?? [],
									c,
									reconnecting.current ?
										key(reconnecting.current.source, reconnecting.current.target)
									:	undefined
								)
							}
							deleteKeyCode={null}
							minZoom={0.18}
							maxZoom={1.7}
							nodesConnectable={online && !busy}
							nodesFocusable
							edgesFocusable
							connectionRadius={28}
							proOptions={{ hideAttribution: false }}
						>
							<Background
								color="#293a42"
								gap={28}
							/>
							<Controls showInteractive={false} />
						</ReactFlow>
						<div className="canvas-legend">
							<span>● Editable PCM</span>
							<span>◇ Fixed pipeline</span>
							<span>→ Signal direction</span>
						</div>
					</main>
					<aside
						className="inspector"
						aria-label="Selected audio node"
					>
						<div className="inspector-heading">
							<small>02 / INSPECT</small>
							<h2>{selected?.title ?? (selectedEdge ? "Connection" : "Signal controls")}</h2>
						</div>
						{selected && (
							<>
								<p className="description">{selected.detail}</p>
								{selected.effect && (
									<p className="notice">
										{selected.effect}. Attached to this endpoint; not a movable DSP
										insert.
									</p>
								)}
								{selected.meter && <Peak id={selected.meter} />}
							</>
						)}
						{selectedEdge && (
							<section>
								<p>
									<strong>
										{
											snapshot.topology.nodes.find(n => n.id === selectedEdge.source)
												?.title
										}
									</strong>{" "}
									→{" "}
									<strong>
										{
											snapshot.topology.nodes.find(n => n.id === selectedEdge.target)
												?.title
										}
									</strong>
								</p>
								<p>{selectedEdge.label}</p>
								{selectedEdge.kind === "patch" ?
									<button
										className="danger"
										disabled={busy || !online}
										onClick={remove}
									>
										Disconnect route
									</button>
								:	<p className="notice">
										This connection is part of AMPS's fixed processing or device pipeline.
										It cannot be rewired here.
									</p>
								}
							</section>
						)}
						{(!selection ||
							["monitor", "main_output", "physical_mic"].includes(selection)) && (
							<section>
								<h3>Device bindings</h3>
								<label>
									Main Output
									<select
										aria-label="Main Output"
										disabled={!!devicePending}
										value={deviceValue("output")}
										onChange={e => void device("output", e.target.value)}
									>
										<option
											value=""
											disabled
										>
											Waiting for active device…
										</option>
										{outputOptions.map(d => (
											<option
												value={d.id}
												key={d.id}
											>
												{d.name}
											</option>
										))}
									</select>
								</label>
								<p className="binding">
									Active: {snapshot?.runtime?.outputName ?? "Unknown"}
								</p>
								<label>
									Main Input
									<select
										aria-label="Main Input"
										disabled={!!devicePending}
										value={deviceValue("input")}
										onChange={e => void device("input", e.target.value)}
									>
										<option
											value=""
											disabled
										>
											Waiting for active device…
										</option>
										{inputOptions.map(d => (
											<option
												value={d.id}
												key={d.id}
											>
												{d.name}
											</option>
										))}
									</select>
								</label>
								<p className="binding">
									Active: {snapshot?.runtime?.inputName ?? "Unknown"}
								</p>
								{snapshot?.graph.sessionOverride && (
									<p className="notice">
										Session override: {snapshot.graph.sessionOverride}
									</p>
								)}
								<p className="hint">
									Windows device selection uses the same history. Master volume affects
									listening, not OBS stems.
								</p>
							</section>
						)}
						{["noise_filter", "clean_mic", "physical_mic"].includes(selection) && (
							<section>
								<h3>Microphone processing</h3>
								<p className="binding">Observed: {snapshot?.graph.suppression}</p>
								<label className="check">
									<input
										type="checkbox"
										checked={noise.enabled}
										disabled={busy || !online}
										onChange={e => {
											setNoise(n => ({ ...n, enabled: e.target.checked }));
											setNoiseDirty(true);
										}}
									/>
									Noise suppression
								</label>
								<label>
									Processor
									<select
										value={noise.engine}
										disabled={busy || !online}
										onChange={e => {
											setNoise(n => ({ ...n, engine: e.target.value }));
											setNoiseDirty(true);
										}}
									>
										<option value="nvidia_afx">NVIDIA AFX (RTX)</option>
										<option value="deepfilternet3">DeepFilterNet3 (CPU)</option>
									</select>
								</label>
								<label>
									Intensity <output>{noise.intensity}%</output>
									<input
										type="range"
										min={0}
										max={100}
										value={noise.intensity}
										disabled={busy || !online}
										onChange={e => {
											setNoise(n => ({ ...n, intensity: +e.target.value }));
											setNoiseDirty(true);
										}}
									/>
								</label>
								<button
									disabled={!noiseDirty || busy || !online}
									onClick={() => void transact({ kind: "suppression", ...noise })}
								>
									Apply filter settings
								</button>
								<button
									aria-pressed={monitoring}
									disabled={!online}
									onClick={async () => {
										try {
											await invoke("set_clean_mic_monitor", { enabled: !monitoring });
											setMonitoring(!monitoring);
										} catch (e) {
											setError(String(e));
										}
									}}
								>
									{monitoring ? "Stop mic monitor" : "Listen to Clean Mic"}
								</button>
								<p className="hint">
									Fixed mic-only stage. RTX model changes may briefly interrupt the mic,
									never the playback buses.
								</p>
							</section>
						)}
						{selected && (
							<section>
								<h3>Direct contributors</h3>
								<ul>
									{snapshot.topology.edges
										.filter(e => e.target === selection)
										.map(e => (
											<li key={e.id}>
												<button
													className="text-button"
													onClick={() => {
														setSelection(null);
														setEdgeSelection(e.id);
													}}
												>
													{snapshot.topology.nodes.find(n => n.id === e.source)?.title}{" "}
													<small>{e.kind === "patch" ? "unity" : e.kind}</small>
												</button>
											</li>
										))}
								</ul>
								{!snapshot.topology.edges.some(e => e.target === selection) && (
									<p className="hint">Source endpoint. No incoming patch routes.</p>
								)}
							</section>
						)}
						<section className="connect-panel">
							<h3>Connect ports</h3>
							<p className="hint">Keyboard and touch alternative to dragging.</p>
							<label>
								Source
								<select
									aria-label="Connection source"
									value={source}
									onChange={e => setSource(e.target.value)}
								>
									{snapshot?.topology.nodes
										.filter(n => n.outputs.some(p => p.editable))
										.map(n => (
											<option
												key={n.id}
												value={n.id}
											>
												{n.title}
											</option>
										))}
								</select>
							</label>
							<label>
								Destination
								<select
									aria-label="Connection destination"
									value={target}
									onChange={e => setTarget(e.target.value)}
								>
									{snapshot?.topology.nodes
										.filter(n => n.inputs.some(p => p.editable))
										.map(n => (
											<option
												key={n.id}
												value={n.id}
											>
												{n.title}
											</option>
										))}
								</select>
							</label>
							<button
								disabled={!online || busy}
								onClick={() =>
									connect({ source, target, sourceHandle: "out", targetHandle: "in" })
								}
							>
								Connect
							</button>
						</section>
						{selected &&
							snapshot?.graph.routes.filter(
								r => r.output === selection || r.input === selection
							).length > 0 && (
								<section>
									<h3>Application preferences</h3>
									<ul>
										{snapshot.graph.routes
											.filter(r => r.output === selection || r.input === selection)
											.map(r => (
												<li key={r.process}>{r.process}</li>
											))}
									</ul>
									<p className="hint">
										Explicit in-app selection can override these preferences.
									</p>
								</section>
							)}
					</aside>
				</div>
				<footer>
					<span
						role="status"
						aria-live="polite"
					>
						{busy ? "APPLYING…" : message}
					</span>
					<span>PCM ROUTING / PROTECTED CONVERSATION SENDS</span>
				</footer>
				{(error || snapshot?.runtime?.error) && (
					<div
						className="error"
						role="alert"
					>
						<span>{error || snapshot.runtime.error}</span>
						<button
							onClick={() => {
								setError("");
								void refresh();
							}}
						>
							Refresh state
						</button>
					</div>
				)}
			</div>
		</MeterContext.Provider>
	);
}
createRoot(document.getElementById("root")!).render(
	<ReactFlowProvider>
		<Console />
	</ReactFlowProvider>
);
