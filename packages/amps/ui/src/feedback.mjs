// User-action feedback only: telemetry and automatic layout never call this.
export const clips = ["intrepid-key", "key-02", "search", "confirm", "denied"];

export function createFeedback({
	muted = false,
	createAudio = src => new Audio(src),
	now = () => performance.now(),
	schedule = (fn, ms) => setTimeout(fn, ms),
	cancel = timer => clearTimeout(timer)
} = {}) {
	const playing = new Set();
	const last = new Map();
	let motionAudio = null,
		motionTimer = null,
		motionHeld = false;
	const cancelMotionTimer = () => {
		if (motionTimer !== null) cancel(motionTimer);
		motionTimer = null;
	};
	const stopMotion = () => {
		cancelMotionTimer();
		motionHeld = false;
		motionAudio?.pause();
		motionAudio = null;
	};
	const fadeMotion = () => {
		cancelMotionTimer();
		const audio = motionAudio;
		if (!audio) return;
		const started = now(),
			volume = audio.volume;
		const tick = () => {
			if (motionAudio !== audio) return;
			const remaining = Math.max(0, 1 - (now() - started) / 80);
			audio.volume = volume * remaining;
			if (remaining === 0) stopMotion();
			else motionTimer = schedule(tick, 16);
		};
		motionTimer = schedule(tick, 16);
	};
	// One scanning voice spans a gesture. Events extend it, never restart the clip.
	const motion = () => {
		if (muted) return false;
		cancelMotionTimer();
		if (!motionAudio) {
			const audio = createAudio("./audio/search.mp3");
			motionAudio = audio;
			audio.loop = true;
			audio.volume = 0.06;
			const failed = () => {
				if (motionAudio === audio) stopMotion();
			};
			audio.onerror = failed;
			void audio.play().catch(failed);
		}
		motionAudio.volume = 0.06;
		if (!motionHeld) motionTimer = schedule(fadeMotion, 180);
		return true;
	};
	const stop = () => {
		stopMotion();
		for (const audio of playing) audio.pause();
		playing.clear();
	};
	return {
		setMuted(value) {
			muted = value;
			if (muted) stop();
		},
		motion,
		beginMotion() {
			if (muted) return false;
			motionHeld = true;
			return motion();
		},
		endMotion() {
			motionHeld = false;
			fadeMotion();
		},
		play(name = "intrepid-key") {
			if (muted || !clips.includes(name)) return false;
			const time = now();
			if (time - (last.get(name) ?? -Infinity) < 65) return false;
			last.set(name, time);
			// Never accumulate a chorus during a slider drag or repeated keypresses.
			if (playing.size >= 2) {
				const oldest = playing.values().next().value;
				oldest.pause();
				playing.delete(oldest);
			}
			const audio = createAudio(`./audio/${name}.mp3`);
			audio.volume = 0.2;
			playing.add(audio);
			audio.onended = audio.onerror = () => playing.delete(audio);
			void audio.play().catch(() => playing.delete(audio));
			return true;
		},
		stop
	};
}

// Delegation also covers new inspector controls and React Flow's own buttons.
export function installInteractionFeedback(root, feedback) {
	let keyboardFocus = false;
	const element = event =>
		event.target?.closest?.(
			"button,a[href],select,input,textarea,[role=button],.react-flow__edge,.react-flow__pane"
		);
	const available = target =>
		target &&
		!target.matches(":disabled,[aria-disabled=true]") &&
		!target.closest("[data-feedback=manual]");
	const handlers = {
		pointerdown(event) {
			keyboardFocus = false;
			const target = element(event);
			if (available(target) && target.matches("select")) feedback.play("search");
		},
		click(event) {
			const target = element(event);
			if (!available(target) || target.matches("select,input,textarea")) return;
			if (target.matches(".react-flow__controls-zoomin,.react-flow__controls-zoomout")) {
				feedback.motion();
				return;
			}
			feedback.play("intrepid-key");
		},
		change(event) {
			const target = element(event);
			if (available(target) && target.matches("select,input[type=checkbox],input[type=radio]"))
				feedback.play("key-02");
		},
		input(event) {
			const target = element(event);
			if (
				available(target) &&
				target.matches("input,textarea") &&
				!target.matches("[type=checkbox],[type=radio]")
			)
				if (target.matches("input[type=range]")) feedback.motion();
				else feedback.play("key-02");
		},
		keydown(event) {
			keyboardFocus = event.key === "Tab";
			if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z")
				feedback.play("key-02");
			const target = element(event);
			if (
				available(target) &&
				target.matches("select") &&
				["Enter", " ", "ArrowDown", "ArrowUp"].includes(event.key)
			)
				feedback.play("key-02");
			if (
				event.target?.closest?.(".react-flow") &&
				[
					"Delete",
					"Backspace",
					"Escape",
					"ArrowLeft",
					"ArrowRight",
					"ArrowUp",
					"ArrowDown"
				].includes(event.key)
			)
				if (event.key.startsWith("Arrow")) feedback.motion();
				else feedback.play("key-02");
		},
		focusin(event) {
			if (keyboardFocus && available(element(event))) feedback.play("key-02");
		},
		wheel(event) {
			if (event.target?.closest?.(".inspector")) feedback.motion();
		}
	};
	const window = root.ownerDocument.defaultView;
	const document = root.ownerDocument;
	const hidden = () => {
		if (document.hidden) feedback.stop();
	};
	// Pointer cancellation or switching windows must not strand a looping voice.
	window.addEventListener("pointerup", feedback.endMotion);
	window.addEventListener("pointercancel", feedback.endMotion);
	window.addEventListener("blur", feedback.stop);
	document.addEventListener("visibilitychange", hidden);
	for (const [name, handler] of Object.entries(handlers))
		root.addEventListener(name, handler, { capture: true, passive: true });
	return () => {
		window.removeEventListener("pointerup", feedback.endMotion);
		window.removeEventListener("pointercancel", feedback.endMotion);
		window.removeEventListener("blur", feedback.stop);
		document.removeEventListener("visibilitychange", hidden);
		feedback.stop();
		for (const [name, handler] of Object.entries(handlers))
			root.removeEventListener(name, handler, true);
	};
}
