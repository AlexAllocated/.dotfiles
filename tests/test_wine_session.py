import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "wine_session", Path(__file__).parents[1] / "scripts/gaming/wine-session.py")
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


class WineSessionTests(unittest.TestCase):
    def test_recovery_recreates_publisher_after_helper_failure(self):
        publishers = [unittest.mock.Mock(), unittest.mock.Mock()]
        factory = unittest.mock.Mock(side_effect=publishers)
        run = unittest.mock.Mock(side_effect=[SimpleNamespace(returncode=1), SimpleNamespace(returncode=0)])
        sleep = unittest.mock.Mock()
        with patch.object(session, "process_running", return_value=True):
            self.assertEqual(session.supervise(Path("/pfx"), None, ["helper"], run, sleep,
                             display_plan=Path("/plan"), topology_factory=factory), 0)
        self.assertEqual(factory.call_count, 2)
        for publisher in publishers:
            publisher.close.assert_called_once()
        sleep.assert_called_once_with(2)

    def test_initial_publisher_failure_is_retried_and_duplicate_is_left_alone(self):
        publisher = unittest.mock.Mock()
        factory = unittest.mock.Mock(side_effect=[OSError("X11 unavailable"), publisher])
        run = unittest.mock.Mock(return_value=SimpleNamespace(returncode=0))
        with patch.object(session, "process_running", return_value=True):
            self.assertEqual(session.supervise(Path("/pfx"), None, ["helper"], run, lambda _: None,
                             display_plan=Path("/plan"), topology_factory=factory), 0)
        self.assertEqual(factory.call_count, 2)
        run.assert_called_once()
        factory = unittest.mock.Mock(side_effect=BlockingIOError("already owned"))
        run.reset_mock()
        self.assertEqual(session.supervise(Path("/pfx"), None, ["helper"], run,
                         display_plan=Path("/plan"), topology_factory=factory), 0)
        run.assert_not_called()

    def test_helper_failure_after_last_application_exits_is_normal_shutdown(self):
        with patch.object(session, "process_running", return_value=False):
            self.assertEqual(session.supervise(Path("/pfx"), None, ["helper"],
                             run=lambda _: SimpleNamespace(returncode=1)), 0)

    def test_session_lifetime_tracks_other_games_but_not_orphan_services(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = root / "123"
            process.mkdir()
            prefix = root / "pfx"
            (process / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix) + b"\0")
            for name, active in [("Diablo IV.exe", True), ("Overwatch.exe", True), ("UnknownGame.exe", True),
                                 ("Agent.exe", False), ("explorer.exe", False), ("wine-display-sync.exe", False)]:
                (process / "cmdline").write_bytes(os.fsencode(name) + b"\0")
                self.assertEqual(session.process_running(prefix, None, root), active)
                self.assertFalse(session.process_running(root / "unrelated", None, root))
            (process / "cmdline").write_bytes(b"WowClassicT.exe\0")
            self.assertTrue(session.process_running(prefix, ["Wow.exe", "WowClassicT.exe"], root))

    def test_helper_retry_is_bounded_and_stops_when_application_exits(self):
        run = unittest.mock.Mock(return_value=SimpleNamespace(returncode=1))
        sleep = unittest.mock.Mock()
        with patch.object(session, "process_running", return_value=True):
            self.assertEqual(session.supervise(Path("/pfx"), "Battle.net.exe", ["helper"], run, sleep), 1)
        self.assertEqual(run.call_count, 4)
        self.assertEqual([args[0][0] for args in sleep.call_args_list], [2, 10, 30])
        run.reset_mock()
        sleep.reset_mock()
        with patch.object(session, "process_running", side_effect=[True, False]):
            self.assertEqual(session.supervise(Path("/pfx"), "Battle.net.exe", ["helper"], run, sleep), 0)
        self.assertEqual(run.call_count, 1)

    def test_duplicate_helper_and_unsupported_runtime_do_not_retry(self):
        for code in (0, 2):
            run = unittest.mock.Mock(return_value=SimpleNamespace(returncode=code))
            sleep = unittest.mock.Mock()
            self.assertEqual(session.supervise(Path("/pfx"), "Battle.net.exe", ["helper"], run, sleep), code)
            self.assertEqual(run.call_count, 1)
            sleep.assert_not_called()

    def test_live_threads_are_found_when_leader_environment_denies_access(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            process = root / "123"
            process.mkdir()
            (process / "cmdline").write_bytes(b"")
            (process / "environ").write_bytes(b"")
            thread = process / "task/124"
            thread.mkdir(parents=True)
            (thread / "cmdline").write_bytes(b"C:\\WoW\\WowB.exe\0")
            prefix = root / "pfx"
            (thread / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix) + b"\0")
            original = Path.read_bytes
            def read_bytes(path):
                if path == process / "environ":
                    raise PermissionError("Exited leader")
                return original(path)
            with patch.object(Path, "read_bytes", read_bytes):
                self.assertTrue(session.process_running(prefix, "WowB.exe", root))
                self.assertFalse(session.process_running(root / "other-prefix", "WowB.exe", root))

    def test_wait_ignores_other_prefixes_and_launcher_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proc = root / "proc"
            proc.mkdir()
            prefix = root / "pfx"
            prefix.mkdir()
            (prefix / "pfx").symlink_to(".")
            process = proc / "123"
            process.mkdir()
            (process / "cmdline").write_bytes(b"python3\0proton\0Battle.net.exe\0")
            (process / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix))
            self.assertFalse(session.process_running(prefix, "Battle.net.exe", proc))
            (process / "cmdline").write_bytes(b"C:\\Program Files (x86)\\Battle.net\\Battle.net.exe\0")
            (process / "environ").write_bytes(b"WINEPREFIX=/another/prefix\0")
            self.assertFalse(session.process_running(prefix, "Battle.net.exe", proc))
            (process / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix / "pfx") + b"\0")
            self.assertTrue(session.process_running(prefix, "battle.net.exe", proc))
            (process / "cmdline").write_bytes(b"battlenet.overlay.runtime.exe\0")
            self.assertFalse(session.process_running(prefix, "Battle.net.exe", proc))


if __name__ == "__main__":
    unittest.main()
