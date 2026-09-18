const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Worker, isMainThread, workerData } = require("node:worker_threads");

if (isMainThread) {
	const worker = new Worker(__filename, { workerData: process.argv[2] });
	worker.on("error", (error) => {
		console.error(error);
		process.exitCode = 1;
	});
	worker.on("exit", (code) => {
		if (code !== 0) process.exitCode = code;
	});
} else {
	process.report.getReport = () => {
		throw new Error("libc detection must not invoke Electron's diagnostic report");
	};
	const filesystemPath = path.join(workerData, "node_modules/detect-libc/lib/filesystem.js");
	const filesystem = require(filesystemPath);
	const originalRead = filesystem.readFileSync;
	filesystem.readFileSync = (file) =>
		file === filesystem.SELF_PATH ? Buffer.alloc(0) : originalRead(file);
	const libc = require(path.join(workerData, "node_modules/detect-libc"));
	assert.equal(libc.familySync(), libc.GLIBC);
	const watcher = require(workerData);
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), "chatgpt-watcher-"));
	(async () => {
		let subscription;
		try {
			let received;
			const event = new Promise((resolve, reject) => {
				received = (error, events) => (error ? reject(error) : resolve(events));
			});
			subscription = await watcher.subscribe(directory, received);
			fs.writeFileSync(path.join(directory, "probe"), "watcher check");
			let timeout;
			try {
				const events = await Promise.race([
					event,
					new Promise((_, reject) => {
						timeout = setTimeout(() => reject(new Error("Watcher timed out")), 5000);
					})
				]);
				assert(events.some((entry) => entry.path === path.join(directory, "probe")));
			} finally {
				clearTimeout(timeout);
			}
			console.log("Desktop libc detection and worker file watching passed.");
		} finally {
			if (subscription) await subscription.unsubscribe();
			fs.rmSync(directory, { recursive: true });
		}
	})().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
}
