import test from "node:test";
import assert from "node:assert/strict";
import { selectDevice } from "../src/device-selection.mjs";

function harness(bindings) {
	let clock = 0;
	const requests = [];
	return {
		requests,
		args: {
			direction: "output",
			id: "usb-id",
			name: "USB headphones",
			timeout: 600,
			invoke: async (command, args) => requests.push({ command, args }),
			refresh: async () => ({
				runtime: {
					online: true,
					outputName: bindings.length > 1 ? bindings.shift() : bindings[0]
				}
			}),
			now: () => clock,
			sleep: async ms => {
				clock += ms;
			}
		}
	};
}

test("selection confirms the active engine binding, not the saved preference", async () => {
	const { args, requests } = harness(["Moonlight", "Moonlight", "USB headphones"]);
	const result = await selectDevice(args);
	assert.equal(result.runtime.outputName, "USB headphones");
	assert.deepEqual(requests, [{ command: "select_main_output", args: { endpointId: "usb-id" } }]);
});
test("an overridden binding reports the active device rather than false success", async () => {
	const { args } = harness(["Moonlight"]);
	await assert.rejects(selectDevice(args), /Active device: Moonlight/);
});
test("native errors propagate and a hung request cannot lock the selector forever", async () => {
	const { args } = harness([]);
	await assert.rejects(
		selectDevice({
			...args,
			invoke: async () => {
				throw new Error("Disconnected");
			}
		}),
		/Disconnected/
	);
	await assert.rejects(
		selectDevice({ ...args, timeout: 10, invoke: () => new Promise(() => {}) }),
		/timed out/
	);
	await assert.rejects(
		selectDevice({ ...args, timeout: 10, refresh: () => new Promise(() => {}) }),
		/timed out/
	);
});
