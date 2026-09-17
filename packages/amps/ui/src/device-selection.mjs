const bounded = (operation, ms, schedule, cancel) =>
	new Promise((resolve, reject) => {
		const timer = schedule(
			() => reject(new Error("Device request timed out; controls are available to retry.")),
			ms
		);
		Promise.resolve()
			.then(operation)
			.then(resolve, reject)
			.finally(() => cancel(timer));
	});

// A saved preference is not an applied device. Confirm the engine's actual
// binding, and always release the selector even if a native request gets stuck.
export async function selectDevice({
	direction,
	id,
	name,
	invoke,
	refresh,
	now = () => performance.now(),
	timeout = 10000,
	schedule = (fn, ms) => setTimeout(fn, ms),
	cancel = timer => clearTimeout(timer),
	sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
}) {
	const deadline = now() + timeout;
	await bounded(
		() => invoke(`select_main_${direction}`, { endpointId: id }),
		timeout,
		schedule,
		cancel
	);
	let actual = "unknown";
	while (now() < deadline) {
		const snapshot = await bounded(refresh, deadline - now(), schedule, cancel);
		actual = snapshot?.runtime?.[direction === "input" ? "inputName" : "outputName"] ?? "unknown";
		if (snapshot?.runtime?.online && actual.toLowerCase() === name.toLowerCase()) return snapshot;
		await sleep(Math.min(250, Math.max(0, deadline - now())));
	}
	throw new Error(
		`Could not confirm ${name} as Main ${direction}. Active device: ${actual}. Your preference is saved; you can retry or select another device.`
	);
}
