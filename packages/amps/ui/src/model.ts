export type Port = {
	id: string;
	label: string;
	direction: "input" | "output";
	editable: boolean;
	signal: string;
	fanIn: boolean;
};
export type GraphNode = {
	id: string;
	title: string;
	kind: string;
	detail: string;
	meter?: string;
	inputs: Port[];
	outputs: Port[];
	effect?: string;
};
export type GraphEdge = {
	routeDestination?: string | null;
	id: string;
	source: string;
	target: string;
	sourceHandle: string;
	targetHandle: string;
	kind: string;
	meter?: string;
	label: string;
};
export type Patch = { source: string; destination: string };
export type Noise = {
	enabled: boolean;
	engine: string;
	attenuation_limit_db: number;
	post_filter_beta: number;
};
export type Runtime = {
	schemaVersion: number;
	session: string;
	revision: number;
	appliedRevision: number | null;
	online: boolean;
	updatedAt: number;
	patches: Patch[];
	suppression: Noise;
	canUndo: boolean;
	canRedo: boolean;
	error?: string;
	pending?: string;
	inputName: string;
	outputName: string;
	devices?: DeviceBinding[];
	unavailableRoutes?: Record<string, string>;
};
export type Endpoint = { id: string; name: string; selected: boolean };
export type DeviceBinding = {
	id: string;
	name: string;
	direction: "input" | "output";
	endpointId: string;
};
export type Snapshot = {
	phone?: {
		supported: boolean;
		devices: { id: string; name: string }[];
		settings: {
			schemaVersion: number;
			deviceId?: string;
			autoConnect: boolean;
		};
		wanted: boolean;
		connected: boolean;
		phase: string;
		output?: { id: string; name: string };
		error?: string;
	};
	runtime: Runtime | null;
	topology: { nodes: GraphNode[]; edges: GraphEdge[] };
	graph: {
		engineOnline: boolean;
		routingReady: boolean;
		suppression: string;
		inputDevices: Endpoint[];
		outputDevices: Endpoint[];
		devices?: DeviceBinding[];
		mainInput?: Endpoint;
		mainOutput?: Endpoint;
		sessionOverride?: string;
		sessionInputOverride?: string;
		routes: { process: string; output?: string; input?: string }[];
		patches: Patch[];
	};
};
export type Meter = { id: string; peak: number; dbfs: number; waveform: number[] };
