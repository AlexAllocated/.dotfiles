import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


source = Path(__file__).parents[1] / "scripts/nixos/chatgpt-supervisor.py"
spec = importlib.util.spec_from_file_location("supervisor", source)
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)


class Tests(unittest.TestCase):
    def environment(self, text="DISPLAY=:1\nNIRI_SOCKET=/run/new.sock", active=0, exists=True):
        run = Mock(side_effect=[
            SimpleNamespace(returncode=active), SimpleNamespace(stdout=text),
        ])
        return supervisor.desktop_environment(
            {"HOME": "/home/test", "DISPLAY": ":99", "NIRI_SOCKET": "/run/old.sock"},
            run, lambda _: exists,
        )

    def test_uses_fresh_session_environment_and_preserves_home(self):
        env = self.environment("DISPLAY=:1\nPATH=/untrusted\nCODEX_HOME=/home/test/custom")
        self.assertEqual(env["DISPLAY"], ":1")
        self.assertEqual(env["HOME"], "/home/test")
        self.assertEqual(env["CODEX_HOME"], "/home/test/custom")
        self.assertNotIn("NIRI_SOCKET", env)
        self.assertNotIn("PATH", env)

    def test_waits_for_session_and_x_socket(self):
        self.assertIsNone(self.environment(active=3))
        self.assertIsNone(self.environment(exists=False))
        self.assertIsNone(self.environment("DISPLAY=remote:1"))
        self.assertIsNone(self.environment("DISPLAY=:not-a-number"))
        self.assertIsNone(self.environment("WAYLAND_DISPLAY=wayland-1"))

    def test_unavailable_user_manager_is_retried(self):
        run = Mock(side_effect=subprocess.TimeoutExpired("systemctl", 5))
        self.assertIsNone(supervisor.desktop_environment({}, run))

    def test_existing_app_is_not_relaunched(self):
        launch = Mock()
        child, _ = supervisor.tick(None, None, {"DISPLAY": ":1"}, "chatgpt", lambda: True, launch)
        self.assertIsNone(child)
        launch.assert_not_called()

    def test_missing_app_is_launched(self):
        launch = Mock()
        env = {"DISPLAY": ":1"}
        child, _ = supervisor.tick(None, None, env, "chatgpt", lambda: False, launch)
        launch.assert_called_once_with(["chatgpt"], env=env)
        self.assertIs(child, launch.return_value)

    def test_crashed_app_is_relaunched(self):
        child = Mock()
        child.poll.return_value = 1
        launch = Mock()
        replacement, _ = supervisor.tick(
            child, (":1", None, None, None), {"DISPLAY": ":1"},
            "chatgpt", lambda: False, launch,
        )
        self.assertIs(replacement, launch.return_value)

    def test_session_loss_stops_only_managed_child_and_waits(self):
        child = Mock()
        child.poll.return_value = None
        launch = Mock()
        result, _ = supervisor.tick(child, (":1",), None, "chatgpt", lambda: False, launch)
        child.terminate.assert_called_once()
        child.wait.assert_called_once_with(timeout=10)
        launch.assert_not_called()
        self.assertIsNone(result)

    def test_graphical_replacement_relaunches_with_new_environment(self):
        child = Mock()
        child.poll.return_value = None
        launch = Mock()
        env = {"DISPLAY": ":2", "NIRI_SOCKET": "/run/new.sock"}
        supervisor.tick(child, (":1", None, None, "/run/old.sock"), env, "chatgpt", lambda: False, launch)
        child.terminate.assert_called_once()
        launch.assert_called_once_with(["chatgpt"], env=env)

    def test_process_detection_ignores_helpers_and_other_users(self):
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            main = proc / "123"
            main.mkdir()
            (main / "exe").symlink_to("/nix/store/test/lib/chatgpt/ChatGPT")
            (main / "cmdline").write_bytes(b"ChatGPT\0--type=renderer\0")
            self.assertFalse(supervisor.app_running(proc))
            (main / "cmdline").write_bytes(b"ChatGPT\0")
            self.assertTrue(supervisor.app_running(proc))
            self.assertFalse(supervisor.app_running(proc, os.getuid() + 1))
            (main / "exe").unlink()
            self.assertFalse(supervisor.app_running(proc))


if __name__ == "__main__":
    unittest.main()
