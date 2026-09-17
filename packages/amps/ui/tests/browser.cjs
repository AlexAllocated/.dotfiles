// Isolated browser UI tests. Never connects to the native/live audio command API.
const { createRequire } = require("node:module");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const requireRuntime = createRequire(process.env.AMPS_PLAYWRIGHT_MODULE || __filename);
const { chromium } = requireRuntime("playwright");
(async () => {
	const fixture = JSON.parse(fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, ""));
	const output = process.argv[3];
	fs.mkdirSync(output, { recursive: true });
	const browser = await chromium.launch({
		executablePath: process.env.AMPS_BROWSER_EXECUTABLE,
		channel: process.env.AMPS_BROWSER_CHANNEL || "chrome",
		headless: true,
		args: ["--disable-gpu"]
	});
	try {
		const page = await browser.newPage({
			viewport: { width: 1600, height: 1000 },
			hasTouch: true
		});
		const errors = [];
		page.on("pageerror", e => errors.push(String(e)));
		const assertWindowFit = async () => {
			assert.equal(
				await page.locator("h1").innerText(),
				"Audio Mixing and Processing Subsystem"
			);
			const dimensions = await page.evaluate(() => ({
				pageWidth: document.documentElement.scrollWidth,
				pageHeight: document.documentElement.scrollHeight,
				width: innerWidth,
				height: innerHeight,
				footerBottom: document.querySelector("footer").getBoundingClientRect().bottom,
				canvasHeight: document.querySelector(".canvas").clientHeight,
				inspectorHeight: document.querySelector(".inspector").clientHeight
			}));
			assert(
				dimensions.pageWidth <= dimensions.width && dimensions.pageHeight <= dimensions.height,
				`Outer window overflow: ${JSON.stringify(dimensions)}`
			);
			assert(
				dimensions.footerBottom <= dimensions.height &&
					dimensions.canvasHeight > 60 &&
					dimensions.inspectorHeight > 60,
				`Workspace controls clipped: ${JSON.stringify(dimensions)}`
			);
		};
		// Match the packaged WebView policy, including the locally bundled ELK worker.
		await page.route("**/*", async route => {
			if (route.request().resourceType() !== "document") return route.continue();
			const response = await route.fetch();
			await route.fulfill({
				response,
				headers: {
					...response.headers(),
					"content-security-policy":
						"default-src 'self'; connect-src 'self' ipc: http://ipc.localhost; img-src 'self' data:; media-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'"
				}
			});
		});
		await page.addInitScript(
			({ fixture }) => {
				window.__TEST_SOUNDS__ = [];
				window.__TEST_AUDIO__ = [];
				HTMLMediaElement.prototype.play = function () {
					window.__TEST_SOUNDS__.push(this.src.split("/").at(-1));
					window.__TEST_AUDIO__.push(this);
					this.__testPaused = false;
					return Promise.resolve();
				};
				HTMLMediaElement.prototype.pause = function () {
					this.__testPaused = true;
				};
				fixture.phone = {
					supported: true,
					devices: [{ id: "fixture-phone", name: "Test phone" }],
					settings: { schemaVersion: 1, deviceId: null, autoConnect: false },
					wanted: false,
					connected: false,
					phase: "off",
					output: null,
					error: null
				};
				fixture.topology.nodes = fixture.topology.nodes.filter(
					n => !["phone", "monitor"].includes(n.id)
				);
				fixture.topology.edges = fixture.topology.edges.filter(e => e.source !== "monitor");
				fixture.topology.nodes.find(n => n.id === "main_output").inputs = [
					{
						id: "in",
						label: "Listening",
						direction: "input",
						editable: true,
						signal: "PCM",
						fanIn: true
					}
				];
				fixture.topology.nodes.push({
					id: "phone",
					title: "Phone Audio",
					kind: "device",
					detail: "Private phone playback",
					meter: "phone",
					inputs: [],
					outputs: [
						{
							id: "out",
							label: "Received audio",
							direction: "output",
							editable: true,
							signal: "PCM",
							fanIn: false
						}
					]
				});
				const patches = fixture.graph.patches.filter(p => p.source !== "phone");
				patches.push({ source: "phone", destination: "main_output" });
				fixture.graph.inputDevices.push({
					id: "fixture-input",
					name: "Test microphone",
					selected: false
				});
				fixture.graph.outputDevices.push({
					id: "fixture-output",
					name: "Test speakers",
					selected: false
				});
				fixture.runtime = {
					schemaVersion: 1,
					session: "isolated-test",
					revision: 1,
					appliedRevision: 1,
					online: true,
					updatedAt: Date.now(),
					patches,
					devices: [],
					suppression: {
						enabled: true,
						engine: "nvidia_afx",
						attenuation_limit_db: 40,
						post_filter_beta: 0
					},
					canUndo: false,
					canRedo: false,
					inputName: fixture.graph.mainInput?.name,
					outputName: fixture.graph.mainOutput?.name
				};
				const undo = [],
					redo = [];
				const regenerate = () => {
					fixture.topology.nodes = fixture.topology.nodes
						.filter(n => !n.id.startsWith("device-"))
						.concat(
							fixture.runtime.devices.map(d => ({
								id: d.id,
								title: d.name,
								kind: "device",
								detail: `Pinned ${d.direction}`,
								meter: d.direction === "input" ? d.id : null,
								inputs:
									d.direction === "output" ?
										[
											{
												id: "in",
												label: "Mix in",
												direction: "input",
												editable: true,
												signal: "PCM",
												fanIn: true
											}
										]
									:	[],
								outputs:
									d.direction === "input" ?
										[
											{
												id: "out",
												label: "Signal out",
												direction: "output",
												editable: true,
												signal: "PCM",
												fanIn: false
											}
										]
									:	[]
							}))
						);
					fixture.topology.edges = fixture.topology.edges
						.filter(e => e.kind !== "patch")
						.concat(
							fixture.runtime.patches.map(p => ({
								id: `patch:${p.source}:${p.destination}`,
								source: p.source,
								target: p.destination === "monitor" ? "main_output" : p.destination,
								routeDestination: p.destination,
								sourceHandle: "out",
								targetHandle: "in",
								kind: "patch",
								meter: fixture.topology.nodes.find(n => n.id === p.source)?.meter,
								label: "Unity gain"
							}))
						);
				};
				regenerate();
				window.__TEST_REQUESTS__ = [];
				window.__TEST_BINDING__ = name => {
					fixture.runtime.outputName = name;
					fixture.graph.sessionOverride =
						name === "Speakers (Steam Streaming Speakers)" ? name : null;
				};
				window.__TEST_METERS__ = {};
				window.__AMPS_TEST__ = {
					invoke: async (cmd, args) => {
						if (cmd === "routing_snapshot") return structuredClone(fixture);
						if (cmd === "select_main_output" || cmd === "select_main_input") {
							window.__TEST_REQUESTS__.push({ cmd, args });
							const direction = cmd.endsWith("output") ? "output" : "input";
							const endpoint = fixture.graph[`${direction}Devices`].find(
								d => d.id === args.endpointId
							);
							if (!endpoint) throw new Error("Device disconnected");
							setTimeout(() => {
								fixture.runtime[`${direction}Name`] = endpoint.name;
							}, 350);
							return;
						}
						if (cmd === "meter_snapshot")
							return [
								"game",
								"comms",
								"music",
								"chatgpt",
								"chatgpt-in",
								"comms-send",
								"clean-mic",
								"processed-mic",
								"physical-mic",
								"monitor"
							]
								.map(id =>
									Object.hasOwn(window.__TEST_METERS__, id) ?
										window.__TEST_METERS__[id]
									:	{
											id,
											peak: id.includes("mic") ? 0 : 0.3,
											dbfs: id.includes("mic") ? -90 : -12,
											waveform: Array.from({ length: 192 }, (_, i) =>
												id.includes("mic") ? 0 : Math.sin(i * 0.4) * 0.15
											)
										}
								)
								.filter(Boolean);
						if (cmd === "edit_routing") {
							const r = args.request;
							window.__TEST_REQUESTS__.push(r);
							if (r.expectedRevision !== fixture.runtime.revision)
								return { id: r.id, applied: false, error: "stale revision" };
							const prev = structuredClone({
									patches: fixture.runtime.patches,
									devices: fixture.runtime.devices
								}),
								edit = r.edit;
							if (edit.kind === "undo") {
								redo.push(prev);
								Object.assign(fixture.runtime, undo.pop());
							} else if (edit.kind === "redo") {
								undo.push(prev);
								Object.assign(fixture.runtime, redo.pop());
							} else {
								undo.push(prev);
								redo.length = 0;
								if (edit.kind === "add_device") fixture.runtime.devices.push(edit.device);
								if (edit.kind === "remove_device") {
									fixture.runtime.devices = fixture.runtime.devices.filter(
										d => d.id !== edit.id
									);
									fixture.runtime.patches = fixture.runtime.patches.filter(
										p => p.source !== edit.id && p.destination !== edit.id
									);
								}
								if (edit.kind === "connect")
									fixture.runtime.patches.push({
										source: edit.source,
										destination: edit.destination
									});
								if (edit.kind === "disconnect")
									fixture.runtime.patches = prev.patches.filter(
										p => !(p.source === edit.source && p.destination === edit.destination)
									);
								if (edit.kind === "suppression")
									fixture.runtime.suppression = {
										enabled: edit.enabled,
										engine: edit.engine,
										attenuation_limit_db: edit.intensity * 0.4,
										post_filter_beta: 0
									};
							}
							fixture.runtime.revision++;
							fixture.runtime.appliedRevision = fixture.runtime.revision;
							fixture.runtime.canUndo = !!undo.length;
							fixture.runtime.canRedo = !!redo.length;
							regenerate();
							return { id: r.id, applied: true, revision: fixture.runtime.revision };
						}
						if (cmd === "set_clean_mic_monitor") return args.enabled ? "Test output" : null;
						if (cmd === "phone_control") {
							window.__TEST_REQUESTS__.push({ cmd, args });
							const request = args.request;
							if (request.deviceId) fixture.phone.settings.deviceId = request.deviceId;
							if (typeof request.autoConnect === "boolean")
								fixture.phone.settings.autoConnect = request.autoConnect;
							if (["connect", "reconnect", "disconnect"].includes(request.action)) {
								fixture.phone.wanted = fixture.phone.connected =
									request.action !== "disconnect";
								fixture.phone.phase = fixture.phone.connected ? "connected" : "off";
								fixture.phone.output =
									fixture.phone.connected ? fixture.graph.mainOutput : null;
							}
							return null;
						}
						if (cmd.startsWith("select_main_")) {
							window.__TEST_REQUESTS__.push({ cmd, args });
							return null;
						}
						throw new Error(`Unmocked native command ${cmd}`);
					}
				};
				window.__TAURI__ = {
					core: window.__AMPS_TEST__,
					event: {
						async listen(name, callback) {
							window.__TEST_NATIVE_FEEDBACK__ = callback;
							return () => {
								window.__TEST_NATIVE_FEEDBACK__ = null;
							};
						}
					}
				};
			},
			{ fixture }
		);
		await page.goto(process.env.AMPS_TEST_URL || "http://127.0.0.1:5173");
		try {
			await page.waitForSelector(".react-flow__node");
		} catch (error) {
			await page.screenshot({ path: path.join(output, "startup-error.png"), fullPage: true });
			console.error({ errors, body: await page.locator("body").innerText() });
			throw error;
		}
		await page.waitForFunction(() => document.querySelectorAll(".react-flow__edge").length > 10);
		await page.waitForTimeout(1800);
		assert.equal(errors.length, 0, errors.join("\n"));
		assert.deepEqual(
			await page.evaluate(() => window.__TEST_SOUNDS__),
			[],
			"Polling or initial layout played sound"
		);
		const audible = async (label, action, clip) => {
			await page.waitForTimeout(200);
			await page.evaluate(() => {
				window.__TEST_SOUNDS__ = [];
			});
			await action();
			await page.waitForFunction(clip => window.__TEST_SOUNDS__.includes(`${clip}.mp3`), clip);
			console.log(`Sound feedback: ${label}`);
		};
		await page.evaluate(() => window.__TEST_BINDING__("Speakers (Steam Streaming Speakers)"));
		await page.waitForFunction(() =>
			document
				.querySelector('select[aria-label="Main Output"]')
				.selectedOptions[0].textContent.includes("Steam Streaming Speakers")
		);
		const physicalId = await page
			.locator('select[aria-label="Main Output"] option:not([disabled])')
			.first()
			.getAttribute("value");
		await page.getByLabel("Main Output", { exact: true }).selectOption(physicalId);
		assert.equal(await page.getByLabel("Main Output", { exact: true }).isDisabled(), true);
		await page.waitForFunction(id => {
			const select = document.querySelector('select[aria-label="Main Output"]');
			return !select.disabled && select.value === id;
		}, physicalId);
		await page.evaluate(() => {
			window.__TEST_REQUESTS__ = [];
		});
		for (const button of [".react-flow__controls-zoomin", ".react-flow__controls-zoomout"]) {
			await page.waitForTimeout(300);
			await audible("zoom control", () => page.locator(button).click(), "search");
			assert.deepEqual(
				await page.evaluate(() => window.__TEST_SOUNDS__),
				["search.mp3"],
				"Zoom played a button beep"
			);
		}
		await audible(
			"toolbar button",
			() => page.getByRole("button", { name: "Fit graph", exact: true }).click(),
			"intrepid-key"
		);
		await audible(
			"keyboard button activation",
			async () => {
				await page.getByRole("button", { name: "Arrange", exact: true }).focus();
				await page.keyboard.press("Enter");
			},
			"intrepid-key"
		);
		await audible(
			"selector change",
			() => page.getByLabel("Connection source", { exact: true }).selectOption("music"),
			"key-02"
		);
		await audible(
			"node selection",
			() => page.locator('[data-id="noise_filter"]').click(),
			"intrepid-key"
		);
		await audible("slider adjustment", () => page.getByRole("slider").fill("75"), "search");
		await page.waitForTimeout(300);
		await page.evaluate(() => {
			window.__TEST_SOUNDS__ = [];
		});
		for (let i = 0; i < 15; i++) {
			await page.locator(".inspector").dispatchEvent("wheel", { deltaY: 10 });
			await page.waitForTimeout(30);
		}
		assert.deepEqual(
			await page.evaluate(() => window.__TEST_SOUNDS__),
			["search.mp3"],
			"Scroll burst retriggered a cue"
		);
		await page.waitForFunction(() => window.__TEST_AUDIO__.at(-1).__testPaused);
		await page.evaluate(() => {
			window.__TEST_SOUNDS__ = [];
		});
		const nodeBox = await page.locator('[data-id="noise_filter"] .signal-node').boundingBox();
		await page.mouse.move(nodeBox.x + 40, nodeBox.y + 20);
		await page.mouse.down();
		await page.mouse.move(nodeBox.x + 80, nodeBox.y + 40, { steps: 10 });
		await page.waitForTimeout(700);
		assert.deepEqual(
			await page.evaluate(() => window.__TEST_SOUNDS__),
			["search.mp3"],
			"Drag did not use the scanning cue"
		);
		assert.equal(
			await page.evaluate(() => window.__TEST_AUDIO__.at(-1).__testPaused),
			false,
			"Held drag stopped scanning"
		);
		await page.mouse.up();
		await page.waitForFunction(() =>
			window.__TEST_AUDIO__.filter(audio => audio.loop).every(audio => audio.__testPaused)
		);
		await audible(
			"checkbox",
			() => page.getByRole("checkbox", { name: "Noise suppression", exact: true }).uncheck(),
			"key-02"
		);
		await audible(
			"native tray/window action",
			() => page.evaluate(() => window.__TEST_NATIVE_FEEDBACK__({ payload: "search" })),
			"search"
		);
		await page.getByRole("button", { name: "Sounds on", exact: true }).click();
		await page.evaluate(() => {
			window.__TEST_SOUNDS__ = [];
		});
		await page.getByRole("button", { name: "Fit graph", exact: true }).click();
		await page.evaluate(() => window.__TEST_NATIVE_FEEDBACK__({ payload: "confirm" }));
		assert.deepEqual(
			await page.evaluate(() => window.__TEST_SOUNDS__),
			[],
			"Muted UI/native action beeped"
		);
		await page.reload();
		await page.getByRole("button", { name: "Sounds off", exact: true }).waitFor();
		await page.waitForTimeout(1600);
		assert.deepEqual(
			await page.evaluate(() => window.__TEST_SOUNDS__),
			[],
			"Saved mute or background polling beeped"
		);
		await audible(
			"unmute preview",
			() => page.getByRole("button", { name: "Sounds off", exact: true }).click(),
			"intrepid-key"
		);
		for (const clip of ["intrepid-key", "key-02", "search", "confirm", "denied"]) {
			const asset = await page.request.get(new URL(`audio/${clip}.mp3`, page.url()).href);
			assert.equal(asset.status(), 200, `Bundled sound missing: ${clip}`);
			assert((await asset.body()).length > 1000);
		}
		await page.getByRole("combobox", { name: "Paired phone" }).selectOption("fixture-phone");
		await page.getByRole("button", { name: "Enable receiver", exact: true }).click();
		await page.getByRole("button", { name: "Disable receiver", exact: true }).waitFor();
		await audible(
			"explicit phone reconnect",
			() => page.getByRole("button", { name: "Restart receiver", exact: true }).click(),
			"confirm"
		);
		assert.equal(
			await page.evaluate(() => window.__TEST_REQUESTS__.at(-1)?.args?.request?.action),
			"reconnect"
		);
		assert.equal(await page.getByRole("combobox", { name: "Phone buffer" }).count(), 0);
		await page.locator('.react-flow__edge[data-id="patch:phone:main_output"]').waitFor();
		assert.equal(
			await page
				.locator('.react-flow__node[data-id="main_output"] .react-flow__handle.target')
				.count(),
			1
		);
		await assertWindowFit();
		await page.screenshot({ path: path.join(output, "phone-connected.png"), fullPage: true });
		await page.getByRole("checkbox", { name: "Enable receiver when AMPS starts (phone initiates connection)" }).check();
		await page.getByRole("button", { name: "Disable receiver", exact: true }).click();
		await page.getByRole("button", { name: "Enable receiver", exact: true }).waitFor();
		assert(await page.getByRole("checkbox", { name: "Enable receiver when AMPS starts (phone initiates connection)" }).isChecked());
		for (const [id, title] of [
			["comms", "Comms Audio"],
			["comms_send", "Comms Mic"],
			["chatgpt", "AI Audio"],
			["chatgpt_in", "AI Mic"]
		]) {
			assert.match(
				await page.locator(`.react-flow__node[data-id="${id}"]`).innerText(),
				new RegExp(title, "i")
			);
		}
		// Only AMPS-owned nodes/routes are drawn; no external-app placeholders.
		assert.equal(
			await page
				.locator('[data-id="obs"], [data-id="ai_capture"], [data-id="comms_capture"]')
				.count(),
			0
		);
		assert.equal(await page.locator('.react-flow__edge[data-id^="policy:"]').count(), 0);
		for (const id of ["chatgpt_in", "comms_send"]) {
			assert.equal(
				await page
					.locator(`.react-flow__node[data-id="${id}"] .react-flow__handle.source`)
					.count(),
				0
			);
		}
		// Added endpoints are independent, initially unwired, and survive undo.
		const originalPatches = await page.evaluate(
			() => window.__TEST_REQUESTS__.filter(r => r.edit).length
		);
		await page
			.getByRole("combobox", { name: "Add physical output" })
			.selectOption("fixture-output");
		await page
			.getByRole("combobox", { name: "Add physical input" })
			.selectOption("fixture-input");
		await page.waitForFunction(
			() => document.querySelectorAll('.react-flow__node[data-id^="device-"]').length === 2
		);
		assert.equal(
			await page.locator('.react-flow__edge[data-id*="device-"]').count(),
			0,
			"Adding a device silently created a route"
		);
		const deviceIds = await page
			.locator('.react-flow__node[data-id^="device-"]')
			.evaluateAll(nodes => nodes.map(n => n.dataset.id));
		await page.locator(`.react-flow__node[data-id="${deviceIds[0]}"]`).click();
		await page.getByRole("button", { name: "Remove device", exact: true }).click();
		await page
			.waitForFunction(
				() => document.querySelectorAll('.react-flow__node[data-id^="device-"]').length === 1
			)
			.catch(async error => {
				console.error(
					errors,
					await page.locator("body").innerText(),
					await page.evaluate(() => window.__TEST_REQUESTS__)
				);
				await page.screenshot({ path: path.join(output, "device-removal-error.png") });
				throw error;
			});
		await page.getByRole("button", { name: /Undo/ }).first().click();
		await page.waitForFunction(
			() => document.querySelectorAll('.react-flow__node[data-id^="device-"]').length === 2
		);
		assert.equal(await page.locator('.react-flow__edge[data-id*="device-"]').count(), 0);
		await page.locator(".react-flow__pane").click({ position: { x: 8, y: 8 } });
		await page.getByRole("combobox", { name: "Connection source" }).selectOption("phone");
		await page
			.getByRole("combobox", { name: "Connection destination" })
			.selectOption("comms_send");
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		assert.equal(
			await page.getByRole("alertdialog").count(),
			0,
			"Connecting phone audio must not require confirmation"
		);
		await page.locator('[data-id="patch:phone:comms_send"]').waitFor();
		await page.getByRole("button", { name: "Undo", exact: true }).click();
		await page.waitForFunction(
			() => !document.querySelector('[data-id="patch:phone:comms_send"]')
		);
		await assertWindowFit();
		// Each retained wire displays its own source bus, not the downstream mix.
		await page.locator('.react-flow__node[data-id="game"]').click();
		await page.locator('.react-flow__node[data-id="music"] .signal-node.dimmed').waitFor();
		assert.equal(await page.locator('.react-flow__node[data-id="monitor"]').count(), 0);
		for (const id of ["game", "main_output"]) {
			assert.equal(
				await page.locator(`.react-flow__node[data-id="${id}"] .signal-node.dimmed`).count(),
				0
			);
		}
		assert.equal(await page.locator('[data-id="patch:game:monitor"] .wire.dimmed').count(), 0);
		assert.equal(await page.locator('[data-id="patch:music:monitor"] .wire.dimmed').count(), 1);
		await page.screenshot({ path: path.join(output, "node-focus.png"), fullPage: true });
		// A dimmed node remains interactive and can become the new focus.
		await page.locator('.react-flow__node[data-id="music"]').click();
		await page.locator('.react-flow__node[data-id="game"] .signal-node.dimmed').waitFor();
		assert.equal(
			await page.locator('.react-flow__node[data-id="music"] .signal-node.dimmed').count(),
			0
		);
		await page.waitForTimeout(1600);
		assert.equal(
			await page.locator('.react-flow__node[data-id="game"] .signal-node.dimmed').count(),
			1,
			"Snapshot lost node focus"
		);
		await page.locator(".react-flow__pane").click({ position: { x: 8, y: 8 } });
		assert.equal(await page.locator(".signal-node.dimmed").count(), 0);
		const musicRoute = page.locator('[data-id="patch:music:monitor"] .wave');
		await page.waitForFunction(
			() => !!document.querySelector('[data-id="patch:music:monitor"] .wave')?.getAttribute("d")
		);
		assert.equal(await page.locator(".wire.dimmed").count(), 0, "Overview hid a branch");
		assert.equal(
			await page.locator('[data-id="fixed:noise_filter:clean_mic"] .wave').getAttribute("d"),
			""
		);
		const musicTrace = await musicRoute.getAttribute("d");
		await page.evaluate(() => {
			window.__TEST_METERS__.monitor = { id: "monitor", peak: 0, dbfs: -90, waveform: [0, 0] };
		});
		await page.waitForTimeout(150);
		assert.equal(
			await musicRoute.getAttribute("d"),
			musicTrace,
			"Listening-mix silence changed the source waveform"
		);
		await page.evaluate(() => {
			window.__TEST_METERS__.music = {
				id: "music",
				peak: 0.3,
				dbfs: -12,
				waveform: [0.3, -0.3, 0.1]
			};
		});
		await page.waitForFunction(previous => {
			const current = document
				.querySelector('[data-id="patch:music:monitor"] .wave')
				?.getAttribute("d");
			return !!current && current !== previous;
		}, musicTrace);
		await page.evaluate(() => {
			delete window.__TEST_METERS__.monitor;
			window.__TEST_METERS__.music = { id: "music", peak: 0, dbfs: -90, waveform: [0, 0] };
		});
		await page.waitForFunction(
			() =>
				document.querySelector('[data-id="patch:music:monitor"] .wave')?.getAttribute("d") ===
				""
		);
		assert.equal(await page.locator('[data-id="fixed:monitor:main_output"]').count(), 0);
		await page.evaluate(() => {
			window.__TEST_METERS__.music = null;
		});
		await page.waitForTimeout(150);
		assert.equal(
			await musicRoute.getAttribute("d"),
			"",
			"Missing source telemetry invented activity"
		);
		await page.evaluate(() => {
			delete window.__TEST_METERS__.music;
		});
		await page.waitForFunction(
			() => !!document.querySelector('[data-id="patch:music:monitor"] .wave')?.getAttribute("d")
		);
		const bounds = await page.locator(".react-flow__node").evaluateAll(nodes =>
			nodes.map(n => {
				const r = n.getBoundingClientRect();
				return { id: n.dataset.id, x: r.x, y: r.y, right: r.right, bottom: r.bottom };
			})
		);
		for (let i = 0; i < bounds.length; i++)
			for (let j = i + 1; j < bounds.length; j++) {
				const a = bounds[i],
					b = bounds[j];
				assert(
					!(a.x < b.right && a.right > b.x && a.y < b.bottom && a.bottom > b.y),
					`Nodes overlap: ${a.id}/${b.id}`
				);
			}
		await page.screenshot({ path: path.join(output, "desktop.png"), fullPage: true });
		await assertWindowFit();
		const styling = await page.evaluate(() => {
			const canvas = document.querySelector(".canvas");
			const handle = document.querySelector(".react-flow__handle");
			return {
				background: getComputedStyle(canvas).backgroundColor,
				width: canvas.clientWidth,
				height: canvas.clientHeight,
				font: getComputedStyle(document.querySelector(".toolbar button")).fontFamily,
				buttonHeight: document.querySelector(".toolbar button").getBoundingClientRect().height,
				handleWidth: parseFloat(getComputedStyle(handle).width),
				hitPadding: getComputedStyle(handle, "::after").left
			};
		});
		assert.equal(styling.background, "rgb(0, 0, 0)");
		assert.match(styling.font, /Antonio/);
		assert(
			styling.width >= 1250 && styling.height >= 730,
			"LCARS framing shrank the usable desktop canvas"
		);
		assert(
			styling.buttonHeight >= 38 && styling.handleWidth >= 16 && styling.hitPadding === "-10px",
			"Control/port hit target shrank"
		);
		const movable = page.locator('.react-flow__node[data-id="game"]');
		const beforeMove = await movable.getAttribute("style");
		const grip = await movable.locator(".node-drag").boundingBox();
		await page.mouse.move(grip.x + 20, grip.y + 15);
		await page.mouse.down();
		await page.mouse.move(grip.x + 48, grip.y + 27, { steps: 8 });
		await page.mouse.up();
		await page.waitForTimeout(1700);
		assert.notEqual(
			await movable.getAttribute("style"),
			beforeMove,
			"Meter/snapshot refresh undid node drag"
		);
		const savedPosition = await page.evaluate(
			() => JSON.parse(localStorage.getItem("audioarray:layout:v1")).positions.game
		);
		await page.reload();
		await page.waitForSelector('.react-flow__node[data-id="game"]');
		await page.waitForTimeout(500);
		assert.deepEqual(
			await page.evaluate(
				() => JSON.parse(localStorage.getItem("audioarray:layout:v1")).positions.game
			),
			savedPosition,
			"Reload discarded saved node positions"
		);
		// Regression: a newly-added phone node inherited coordinates occupied by
		// the user's saved Main Input, making it look wired to noise suppression.
		const savedMic = await page.evaluate(() => {
			const layout = JSON.parse(localStorage.getItem("audioarray:layout:v1"));
			layout.positions.phone = { ...layout.positions.physical_mic };
			localStorage.setItem("audioarray:layout:v1", JSON.stringify(layout));
			return layout.positions.physical_mic;
		});
		await page.reload();
		await page.waitForSelector('.react-flow__node[data-id="phone"]');
		await page.waitForTimeout(500);
		assert.deepEqual(
			await page.evaluate(
				() => JSON.parse(localStorage.getItem("audioarray:layout:v1")).positions.physical_mic
			),
			savedMic
		);
		const micBounds = await page
			.locator('.react-flow__node[data-id="physical_mic"]')
			.boundingBox();
		const phoneBounds = await page.locator('.react-flow__node[data-id="phone"]').boundingBox();
		assert(phoneBounds.y >= micBounds.y + micBounds.height + 5, "Phone obscures Main Input");
		assert.equal(await page.locator('[data-id="physical_mic"] h3').innerText(), "MAIN INPUT");
		await page.screenshot({
			path: path.join(output, "phone-layout-repaired.png"),
			fullPage: true
		});
		await page.getByLabel("Connection source", { exact: true }).selectOption("comms");
		await page.getByLabel("Connection destination", { exact: true }).selectOption("comms_send");
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.getByRole("alert").filter({ hasText: "Blocked self-return" }).waitFor();
		assert.equal(
			await page.evaluate(() => window.__TEST_REQUESTS__.length),
			0,
			"Invalid edit reached native bridge"
		);
		await page.getByLabel("Connection source", { exact: true }).selectOption("music");
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.waitForFunction(() => window.__TEST_REQUESTS__.length === 1);
		await page.getByRole("button", { name: "Undo", exact: true }).click();
		await page.waitForFunction(() => window.__TEST_REQUESTS__.length === 2);
		await page.getByRole("button", { name: "Redo", exact: true }).click();
		await page.waitForFunction(() => window.__TEST_REQUESTS__.length === 3);
		await page.locator('.react-flow__node[data-id="comms_send"]').click();
		await page.getByRole("button", { name: "Media unity", exact: true }).click();
		await page.getByRole("button", { name: "Disconnect route", exact: true }).focus();
		await page.keyboard.press("Enter");
		await page.waitForFunction(
			() => window.__TEST_REQUESTS__.at(-1)?.edit?.kind === "disconnect"
		);
		await page.getByRole("button", { name: "Undo", exact: true }).click();
		await page.waitForFunction(() => window.__TEST_REQUESTS__.at(-1)?.edit?.kind === "undo");
		await page.locator('.react-flow__node[data-id="noise_filter"]').click();
		await page.getByRole("slider").fill("25");
		await page.waitForTimeout(2000);
		assert.equal(
			await page.getByRole("slider").inputValue(),
			"25",
			"Snapshot reset in-progress slider"
		);
		await page.getByRole("button", { name: "Apply filter settings" }).click();
		await page.waitForFunction(
			() => window.__TEST_REQUESTS__.at(-1)?.edit?.kind === "suppression"
		);
		// Exercise actual graph-port dragging and keyboard undo, not just menu controls.
		const from = await page
			.locator('.react-flow__node[data-id="clean_mic"] .react-flow__handle.source')
			.boundingBox();
		const to = await page
			.locator('.react-flow__node[data-id="main_output"] .react-flow__handle.target')
			.boundingBox();
		await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
		await page.mouse.down();
		await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 20 });
		await page.mouse.up();
		await page.waitForFunction(
			() => window.__TEST_REQUESTS__.at(-1)?.edit?.source === "clean_mic"
		);
		assert.equal(
			await page.evaluate(() => window.__TEST_REQUESTS__.at(-1).edit.destination),
			"monitor"
		);
		await page.locator(".masthead").click();
		await page.keyboard.press("Control+z");
		await page.waitForFunction(() => window.__TEST_REQUESTS__.at(-1)?.edit?.kind === "undo");
		await page.setViewportSize({ width: 1480, height: 920 });
		// Phone routes use the same one-step path when drawing on the canvas.
		await page.getByRole("button", { name: "Fit graph", exact: true }).click();
		await page.waitForTimeout(400);
		const phoneFrom = await page
			.locator('.react-flow__node[data-id="phone"] .react-flow__handle.source')
			.boundingBox();
		const commsTo = await page
			.locator('.react-flow__node[data-id="comms_send"] .react-flow__handle.target')
			.boundingBox();
		await page.mouse.move(phoneFrom.x + phoneFrom.width / 2, phoneFrom.y + phoneFrom.height / 2);
		await page.mouse.down();
		await page.mouse.move(commsTo.x + commsTo.width / 2, commsTo.y + commsTo.height / 2, {
			steps: 20
		});
		await page.mouse.up();
		await page.locator('[data-id="patch:phone:comms_send"]').waitFor();
		assert.equal(await page.getByRole("alertdialog").count(), 0);
		await page.getByRole("button", { name: "Undo", exact: true }).click();
		await page.waitForFunction(
			() => !document.querySelector('[data-id="patch:phone:comms_send"]')
		);
		await page.getByRole("button", { name: "Fit graph", exact: true }).click();
		await page.screenshot({ path: path.join(output, "window.png"), fullPage: true });
		await assertWindowFit();
		await page.setViewportSize({ width: 1024, height: 1366 });
		await page.getByRole("button", { name: "Fit graph", exact: true }).tap();
		await page.waitForTimeout(500);
		await page.screenshot({ path: path.join(output, "ipad.png"), fullPage: true });
		await assertWindowFit();
		await page.getByRole("button", { name: "Focus node", exact: true }).click();
		await page.waitForTimeout(200);
		await page.screenshot({ path: path.join(output, "ipad-focus.png"), fullPage: true });
		assert(
			await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
			"Horizontal page overflow"
		);
		await page.emulateMedia({ reducedMotion: "reduce" });
		await page.setViewportSize({ width: 650, height: 1000 });
		await page.waitForTimeout(300);
		await page.screenshot({ path: path.join(output, "narrow.png"), fullPage: true });
		await assertWindowFit();
		assert(
			await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
			"Narrow page overflow"
		);
		assert(
			await page.locator(".registry span").evaluate(label => {
				const text = label.getBoundingClientRect();
				const frame = label.parentElement.getBoundingClientRect();
				return text.left >= frame.left + 8 && text.right <= frame.right - 8;
			}),
			"Registry label escaped its narrow LCARS frame"
		);
		assert.equal(errors.length, 0, errors.join("\n"));
		await page.setViewportSize({ width: 600, height: 480 });
		await page.waitForTimeout(300);
		await assertWindowFit();
		// The inspector must remain usable even at the native window's minimum size.
		await page.getByRole("button", { name: "Connect", exact: true }).scrollIntoViewIfNeeded();
		await assertWindowFit();
		await page.screenshot({ path: path.join(output, "minimum.png"), fullPage: true });
		await page.getByRole("combobox", { name: "Connection source" }).selectOption("phone");
		await page
			.getByRole("combobox", { name: "Connection destination" })
			.selectOption("comms_send");
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.locator('[data-id="patch:phone:comms_send"]').waitFor();
		assert.equal(await page.getByRole("alertdialog").count(), 0);
		console.log(
			JSON.stringify({
				result: "PASS",
				nodes: fixture.topology.nodes.length,
				errors,
				screenshots: output,
				requests: await page.evaluate(() =>
					window.__TEST_REQUESTS__.map(r => r.edit?.kind ?? r.cmd)
				)
			})
		);
	} finally {
		await browser.close();
	}
})().catch(e => {
	console.error(e);
	process.exitCode = 1;
});
