"""Publish Wine's XRandR source order from real output IDs, without input polling."""
import fcntl
import os
from pathlib import Path
import select
import threading


def source_order(outputs, primary):
	# Wine ignores disconnected outputs and mirrored replicas with higher IDs,
	# then swaps the primary adapter into slot zero.
	active = [o for o in outputs if o["connected"] and o["geometry"]]
	lowest = {}
	for output in active:
		geometry = output["geometry"]
		lowest[geometry] = min(lowest.get(geometry, output["id"]), output["id"])
	ordered = [o for o in active if o["id"] == lowest[o["geometry"]]]
	primary_geometry = next((o["geometry"] for o in active if o["id"] == primary), None)
	if primary_geometry is None:
		primary_geometry = next((o["geometry"] for o in ordered if o["geometry"][:2] == (0, 0)), None)
	index = next((i for i, o in enumerate(ordered) if o["geometry"] == primary_geometry), 0)
	if ordered:
		ordered[0], ordered[index] = ordered[index], ordered[0]
	return [o["id"] for o in ordered]


def source_plan(outputs, primary):
	ordered = source_order(outputs, primary)
	# The Wine reader consumes the count and IDs. Geometry also belongs in the
	# notification fingerprint: moving an existing output must wake the helper.
	content = f"{len(ordered)}\n" + "".join(f"{identifier:08x}\n" for identifier in ordered)
	for identifier in ordered:
		geometry = next(o["geometry"] for o in outputs if o["id"] == identifier)
		content += "geometry " + " ".join(str(value) for value in geometry) + "\n"
	return ordered, content


def register_resource_event(connection):
	# python-xlib supports older RRNotify subcodes but omits RandR 1.4's
	# ResourceChange (5), which Xwayland sends on primary changes/hotplug.
	from Xlib.protocol import rq
	from Xlib.ext import randr
	class ResourceChangeNotify(rq.Event):
		_code = None
		_fields = rq.Struct(rq.Card8("type"), rq.Card8("sub_code"), rq.Card16("sequence_number"),
		                    rq.Card32("timestamp"), rq.Window("window"), rq.Pad(20))
	info = connection.query_extension("RANDR")
	connection.extension_add_subevent(info.first_event + randr.RRNotify, 5, ResourceChangeNotify)
	return ResourceChangeNotify


class Topology:
	def __init__(self, path):
		from Xlib import display
		from Xlib.ext import randr
		self.path = Path(path)
		self.path.parent.mkdir(parents=True, exist_ok=True)
		self.lock = self.path.with_suffix(".lock").open("a")
		try:
			fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
		except BlockingIOError:
			self.lock.close()
			raise
		self.display = None
		try:
			# Never let a failed initial query reuse a previous session's plan.
			self.path.unlink(missing_ok=True)
			self.display = display.Display()
			register_resource_event(self.display)
			self.root = self.display.screen().root
			self.root.xrandr_select_input(randr.RRScreenChangeNotifyMask | randr.RRCrtcChangeNotifyMask |
			                              randr.RROutputChangeNotifyMask | randr.RROutputPropertyNotifyMask | 64)
			self.display.flush()
			self.stop_event = threading.Event()
			self.publish_with_retry()
			self.thread = threading.Thread(target=self.watch, daemon=True)
			self.thread.start()
		except Exception:
			try:
				if self.display:
					self.display.close()
			finally:
				self.lock.close()
			raise

	def publish_with_retry(self):
		for _ in range(3):
			if self.publish():
				return
			if self.stop_event.wait(0.1):
				return
		raise RuntimeError("XRandR topology unavailable after three snapshots")

	def publish(self):
		from Xlib import error
		try:
			resources = self.root.xrandr_get_screen_resources_current()
			primary = self.root.xrandr_get_output_primary().output
			outputs = []
			for identifier in resources.outputs:
				info = self.display.xrandr_get_output_info(identifier, resources.config_timestamp)
				geometry = None
				if info.crtc:
					crtc = self.display.xrandr_get_crtc_info(info.crtc, resources.config_timestamp)
					if crtc.mode:
						geometry = (crtc.x, crtc.y, crtc.width, crtc.height)
				outputs.append({"id": identifier, "connected": info.connection == 0, "geometry": geometry})
			ordered, content = source_plan(outputs, primary)
			if self.path.exists() and self.path.read_text() == content:
				return True
			temporary = self.path.with_suffix(".tmp")
			temporary.write_text(content)
			temporary.replace(self.path)
			print(f"XRandR Wine source order: {[hex(identifier) for identifier in ordered]}", flush=True)
			return True
		except (error.XError, OSError) as exception:
			print(f"XRandR topology changed during query: {exception}", flush=True)
			return False

	def watch(self):
		try:
			self.watch_events()
		except Exception as exception:
			print(f"XRandR publisher failed: {exception}", flush=True)
			# Wake the Wine helper and fail visibly instead of leaving a stale plan.
			self.path.unlink(missing_ok=True)
			self.stop_event.set()

	def watch_events(self):
		while not self.stop_event.is_set():
			ready = [self.display.fileno()] if self.display.pending_events() else select.select([self.display.fileno()], [], [], 1)[0]
			if not ready and not self.display.pending_events():
				continue
			while self.display.pending_events():
				self.display.next_event()
			# Collapse a burst of output notifications; no mouse/key events are selected.
			if self.stop_event.wait(0.1):
				break
			self.publish_with_retry()

	def close(self):
		self.stop_event.set()
		self.thread.join(timeout=2)
		try:
			self.display.close()
		finally:
			self.lock.close()
