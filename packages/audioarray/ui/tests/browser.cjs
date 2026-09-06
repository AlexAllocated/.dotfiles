// Isolated browser UI tests. Never connects to the native/live audio command API.
const { createRequire } = require("node:module");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const requireRuntime = createRequire(process.env.AUDIOARRAY_PLAYWRIGHT_MODULE || __filename);
const { chromium } = requireRuntime("playwright");
(async () => {
	const fixture = JSON.parse(fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, ""));
	const output = process.argv[3];
	fs.mkdirSync(output, { recursive: true });
	const browser = await chromium.launch({
		channel: process.env.AUDIOARRAY_BROWSER_CHANNEL || "chrome",
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
				const patches = fixture.graph.patches;
				fixture.runtime = {
					schemaVersion: 1,
					session: "isolated-test",
					revision: 1,
					appliedRevision: 1,
					online: true,
					updatedAt: Date.now(),
					patches,
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
					fixture.topology.edges = fixture.topology.edges
						.filter(e => e.kind !== "patch")
						.concat(
							fixture.runtime.patches.map(p => ({
								id: `patch:${p.source}:${p.destination}`,
								source: p.source,
								target: p.destination,
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
				window.__TEST_METERS__ = {};
				window.__AUDIOARRAY_TEST__ = {
					invoke: async (cmd, args) => {
						if (cmd === "routing_snapshot") return structuredClone(fixture);
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
							const prev = structuredClone(fixture.runtime.patches),
								edit = r.edit;
							if (edit.kind === "undo") {
								redo.push(prev);
								fixture.runtime.patches = undo.pop();
							} else if (edit.kind === "redo") {
								undo.push(prev);
								fixture.runtime.patches = redo.pop();
							} else {
								undo.push(prev);
								redo.length = 0;
								if (edit.kind === "connect")
									fixture.runtime.patches.push({
										source: edit.source,
										destination: edit.destination
									});
								if (edit.kind === "disconnect")
									fixture.runtime.patches = prev.filter(
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
						if (cmd.startsWith("select_main_")) {
							window.__TEST_REQUESTS__.push({ cmd, args });
							return null;
						}
						throw new Error(`Unmocked native command ${cmd}`);
					}
				};
			},
			{ fixture }
		);
		await page.goto(process.env.AUDIOARRAY_TEST_URL || "http://127.0.0.1:5173");
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
		// Only AudioArray-owned nodes/routes are drawn; no external-app placeholders.
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
		// Each retained wire displays its own source bus, not the downstream mix.
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
		assert(
			await page.locator('[data-id="fixed:monitor:main_output"] .wave').getAttribute("d"),
			"Monitor fixture should still be active"
		);
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
			.locator('.react-flow__node[data-id="monitor"] .react-flow__handle.target')
			.boundingBox();
		await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
		await page.mouse.down();
		await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 20 });
		await page.mouse.up();
		await page.waitForFunction(
			() => window.__TEST_REQUESTS__.at(-1)?.edit?.source === "clean_mic"
		);
		await page.locator(".masthead").click();
		await page.keyboard.press("Control+z");
		await page.waitForFunction(() => window.__TEST_REQUESTS__.at(-1)?.edit?.kind === "undo");
		await page.setViewportSize({ width: 1480, height: 920 });
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
