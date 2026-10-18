//! Phone-only readiness and retry policy. Silence is not a failed connection.
use std::time::Duration;

pub(super) const ENDPOINT_GRACE: Duration = Duration::from_secs(10);
const STABLE_CONNECTION: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RetryComponent {
	Registration,
	Capture,
}
impl RetryComponent {
	pub fn withdraws_receiver(self) -> bool {
		self == Self::Registration
	}
	pub fn name(self) -> &'static str {
		match self {
			Self::Registration => "receiver registration",
			Self::Capture => "audio capture",
		}
	}
}

#[derive(Default)]
pub(super) struct EndpointWatch {
	inactive_since: Option<Duration>,
}
impl EndpointWatch {
	/// An inactive endpoint is ambiguous (idle or stalled). This is diagnostic
	/// only: never withdraw the Bluetooth receiver just because it stays idle.
	pub fn observe(&mut self, now: Duration, active: bool) -> bool {
		if active {
			self.inactive_since = None;
			return false;
		}
		let since = *self.inactive_since.get_or_insert(now);
		now.saturating_sub(since) >= ENDPOINT_GRACE
	}
}

#[derive(Default)]
pub(super) struct RetryBackoff {
	failures: u32,
	healthy_since: Option<Duration>,
}
impl RetryBackoff {
	pub fn failed(&mut self) -> Duration {
		self.healthy_since = None;
		let seconds = [2, 5, 15, 30, 60][self.failures.min(4) as usize];
		self.failures = self.failures.saturating_add(1);
		Duration::from_secs(seconds)
	}
	pub fn observe(&mut self, now: Duration, ready: bool) {
		if !ready {
			self.healthy_since = None;
			return;
		}
		let since = *self.healthy_since.get_or_insert(now);
		if now.saturating_sub(since) >= STABLE_CONNECTION {
			self.failures = 0;
		}
	}
	pub fn reset(&mut self) {
		*self = Self::default();
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn capture_retries_never_withdraw_bluetooth_availability() {
		let mut retry = RetryBackoff::default();
		for _ in 0..100 {
			assert!(!RetryComponent::Capture.withdraws_receiver());
			assert!(retry.failed() <= Duration::from_secs(60));
		}
		assert!(RetryComponent::Registration.withdraws_receiver());
		assert_eq!(RetryComponent::Capture.name(), "audio capture");
	}
	#[test]
	fn inactive_endpoint_becomes_diagnostic_not_a_disconnect_request() {
		let mut watch = EndpointWatch::default();
		assert!(!watch.observe(Duration::ZERO, false));
		assert!(!watch.observe(ENDPOINT_GRACE - Duration::from_millis(1), false));
		assert!(watch.observe(ENDPOINT_GRACE, false));
	}
	#[test]
	fn settling_and_later_disconnect_receive_separate_grace_periods() {
		let mut watch = EndpointWatch::default();
		assert!(!watch.observe(Duration::ZERO, false));
		assert!(!watch.observe(Duration::from_secs(9), true));
		assert!(!watch.observe(Duration::from_secs(100), false));
		assert!(watch.observe(Duration::from_secs(110), false));
		assert!(!watch.observe(Duration::from_secs(111), true));
	}
	#[test]
	fn active_endpoint_never_reconnects_for_paused_or_silent_audio() {
		let mut watch = EndpointWatch::default();
		// No PCM/peak or playback timer is consulted, even after hours of silence.
		for seconds in [0, 10, 60, 3600, 86400] {
			assert!(!watch.observe(Duration::from_secs(seconds), true));
		}
	}
	#[test]
	fn retries_back_off_and_short_lived_connections_do_not_reset_them() {
		let mut retry = RetryBackoff::default();
		for seconds in [2, 5, 15, 30, 60, 60] {
			assert_eq!(retry.failed(), Duration::from_secs(seconds));
			retry.observe(Duration::ZERO, true);
			retry.observe(Duration::from_secs(29), true);
		}
		retry.observe(Duration::from_secs(30), true);
		assert_eq!(retry.failed(), Duration::from_secs(2));
	}
	#[test]
	fn interruption_resets_stability_not_the_retry_budget() {
		let mut retry = RetryBackoff::default();
		assert_eq!(retry.failed(), Duration::from_secs(2));
		retry.observe(Duration::ZERO, true);
		retry.observe(Duration::from_secs(20), false);
		retry.observe(Duration::from_secs(30), true);
		assert_eq!(retry.failed(), Duration::from_secs(5));
		retry.reset();
		assert_eq!(retry.failed(), Duration::from_secs(2));
	}
}
