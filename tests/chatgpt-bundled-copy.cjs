const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { createRequire } = require("node:module");

async function main() {
	assert.equal(process.argv.length, 3, "Expected exactly one main bundle");
	const bundlePath = path.resolve(process.argv[2]);
	const source = await fs.readFile(bundlePath, "utf8");
	const start = source.indexOf("async function Tne(e,t){");
	const end = source.indexOf("async function vs(e){", start);
	assert(start >= 0 && end > start, "Bundled-plugin copy function must remain identifiable");
	const copy = vm.runInNewContext(`(${source.slice(start, end)})`, {
		P: { default: { platform: "linux" } },
		b: { default: fs },
		require: createRequire(bundlePath)
	});
	const { makeDirectoryWritable } = createRequire(bundlePath)("./bundled-copy.cjs");
	const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "chatgpt-bundled-copy-"));
	const original = path.join(temporary, "source");
	const destination = path.join(temporary, "copy");
	const outside = path.join(temporary, "outside");
	const mode = async (file) => (await fs.stat(file)).mode & 0o777;
	try {
		await fs.mkdir(path.join(original, ".codex-plugin"), { recursive: true });
		await fs.mkdir(outside);
		await fs.writeFile(path.join(outside, "untouched"), "outside");
		await fs.writeFile(path.join(original, ".codex-plugin/plugin.json"), '{"name":"visualize"}');
		await fs.writeFile(path.join(original, ".mcp.json"), '{}');
		await fs.writeFile(path.join(original, "executable"), "#!/bin/sh\n");
		await fs.symlink(outside, path.join(original, "external-directory"));
		await fs.symlink(path.join(outside, "untouched"), path.join(original, "external-file"));
		await fs.symlink(".codex-plugin/plugin.json", path.join(original, "internal-file"));
		await fs.symlink("missing", path.join(original, "dangling"));
		for (const file of [path.join(original, ".codex-plugin/plugin.json"), path.join(original, ".mcp.json"), path.join(outside, "untouched")]) {
			await fs.chmod(file, 0o444);
		}
		for (const file of [original, path.join(original, ".codex-plugin"), path.join(original, "executable"), outside]) {
			await fs.chmod(file, 0o555);
		}

		// Prove the original behavior reproduces the permission bug as an ordinary user.
		const control = path.join(temporary, "unpatched-copy");
		await fs.cp(original, control, { recursive: true, verbatimSymlinks: true });
		assert.equal(await mode(path.join(control, ".codex-plugin/plugin.json")), 0o444);
		if (process.getuid() !== 0) {
			await assert.rejects(fs.writeFile(path.join(control, ".codex-plugin/plugin.json"), "rewritten"), { code: "EACCES" });
			await assert.rejects(fs.rm(control, { recursive: true }), { code: "EACCES" });
		}
		await makeDirectoryWritable(control);
		await fs.rm(control, { recursive: true });

		await copy(original, destination);
		assert.equal(await mode(destination), 0o755);
		assert.equal(await mode(path.join(destination, ".codex-plugin")), 0o755);
		assert.equal(await mode(path.join(destination, ".codex-plugin/plugin.json")), 0o644);
		assert.equal(await mode(path.join(destination, "executable")), 0o755);
		await fs.writeFile(path.join(destination, ".codex-plugin/plugin.json"), '{"name":"visualize","patched":true}');
		for (const name of ["external-directory", "external-file", "internal-file", "dangling"]) {
			assert.equal(await fs.readlink(path.join(destination, name)), await fs.readlink(path.join(original, name)));
		}
		assert.equal(await mode(original), 0o555);
		assert.equal(await mode(path.join(original, ".codex-plugin")), 0o555);
		assert.equal(await mode(path.join(original, ".codex-plugin/plugin.json")), 0o444);
		assert.equal(await fs.readFile(path.join(original, ".codex-plugin/plugin.json"), "utf8"), '{"name":"visualize"}');
		assert.equal(await mode(outside), 0o555);
		assert.equal(await mode(path.join(outside, "untouched")), 0o444);
		assert.equal(await fs.readFile(path.join(outside, "untouched"), "utf8"), "outside");
		await fs.rm(destination, { recursive: true });
		await assert.rejects(fs.stat(destination), { code: "ENOENT" });

		// Copy failures must keep their original error and never chmod an old target.
		const failedDestination = path.join(temporary, "failed-copy");
		await fs.mkdir(failedDestination);
		await fs.chmod(failedDestination, 0o555);
		await assert.rejects(copy(path.join(temporary, "missing"), failedDestination), { code: "ENOENT" });
		assert.equal(await mode(failedDestination), 0o555);
		await fs.chmod(failedDestination, 0o755);

		// The executor uses a separate copy path, then rewrites .mcp.json.
		// Also recover runtime directories left read-only by an older build.
		const executorStart = source.indexOf("async function Yc(");
		const executorEnd = source.indexOf("async function Xc(", executorStart);
		assert(executorStart >= 0 && executorEnd > executorStart);
		const executorSource = path.join(temporary, "executor-source");
		await fs.mkdir(path.join(executorSource, ".codex-plugin"), { recursive: true });
		for (const name of [".mcp.json", ".codex-plugin/plugin.json", "executable"]) {
			await fs.copyFile(path.join(original, name), path.join(executorSource, name));
			await fs.chmod(path.join(executorSource, name), 0o444);
		}
		await fs.chmod(path.join(executorSource, ".codex-plugin"), 0o555);
		await fs.chmod(executorSource, 0o555);
		const executorCopy = vm.runInNewContext(`(${source.slice(executorStart, executorEnd)})`, {
			Zc: async () => ({ cwd: executorSource, command: path.join(executorSource, "executable") }),
			b: { default: fs },
			S: { default: path },
			r: { An: "test-host" },
			process: { platform: "linux" },
			require: createRequire(bundlePath)
		});
		const executorRoot = path.join(temporary, "executor");
		await fs.cp(executorSource, executorRoot, { recursive: true, verbatimSymlinks: true });
		for (let attempt = 0; attempt < 2; attempt++) {
			assert.equal(await executorCopy({ executorPluginRoot: executorRoot }), executorRoot);
			const definition = JSON.parse(await fs.readFile(path.join(executorRoot, ".mcp.json"), "utf8"));
			assert.equal(definition.mcpServers.codex_app.cwd, executorRoot);
			assert.equal(definition.mcpServers.codex_app.env.CODEX_APP_TOOLS_CALLER_HOST_ID, "test-host");
			assert.equal(await mode(path.join(executorRoot, ".mcp.json")), 0o644);
		}
		assert.equal(await mode(path.join(original, ".mcp.json")), 0o444);

		const linkedRoot = path.join(temporary, "linked-root");
		await fs.symlink(outside, linkedRoot);
		await assert.rejects(makeDirectoryWritable(linkedRoot));
		assert.equal(await mode(outside), 0o555);
		console.log("Desktop bundled-plugin copy: read-only source, rewrite, cleanup, symlink boundaries, and copy failure passed.");
	} finally {
		// Test fixture cleanup deliberately includes the read-only source and sentinel.
		await makeDirectoryWritable(temporary);
		await fs.rm(temporary, { recursive: true });
	}
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
