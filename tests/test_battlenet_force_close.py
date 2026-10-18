import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "battlenet_processes", Path(__file__).parents[1] / "scripts/gaming/battlenet-force-close.py")
processes = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = processes
spec.loader.exec_module(processes)


class ForceCloseTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "requires Linux procfs and pidfd signaling")
    def test_real_force_close_preserves_other_game_and_its_watcher(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary) / "pfx"
            children = []
            scan = processes.all_processes
            try:
                for name in ("Battle.net.exe", "Diablo IV.exe", "wine-display-sync.exe"):
                    children.append(subprocess.Popen([name, "-c", "import time; time.sleep(30)"],
                                    executable=sys.executable, env=os.environ | {"WINEPREFIX": str(prefix)}))
                def isolated_scan(*args, **kwargs):
                    return [p for p in scan(*args, **kwargs) if p.prefix == prefix]
                with patch.object(processes, "all_processes", side_effect=isolated_scan), \
                     patch.object(sys, "argv", ["force-close", "--prefix", str(prefix)]), \
                     patch.dict(os.environ, {"XDG_STATE_HOME": temporary}):
                    processes.main()
                    self.assertEqual(children[0].wait(timeout=3), -signal.SIGKILL)
                    self.assertIsNone(children[1].poll())
                    self.assertIsNone(children[2].poll())
                    children[1].terminate()
                    children[1].wait(timeout=3)
                    processes.main()
                    self.assertEqual(children[2].wait(timeout=3), -signal.SIGKILL)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=3)

    def make_process(self, proc, pid, name, prefix):
        path = proc / str(pid)
        path.mkdir()
        (path / "stat").write_text(f"{pid} (Wine (GUI) thread) S " + "0 " * 18 + "123\n")
        (path / "cmdline").write_bytes(os.fsencode(name) + b"\0")
        (path / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix) + b"\0")
        return path

    def test_all_clients_and_only_associated_helpers_are_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proc = root / "proc"
            proc.mkdir()
            prefix = root / "pfx"
            prefix.mkdir()
            (prefix / "pfx").symlink_to(".")
            self.make_process(proc, 1, r"C:\Battle.net\Battle.net.exe", prefix / "pfx")
            self.make_process(proc, 2, r"C:\WoW\WowB.exe", root / "old-prefix")
            self.make_process(proc, 3, "Agent.exe", prefix)
            self.make_process(proc, 4, "Agent.exe", root / "old-prefix")
            self.make_process(proc, 5, "Agent.exe", root / "unrelated")
            self.make_process(proc, 6, "Gw2-64.exe", prefix)
            self.make_process(proc, 7, "Diablo IV.exe", prefix)
            path = self.make_process(proc, 8, "python3", prefix)
            (path / "cmdline").write_bytes(b"python3\0proton\0Battle.net.exe\0")
            self.make_process(proc, 9, "wine-display-sync.exe", prefix)
            self.assertEqual({p.pid for p in processes.targets(prefix, proc)}, {1, 2, 3, 4})

    def test_zombie_leader_with_live_browser_threads_is_found(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proc = root / "proc"
            proc.mkdir()
            process = self.make_process(proc, 123, "", root / "pfx")
            (process / "environ").write_bytes(b"")
            thread = process / "task/124"
            thread.mkdir(parents=True)
            (thread / "cmdline").write_bytes(b"C:\\Battle.net\\Battle.net.exe\0--type=renderer\0")
            (thread / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(root / "pfx") + b"\0")
            self.assertEqual([p.pid for p in processes.targets(root / "pfx", proc)], [123])
            original = Path.read_bytes
            def read_bytes(path):
                if path == process / "environ":
                    raise PermissionError("Exited Wine leader's environment is inaccessible")
                return original(path)
            with patch.object(Path, "read_bytes", read_bytes):
                self.assertEqual([p.pid for p in processes.targets(root / "pfx", proc)], [123])
            self.assertIsNone(processes.inspect_process(process, os.getuid() + 1))

    def test_idle_session_cleanup_preserves_games_and_other_prefixes(self):
        old = Path("/old-battlenet-prefix")
        active = Path("/active-battlenet-prefix")
        unrelated = Path("/guild-wars-prefix")
        candidates = [
            processes.Process(1, "1", "explorer.exe", old),
            processes.Process(2, "1", "wineserver", old),
            processes.Process(3, "1", "explorer.exe", active),
            processes.Process(4, "1", "Diablo IV.exe", active),
            processes.Process(5, "1", "explorer.exe", unrelated),
            processes.Process(6, "1", "xalia.exe", old),
            processes.Process(7, "1", "wine-display-sync.exe", active),
            processes.Process(8, "1", "wine-display-sync.exe", old),
        ]
        self.assertEqual({p.pid for p in processes.idle_session_targets({old, active}, candidates)}, {1, 2, 6, 8})
        for name in ("Overwatch.exe", "UnknownGame.exe", "reg.exe", "Battle.net.exe"):
            candidates[3] = processes.Process(4, "1", name, active)
            self.assertEqual({p.pid for p in processes.idle_session_targets({old, active}, candidates)}, {1, 2, 6, 8})

    @unittest.skipUnless(sys.platform == "linux", "requires Linux procfs and pidfd signaling")
    def test_pidfd_kills_target_and_rejects_a_stale_identity(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            path = Path("/proc") / str(child.pid)
            stale = processes.Process(child.pid, "wrong-start-time", "Wow.exe", Path("/tmp"))
            self.assertFalse(processes.kill_process(stale))
            self.assertIsNone(child.poll())
            actual = processes.Process(child.pid, processes.identity(path), "Wow.exe", Path("/tmp"))
            self.assertTrue(processes.kill_process(actual))
            self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)

    @unittest.skipUnless(sys.platform == "linux", "requires Linux procfs and pidfd signaling")
    def test_real_exited_leader_with_live_threads_is_detected_and_killed(self):
        code = ("import ctypes,threading,time\n"
                "threading.Thread(target=lambda:time.sleep(30)).start()\n"
                "ctypes.CDLL(None).pthread_exit(None)\n")
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            child = subprocess.Popen([r"C:\WoW\WowB.exe", "-c", code], executable=sys.executable,
                                     env=os.environ | {"WINEPREFIX": str(prefix)})
            try:
                path = Path("/proc") / str(child.pid)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if (path / "stat").read_text().rsplit(")", 1)[1].split()[0] == "Z":
                        break
                    time.sleep(.01)
                else:
                    self.fail("Child's main thread did not exit")
                self.assertIsNone(child.poll())
                process = processes.inspect_process(path, os.getuid())
                self.assertIsNotNone(process)
                self.assertEqual(process.name, "WowB.exe")
                self.assertEqual(process.prefix, prefix)
                self.assertTrue(processes.kill_process(process))
                self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
