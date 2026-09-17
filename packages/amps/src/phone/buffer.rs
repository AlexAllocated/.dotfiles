//! Bounded phone-only jitter reservoir. No samples are persisted.
use std::collections::VecDeque;

pub(super) const RATE: usize = 44_100;
const FADE: f32 = (RATE / 200) as f32;

const MAX_CORRECTION: f64 = 0.02;
const MAX_SLEW_PER_SECOND: f64 = 0.002;

/// Queue-depth PI servo for independent input/output clocks. The integral learns
/// sustained skew; the proportional term restores the reservoir after jitter.
/// Time is measured in output frames, not callback count or wall-clock wakes.
struct Drift {
	filtered_error: f64,
	integral: f64,
	ratio: f64,
	limited: bool,
}
impl Drift {
	fn new() -> Self {
		Self {
			filtered_error: 0.0,
			integral: 0.0,
			ratio: 1.0,
			limited: false,
		}
	}
	fn rebase(&mut self) {
		// A pause, refill, or buffer-size change is not a new clock estimate.
		// Keep the learned skew, but discard the transient queue error.
		self.filtered_error = 0.0;
		self.limited = false;
	}
	fn update(&mut self, queued: usize, target: usize, rendered: usize) {
		if rendered == 0 {
			return;
		}
		let dt = rendered as f64 / RATE as f64;
		let error = (queued as f64 - target as f64) / RATE as f64;
		// Half-second low-pass rejects Bluetooth packet-batch sawtooth. Use seconds
		// of queue error so changing buffer size does not weaken drift correction.
		self.filtered_error += (1.0 - (-dt / 0.5).exp()) * (error - self.filtered_error);
		let proportional = 0.25 * self.filtered_error;
		let candidate =
			(self.integral + 0.015 * self.filtered_error * dt).clamp(-MAX_CORRECTION, MAX_CORRECTION);
		let demand = candidate + proportional;
		// Anti-windup: don't integrate further into a saturated rate limit.
		if demand.abs() <= MAX_CORRECTION
			|| (demand > MAX_CORRECTION && self.filtered_error < 0.0)
			|| (demand < -MAX_CORRECTION && self.filtered_error > 0.0)
		{
			self.integral = candidate;
		}
		let demand = self.integral + proportional;
		self.limited = demand.abs() > MAX_CORRECTION;
		let wanted = 1.0 + demand.clamp(-MAX_CORRECTION, MAX_CORRECTION);
		let step = MAX_SLEW_PER_SECOND * dt;
		self.ratio += (wanted - self.ratio).clamp(-step, step);
	}
}

pub(super) struct Buffer {
	frames: VecDeque<[f32; 2]>,
	target: usize,
	primed: bool,
	phase: f64,
	drift: Drift,
	gain: f32,
	last: [f32; 2],
	pub received: u64,
	pub underruns: u64,
	pub overruns: u64,
}
impl Buffer {
	pub fn new(buffer_ms: u32) -> Self {
		Self {
			frames: VecDeque::with_capacity(RATE),
			target: RATE * buffer_ms.clamp(50, 500) as usize / 1000,
			primed: false,
			phase: 0.0,
			drift: Drift::new(),
			gain: 0.0,
			last: [0.0; 2],
			received: 0,
			underruns: 0,
			overruns: 0,
		}
	}
	pub fn set_target(&mut self, buffer_ms: u32) {
		let target = RATE * buffer_ms.clamp(50, 500) as usize / 1000;
		if target != self.target {
			self.target = target;
			// Only the phone queue reprimes; physical streams and Bluetooth stay open.
			self.frames.clear();
			self.primed = false;
			self.phase = 0.0;
			self.drift.rebase();
		}
	}
	pub fn push(&mut self, samples: &[f32]) {
		for pair in samples.chunks_exact(2) {
			self
				.frames
				.push_back([sanitize(pair[0]), sanitize(pair[1])]);
			self.received += 1;
		}
		if self.frames.len() > RATE {
			self.frames.drain(..self.frames.len() - self.target);
			self.primed = false;
			self.phase = 0.0;
			self.drift.rebase();
			self.overruns += 1;
		}
	}
	#[cfg(test)]
	pub fn queued_ms(&self) -> usize {
		self.frames.len() * 1000 / RATE
	}
	#[cfg(test)]
	pub fn resample_ratio(&self) -> f64 {
		self.drift.ratio
	}
	#[cfg(test)]
	pub fn clock_correction_ppm(&self) -> f64 {
		self.drift.integral * 1_000_000.0
	}
	#[cfg(test)]
	pub fn drift_limited(&self) -> bool {
		self.drift.limited
	}
	pub fn render(&mut self, output: &mut [f32], tail: bool) {
		if !self.primed
			&& (self.frames.len() >= self.target + output.len() / 2 + 2
				|| (tail && !self.frames.is_empty()))
		{
			self.primed = true;
			self.phase = 0.0;
			self.gain = 0.0;
		}
		for pair in output.chunks_exact_mut(2) {
			if self.primed && (self.frames.len() >= 2 || (tail && !self.frames.is_empty())) {
				let a = self.frames[0];
				let b = self.frames.get(1).copied().unwrap_or(a);
				self.gain = (self.gain + 1.0 / FADE).min(1.0);
				for ch in 0..2 {
					self.last[ch] = a[ch] + (b[ch] - a[ch]) * self.phase as f32;
					pair[ch] = self.last[ch] * self.gain;
				}
				self.phase += self.drift.ratio;
				while self.phase >= 1.0 {
					self.frames.pop_front();
					self.phase -= 1.0;
				}
			} else {
				if self.primed {
					self.primed = false;
					if !tail {
						self.underruns += 1;
					}
				}
				self.gain = (self.gain - 1.0 / FADE).max(0.0);
				for ch in 0..2 {
					pair[ch] = self.last[ch] * self.gain;
				}
			}
		}
		if self.primed && !tail {
			// Observe the reservoir after consumption, excluding the variable-sized
			// block just handed to WASAPI. Keep fractional sample phase continuous.
			self
				.drift
				.update(self.frames.len(), self.target, output.len() / 2);
		} else {
			self.drift.rebase();
		}
	}
}
fn sanitize(value: f32) -> f32 {
	if value.is_finite() {
		value.clamp(-1.0, 1.0)
	} else {
		0.0
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	const TARGET: usize = RATE / 5;
	#[test]
	fn prefill_then_absorb_a_hundred_ms_gap() {
		let mut b = Buffer::new(200);
		let mut out = vec![0.0; 882];
		b.push(&vec![0.4; 882]);
		b.render(&mut out, false);
		assert!(out.iter().all(|v| *v == 0.0));
		b.push(&vec![0.4; TARGET * 2 + 4]);
		b.render(&mut out, false);
		for _ in 0..10 {
			b.render(&mut out, false);
		}
		assert_eq!(b.underruns, 0);
		assert!(out.iter().all(|v| *v > 0.3));
	}
	#[test]
	fn short_notifications_flush_and_long_gap_fades_to_silence() {
		let mut b = Buffer::new(200);
		b.push(&vec![0.5; 882]);
		let mut out = vec![0.0; 2000];
		b.render(&mut out, true);
		assert!(out.iter().any(|v| *v > 0.4));
		assert_eq!(*out.last().unwrap(), 0.0);
		assert_eq!(b.underruns, 0);
	}
	#[test]
	fn bounded_finite_and_stereo_aligned() {
		let mut b = Buffer::new(200);
		b.push(&vec![f32::NAN; RATE * 3]);
		assert_eq!(b.overruns, 1);
		assert!(b.queued_ms() <= 200);
		let mut out = vec![0.0; 1000];
		b.render(&mut out, true);
		assert!(out.iter().all(|v| *v == 0.0));
	}
	#[test]
	fn long_run_clock_drift_is_bounded_without_periodic_cuts() {
		let mut b = Buffer::new(200);
		b.push(&vec![0.4; (TARGET + 882) * 2]);
		let mut out = vec![0.0; 882];
		for n in 0..30_000 {
			b.push(&vec![0.4; if n % 10 == 0 { 884 } else { 882 }]);
			b.render(&mut out, false);
		}
		assert_eq!((b.underruns, b.overruns), (0, 0));
		assert!((150..300).contains(&b.queued_ms()));
	}
	#[test]
	fn sustained_slower_phone_does_not_drain_reservoir() {
		// Reproduce the measured ~0.57% shortfall: 441 output frames per tick,
		// but only 438/439 input frames. A larger queue alone merely delays failure.
		let mut b = Buffer::new(500);
		b.push(&vec![0.4; (RATE / 2 + 442) * 2]);
		let input = vec![0.4; 439 * 2];
		let mut out = vec![0.0; 882];
		for tick in 0..30_000 {
			b.push(&input[..if tick % 2 == 0 { 438 * 2 } else { 439 * 2 }]);
			b.render(&mut out, false);
		}
		assert_eq!((b.underruns, b.overruns), (0, 0));
		assert!((460..540).contains(&b.queued_ms()), "{} ms", b.queued_ms());
		assert!((b.resample_ratio() - 438.5 / 441.0).abs() < 0.00002);
		assert!((b.clock_correction_ppm() + 5668.934).abs() < 20.0);
		assert!(!b.drift_limited());
	}
	#[test]
	fn clock_servo_soaks_both_directions_and_variable_callback_sizes() {
		// Exercise thirty simulated minutes per combination without generating
		// gigabytes of identical PCM. The full Buffer regression above covers PCM.
		for ms in [50, 100, 200, 500] {
			for input_ratio in [0.99, 0.9943, 1.0, 1.0057, 1.01] {
				let target = RATE * ms / 1000;
				let mut queued = target as f64;
				let mut drift = Drift::new();
				let mut elapsed = 0.0;
				let mut tick = 0;
				while elapsed < 1800.0 {
					let frames = [128, 441, 960][tick % 3];
					let dt = frames as f64 / RATE as f64;
					queued += frames as f64 * (input_ratio - drift.ratio);
					assert!(
						queued > 2.0 && queued < RATE as f64,
						"ms={ms}, ratio={input_ratio}, t={elapsed}, queued={queued}"
					);
					let previous = drift.ratio;
					drift.update(queued as usize, target, frames);
					assert!((drift.ratio - previous).abs() <= MAX_SLEW_PER_SECOND * dt + 1e-12);
					assert!((1.0 - MAX_CORRECTION..=1.0 + MAX_CORRECTION).contains(&drift.ratio));
					elapsed += dt;
					tick += 1;
				}
				assert!((queued - target as f64).abs() < 3.0 * RATE as f64 / 1000.0);
				assert!((drift.ratio - input_ratio).abs() < 0.00002);
			}
		}
	}
	#[test]
	fn clock_servo_tracks_changing_skew_and_rejects_packet_bursts() {
		let target = RATE / 5;
		let mut queued = target as f64;
		let mut drift = Drift::new();
		let mut pending = 0.0;
		for tick in 0..90_000 {
			let input_ratio = [0.9943, 1.006, 0.997][tick / 30_000];
			pending += 441.0 * input_ratio;
			// Bluetooth delivers 40 ms at once; render consumes 10 ms at a time.
			if tick % 4 == 0 {
				queued += pending;
				pending = 0.0;
			}
			queued -= 441.0 * drift.ratio;
			assert!(queued > RATE as f64 * 0.1 && queued < RATE as f64 * 0.3);
			drift.update(queued as usize, target, 441);
			if tick % 30_000 > 25_000 {
				assert!((drift.ratio - input_ratio).abs() < 0.0001);
			}
		}
	}
	#[test]
	fn pause_and_buffer_change_do_not_erase_or_wind_up_clock_estimate() {
		let mut b = Buffer::new(200);
		b.drift.integral = -0.0057;
		b.drift.ratio = 0.9943;
		b.drift.filtered_error = 0.1;
		let mut out = vec![0.0; 882];
		for _ in 0..1000 {
			b.render(&mut out, true);
		}
		b.set_target(500);
		assert_eq!(b.drift.integral, -0.0057);
		assert_eq!(b.drift.ratio, 0.9943);
		assert_eq!(b.drift.filtered_error, 0.0);
		assert_eq!(b.underruns, 0);
		b.push(&vec![0.3; (RATE / 2 + 443) * 2]);
		b.render(&mut out, false);
		assert!(b.primed);
		assert!(out.last().unwrap() > &0.29);
	}
	#[test]
	fn correction_saturates_safely_without_integral_windup() {
		let mut drift = Drift::new();
		for _ in 0..10_000 {
			drift.update(RATE, RATE / 5, 441);
		}
		assert!(drift.limited);
		assert!((drift.ratio - 1.02).abs() < 1e-9);
		assert!(drift.integral.abs() < 0.001);
		drift.rebase();
		for _ in 0..10_000 {
			drift.update(0, RATE / 5, 441);
		}
		assert!(drift.limited);
		assert!((drift.ratio - 0.98).abs() < 1e-9);
		assert!(drift.integral.abs() < 0.001);
	}
	#[test]
	fn resampling_keeps_stereo_and_waveform_continuous() {
		let mut b = Buffer::new(200);
		let mut source_frame = 0usize;
		let mut source = |frames: usize| -> Vec<f32> {
			let mut samples = Vec::with_capacity(frames * 2);
			for _ in 0..frames {
				let wave = (source_frame as f64 * std::f64::consts::TAU * 440.0 / RATE as f64).sin()
					as f32 * 0.4;
				samples.extend([wave, -wave * 0.75]);
				source_frame += 1;
			}
			samples
		};
		b.push(&source(TARGET + 443));
		let mut out = vec![0.0; 882];
		let mut last = 0.0f32;
		for tick in 0..6000 {
			b.push(&source(if tick % 2 == 0 { 438 } else { 439 }));
			b.render(&mut out, false);
			for pair in out.chunks_exact(2) {
				assert!((pair[0] - last).abs() < 0.04, "discontinuous interpolation");
				assert!(
					(pair[1] + pair[0] * 0.75).abs() < 1e-6,
					"stereo channels misaligned"
				);
				last = pair[0];
			}
		}
		assert_eq!((b.underruns, b.overruns), (0, 0));
	}
	#[test]
	fn changing_delay_rebuffers_only_local_queue() {
		let mut b = Buffer::new(100);
		b.push(&vec![0.2; RATE / 2]);
		b.set_target(300);
		assert_eq!(b.queued_ms(), 0);
		assert_eq!(b.target, RATE * 3 / 10);
		assert_eq!((b.underruns, b.overruns), (0, 0));
	}
}
