// Nix store permissions survive fs.cp. Only the private staging copy is mutable.
const fs = require("node:fs/promises");
const { constants } = require("node:fs");

async function makeDirectoryWritable(directory) {
	const handle = await fs.open(
		directory,
		constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW
	);
	try {
		await makeHandleWritable(handle);
	} finally {
		await handle.close();
	}
}

async function makeHandleWritable(handle) {
	const stat = await handle.stat();
	if (!stat.isDirectory() && !stat.isFile()) {
		throw new Error("Unexpected file type in bundled plugin staging copy");
	}
	await handle.chmod((stat.mode & 0o7777) | 0o200);
	if (!stat.isDirectory()) return;

	// Linux fd paths pin the parent even if it is renamed during traversal.
	// O_NOFOLLOW on every child prevents chmod from following a substituted link.
	const parent = `/proc/self/fd/${handle.fd}`;
	for (const entry of await fs.readdir(parent, { withFileTypes: true })) {
		if (entry.isSymbolicLink()) continue;
		const child = await fs.open(
			`${parent}/${entry.name}`,
			constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK
		);
		try {
			await makeHandleWritable(child);
		} finally {
			await child.close();
		}
	}
}

module.exports = { makeDirectoryWritable };
