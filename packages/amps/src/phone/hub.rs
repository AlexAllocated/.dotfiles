//! Engine-local PCM fan-out. Each subscriber has an independent bounded queue.
use super::*;
use crossbeam_queue::ArrayQueue;
use std::{
	collections::BTreeMap,
	sync::{atomic::AtomicU64, Weak},
};
pub(crate) struct Hub {
	subscribers: Mutex<BTreeMap<u64, Arc<ArrayQueue<[f32; 2]>>>>,
	next: AtomicU64,
	pub main_gate: Arc<AtomicBool>,
}
pub(crate) struct Subscription {
	id: u64,
	hub: Weak<Hub>,
	pub queue: Arc<ArrayQueue<[f32; 2]>>,
}
impl Drop for Subscription {
	fn drop(&mut self) {
		if let Some(hub) = self.hub.upgrade() {
			hub.subscribers.lock().unwrap().remove(&self.id);
		}
	}
}
impl Hub {
	pub fn new() -> Arc<Self> {
		Arc::new(Self {
			subscribers: Mutex::new(BTreeMap::new()),
			next: AtomicU64::new(0),
			main_gate: Arc::new(AtomicBool::new(false)),
		})
	}
	pub fn subscribe(self: &Arc<Self>) -> Result<Subscription> {
		let mut subscribers = self.subscribers.lock().unwrap();
		let id = self.next.fetch_add(1, Ordering::Relaxed);
		let queue = Arc::new(ArrayQueue::new(44_100));
		subscribers.insert(id, queue.clone());
		Ok(Subscription {
			id,
			hub: Arc::downgrade(self),
			queue,
		})
	}
	pub fn publish(&self, samples: &[f32]) {
		let subscribers = self.subscribers.lock().unwrap();
		for queue in subscribers.values() {
			for frame in samples.chunks_exact(2) {
				let frame = [frame[0], frame[1]];
				if let Err(frame) = queue.push(frame) {
					let _ = queue.pop();
					let _ = queue.push(frame);
				}
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn independent_consumers_keep_stereo_and_release_queues() {
		let hub = Hub::new();
		assert!(!hub.main_gate.load(Ordering::Acquire));
		let a = hub.subscribe().unwrap();
		let b = hub.subscribe().unwrap();
		hub.publish(&[0.25, -0.5, 0.4, -0.2]);
		assert_eq!(a.queue.pop(), Some([0.25, -0.5]));
		assert_eq!(b.queue.len(), 2);
		assert_eq!(b.queue.pop(), Some([0.25, -0.5]));
		drop(a);
		assert_eq!(hub.subscribers.lock().unwrap().len(), 1);
		drop(b);
		assert!(hub.subscribers.lock().unwrap().is_empty());
	}
	#[test]
	fn stalled_output_cannot_block_capture_or_another_output() {
		let hub = Hub::new();
		let stalled = hub.subscribe().unwrap();
		let running = hub.subscribe().unwrap();
		for _ in 0..50_000 {
			hub.publish(&[0.2, -0.2]);
			assert_eq!(running.queue.pop(), Some([0.2, -0.2]));
		}
		assert_eq!(stalled.queue.len(), 44_100);
		assert!(running.queue.is_empty());
	}
}
