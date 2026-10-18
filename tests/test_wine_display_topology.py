import importlib.util
from pathlib import Path
import unittest
import struct
import os
import tempfile
import threading
import fcntl
from types import SimpleNamespace
from unittest.mock import Mock, patch
import subprocess
import select
import shutil
import time

source = Path(os.environ.get("WINE_TOPOLOGY_MODULE", str(Path(__file__).parents[1] / "scripts/gaming/wine-display-topology.py")))
spec = importlib.util.spec_from_file_location("topology", source)
topology = importlib.util.module_from_spec(spec)
spec.loader.exec_module(topology)


def output(identifier, geometry, connected=True):
	return {"id": identifier, "geometry": geometry, "connected": connected}


class TopologyTests(unittest.TestCase):
	def test_supervisor_recovers_after_real_x11_connection_loss(self):
		try:
			import Xlib  # noqa: F401
		except ImportError:
			self.skipTest("Real X11 recovery runs in the tray package's Xvfb fixture")
		if not shutil.which("Xvfb"):
			self.skipTest("Xvfb is supplied by the tray package's fixture")
		module_path = Path(os.environ.get("WINE_SESSION_MODULE", str(Path(__file__).parents[1] / "scripts/gaming/wine-session.py")))
		session_spec = importlib.util.spec_from_file_location("recovery_session", module_path)
		session = importlib.util.module_from_spec(session_spec)
		session_spec.loader.exec_module(session)
		servers = []
		def server():
			process = subprocess.Popen(["Xvfb", "-displayfd", "1", "-screen", "0", "800x600x24", "-nolisten", "tcp"],
			                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
			servers.append(process)
			self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Xvfb did not become ready")
			number = process.stdout.readline().strip()
			process.stdout.close()
			self.assertTrue(number.isdecimal())
			os.environ["DISPLAY"] = ":" + number
			return process
		with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ):
			plan = Path(temporary) / "plan.txt"
			first = server()
			attempts = []
			def run(command):
				attempts.append(command)
				self.assertTrue(plan.exists())
				if len(attempts) == 1:
					first.terminate()
					first.wait(timeout=3)
					deadline = time.monotonic() + 4
					while plan.exists() and time.monotonic() < deadline:
						time.sleep(.01)
					self.assertFalse(plan.exists(), "Dead publisher left its plan usable")
					server()
					return SimpleNamespace(returncode=1)
				return SimpleNamespace(returncode=0)
			try:
				with patch.object(session, "process_running", return_value=True):
					self.assertEqual(session.supervise(Path(temporary), None, ["helper"], run, lambda _: None,
					                 display_plan=plan, topology_factory=topology.Topology), 0)
				self.assertEqual(len(attempts), 2)
			finally:
				for process in servers:
					if process.poll() is None:
						process.terminate()
					process.wait(timeout=3)

	def test_failed_snapshots_fail_visibly_instead_of_leaving_stale_plan(self):
		publisher = topology.Topology.__new__(topology.Topology)
		publisher.stop_event = threading.Event()
		publisher.publish = Mock(return_value=False)
		with self.assertRaisesRegex(RuntimeError, "three snapshots"):
			publisher.publish_with_retry()
		self.assertEqual(publisher.publish.call_count, 3)
		with tempfile.TemporaryDirectory() as temporary:
			publisher.path = Path(temporary) / "plan.txt"
			publisher.path.write_text("old plan")
			publisher.watch_events = Mock(side_effect=RuntimeError("failed topology"))
			publisher.watch()
			self.assertFalse(publisher.path.exists())
			self.assertTrue(publisher.stop_event.is_set())

	def test_failed_initial_snapshot_removes_old_plan_and_releases_lock(self):
		connection = Mock()
		randr = SimpleNamespace(RRScreenChangeNotifyMask=1, RRCrtcChangeNotifyMask=2,
		                        RROutputChangeNotifyMask=4, RROutputPropertyNotifyMask=8)
		modules = {"Xlib": SimpleNamespace(display=SimpleNamespace(Display=lambda: connection)),
		           "Xlib.ext": SimpleNamespace(randr=randr)}
		with tempfile.TemporaryDirectory() as temporary:
			path = Path(temporary) / "plan.txt"
			path.write_text("old plan")
			with patch.dict("sys.modules", modules), patch.object(topology, "register_resource_event"), \
			     patch.object(topology.Topology, "publish", return_value=False):
				with self.assertRaisesRegex(RuntimeError, "three snapshots"):
					topology.Topology(path)
			self.assertFalse(path.exists())
			connection.close.assert_called_once()
			with path.with_suffix(".lock").open("a") as lock:
				fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

	def test_position_change_updates_plan_with_unchanged_output_ids(self):
		first = [output(31, (0, 0, 3440, 1440)), output(12, (3440, 270, 2732, 2048))]
		moved = [output(31, (0, 0, 3440, 1440)), output(12, (3440, 0, 2732, 2048))]
		ids, before = topology.source_plan(first, 31)
		new_ids, after = topology.source_plan(moved, 31)
		self.assertEqual(ids, new_ids)
		self.assertNotEqual(before, after)
		self.assertEqual(after.splitlines()[:3], ["2", "0000001f", "0000000c"])
		self.assertEqual(topology.source_plan(moved, 31)[1], after)

	def test_modern_resource_change_wire_event_is_decoded(self):
		try:
			from Xlib import display
		except ImportError:
			self.skipTest("Real X11 wire check runs in the tray package's Xvfb fixture")
		connection = display.Display()
		self.addCleanup(connection.close)
		event_type = topology.register_resource_event(connection)
		event = event_type(binarydata=struct.pack("=BBHII20x", 90, 5, 7, 123, 0), display=connection.display)
		self.assertEqual(event.sub_code, 5)
		self.assertEqual(event.timestamp, 123)

	def test_primary_return_swaps_source_order_without_following_focus(self):
		lg = output(31, (0, 0, 3440, 1440))
		ipad = output(12, (3440, 270, 2732, 2048))
		self.assertEqual(topology.source_order([ipad, lg], 31), [31, 12])
		self.assertEqual(topology.source_order([ipad], 31), [12])
		self.assertEqual(topology.source_order([], 31), [])

	def test_mirrors_use_lowest_id_and_disconnected_sources_are_ignored(self):
		outputs = [output(9, (0, 0, 3440, 1440)), output(5, (0, 0, 3440, 1440)),
		           output(11, (3440, 0, 2732, 2048)), output(3, None), output(2, (0, 0, 800, 600), False)]
		self.assertEqual(topology.source_order(outputs, 9), [5, 11])

	def test_order_matches_wines_primary_swap_rather_than_sorting_ids(self):
		outputs = [output(80, (0, 0, 800, 600)), output(30, (800, 0, 800, 600)), output(60, (1600, 0, 800, 600))]
		self.assertEqual(topology.source_order(outputs, 60), [60, 30, 80])


if __name__ == "__main__":
	unittest.main()
