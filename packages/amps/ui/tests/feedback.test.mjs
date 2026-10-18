import test from "node:test";
import assert from "node:assert/strict";
import { createFeedback, clips } from "../src/feedback.mjs";

function harness(muted = false) {
	const played = [];
	let clock = 0;
	let timerId = 0;
	const timers = new Map();
	const feedback = createFeedback({
		muted,
		now: () => clock,
		schedule: (fn, ms) => {
			const id = ++timerId;
			timers.set(id, { fn, at: clock + ms });
			return id;
		},
		cancel: id => timers.delete(id),
		createAudio: src => {
			const audio = {
				src,
				paused: false,
				pause() {
					this.paused = true;
				},
				async play() {
					played.push(this);
				}
			};
			return audio;
		}
	});
	return {
		feedback,
		played,
		timers,
		advance: ms => {
			const until = clock + ms;
			for (;;) {
				const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
				if (!next || next[1].at > until) break;
				clock = next[1].at;
				timers.delete(next[0]);
				next[1].fn();
			}
			clock = until;
		}
	};
}
test("all feedback is mapped to existing Trek clips, never a background hum", () => {
	const { feedback, played } = harness();
	for (const clip of clips) assert(feedback.play(clip));
	assert.equal(feedback.play("hum"), false);
	assert.equal(played.length, clips.length);
	assert(played.every(audio => audio.volume === 0.2));
});
test("mute stops current clips and suppresses delayed acknowledgements and native events", () => {
	const { feedback, played, advance } = harness();
	feedback.play("search");
	feedback.setMuted(true);
	advance(5000);
	assert.equal(feedback.play("confirm"), false);
	assert.equal(feedback.play("key-02"), false);
	assert(played[0].paused);
	feedback.setMuted(false);
	assert(feedback.play("intrepid-key"));
});
test("scroll and slider events extend one scanning voice, then fade it out", () => {
	const { feedback, played, advance } = harness();
	assert(feedback.motion());
	for (let i = 0; i < 100; i++) {
		advance(40);
		assert(feedback.motion());
	}
	assert.equal(played.length, 1, "Movement must not restart the audio");
	assert(played[0].src.endsWith("search.mp3"));
	assert.equal(played[0].loop, true);
	assert.equal(played[0].volume, 0.06);
	assert.equal(played[0].paused, false);
	advance(180 + 32);
	assert(played[0].volume > 0 && played[0].volume < 0.06);
	advance(48);
	assert(played[0].paused);
	assert.equal(played[0].volume, 0);
});
test("held drags outlast the clip and confirmations never interrupt them", () => {
	const { feedback, played, advance, timers } = harness();
	assert(feedback.beginMotion());
	advance(10000);
	assert.equal(played[0].paused, false);
	assert(feedback.play("confirm"));
	assert(feedback.play("denied"));
	assert(feedback.play("key-02"));
	assert.equal(played[0].paused, false);
	assert(played[1].paused, "Discrete clips retain their concurrency limit");
	feedback.endMotion();
	advance(80);
	assert(played[0].paused);
	assert.equal(timers.size, 0);
});
test("resuming during fade continues the same clip without stale timers stopping it", () => {
	const { feedback, played, advance } = harness();
	feedback.motion();
	advance(212);
	feedback.motion();
	assert.equal(played.length, 1);
	assert.equal(played[0].volume, 0.06);
	advance(100);
	assert.equal(played[0].paused, false);
	advance(160);
	assert(played[0].paused);
});
test("mute and cleanup immediately stop gestures and remove all scheduled work", () => {
	const { feedback, played, advance, timers } = harness();
	feedback.motion();
	feedback.setMuted(true);
	assert(played[0].paused);
	assert.equal(timers.size, 0);
	assert.equal(feedback.motion(), false);
	assert.equal(feedback.beginMotion(), false);
	advance(5000);
	assert.equal(played.length, 1);
	feedback.setMuted(false);
	feedback.beginMotion();
	feedback.endMotion();
	feedback.stop();
	assert(played[1].paused);
	assert.equal(timers.size, 0);
});
test("playback rejection releases the gesture voice and can be retried", async () => {
	const { feedback, played, timers } = harness();
	feedback.motion();
	played[0].onerror();
	assert.equal(timers.size, 0);
	assert(played[0].paused);
	feedback.motion();
	assert.equal(played.length, 2);
	feedback.stop();
});
test("duplicate bubbled clicks produce only one sound and saved mute starts silent", () => {
	const { feedback, played } = harness(true);
	assert.equal(feedback.play(), false);
	feedback.setMuted(false);
	assert(feedback.play());
	assert.equal(feedback.play(), false);
	assert.equal(played.length, 1);
});
