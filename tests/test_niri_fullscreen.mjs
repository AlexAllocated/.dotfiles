import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [port, directory, seconds, hidden, niri] = process.argv.slice(2);
const endpoint = `http://127.0.0.1:${port}`;
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function connect(url) {
	const socket = new WebSocket(url);
	await new Promise((resolve, reject) => {
		socket.addEventListener("open", resolve, { once: true });
		socket.addEventListener("error", reject, { once: true });
	});
	let sequence = 0;
	const pending = new Map();
	socket.addEventListener("message", ({ data }) => {
		const message = JSON.parse(data);
		if (message.id) {
			pending.get(message.id)(message);
			pending.delete(message.id);
		}
	});
	return {
		socket,
		call(method, params = {}) {
			return new Promise((resolve, reject) => {
				const id = ++sequence;
				pending.set(id, message =>
					message.error ?
						reject(new Error(JSON.stringify(message.error)))
					:	resolve(message.result)
				);
				socket.send(JSON.stringify({ id, method, params }));
			});
		}
	};
}

const version = await (await fetch(`${endpoint}/json/version`)).json();
const browser = await connect(version.webSocketDebuggerUrl);
const { gpu } = await browser.call("SystemInfo.getInfo");
const pages = await (await fetch(`${endpoint}/json/list`)).json();
const page = pages.find(candidate => candidate.url.endsWith("/test.html"));
const client = await connect(page.webSocketDebuggerUrl);
const layout = () =>
	JSON.parse(execFileSync(niri, ["msg", "--json", "windows"], { encoding: "utf8" }));

try {
	if (hidden === "true") {
		await browser.call("Target.createTarget", {
			url: pathToFileURL(join(directory, "hidden.html")).href,
			newWindow: true
		});
		await sleep(1000);
		const window = layout().find(candidate => candidate.title.includes("FullscreenProbe"));
		execFileSync(niri, ["msg", "action", "focus-window", "--id", String(window.id)]);
		await sleep(500);
	}
	const layouts = { before: layout() };
	await client.call("Runtime.evaluate", { expression: "events=[]" });
	const started = Date.now();
	await client.call("Runtime.evaluate", {
		expression: "document.documentElement.requestFullscreen()",
		userGesture: true
	});
	await sleep(700);
	layouts.fullscreen = layout();
	await sleep(Number(seconds) * 1000 - 700);
	const evaluated = await client.call("Runtime.evaluate", {
		expression: "({events,fullscreen:!!document.fullscreenElement})",
		returnByValue: true
	});
	const finished = Date.now();
	layouts.after = layout();
	console.log(
		JSON.stringify({
			started,
			finished,
			state: evaluated.result.value,
			layouts,
			gpu: {
				devices: gpu.devices,
				featureStatus: gpu.featureStatus,
				auxAttributes: {
					glRenderer: gpu.auxAttributes.glRenderer,
					glVersion: gpu.auxAttributes.glVersion,
					displayType: gpu.auxAttributes.displayType
				}
			}
		})
	);
} finally {
	client.socket.close();
	browser.socket.close();
}
