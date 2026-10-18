import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


source = Path(__file__).parents[1] / "scripts/nixos/wine-display-dpi.py"
spec = importlib.util.spec_from_file_location("wine_display_dpi", source)
dpi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dpi)


def output(scale):
    return {"current_mode": 0, "logical": {"scale": scale}}


class Tests(unittest.TestCase):
    def test_follows_focused_display_not_largest_scale(self):
        outputs = {"LG": output(1), "Moonlight": output(1.75)}
        for name, expected in (("LG", 96), ("Moonlight", 168)):
            with self.subTest(name=name):
                self.assertEqual(dpi.display_dpi(outputs, [{"output": name, "is_focused": True}]), expected)

    def test_single_output_without_focus(self):
        self.assertEqual(dpi.display_dpi({"Moonlight": output(1.75)}, []), 168)

    def test_disabled_output_is_ignored(self):
        disabled = output(1)
        disabled["current_mode"] = None
        self.assertEqual(dpi.display_dpi({"LG": disabled, "Moonlight": output(2)}, []), 192)

    def test_ambiguous_or_missing_output_does_not_guess(self):
        for outputs in ({}, {"LG": output(1), "Moonlight": output(2)}):
            with self.assertRaises(ValueError):
                dpi.display_dpi(outputs, [])

    def test_invalid_scale_is_rejected(self):
        for scale in (None, True, "1.75", 0, 5, float("nan"), float("inf")):
            with self.subTest(scale=scale), self.assertRaises(ValueError):
                dpi.display_dpi({"Moonlight": output(scale)}, [])


class WineSessionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.prefix = self.root / "pfx"
        self.prefix.mkdir()

    def server(self, prefix, name="wineserver"):
        process = self.proc / "123"
        process.mkdir()
        (process / "comm").write_text(name + "\n")
        (process / "environ").write_bytes(f"OTHER=value\0WINEPREFIX={prefix}\0".encode())

    def test_running_prefix_keeps_its_dpi(self):
        self.server(self.prefix)
        self.assertTrue(dpi.wine_server_running(self.prefix, self.proc))

    def test_umu_nested_prefix_alias_is_same_session(self):
        alias = self.prefix / "pfx"
        alias.symlink_to(".", target_is_directory=True)
        self.server(alias, "wineserver64")
        self.assertTrue(dpi.wine_server_running(self.prefix, self.proc))

    def test_another_prefix_does_not_block_new_session_scaling(self):
        self.server(self.root / "other-prefix")
        self.assertFalse(dpi.wine_server_running(self.prefix, self.proc))

    def test_empty_or_exiting_processes_do_not_count_as_running(self):
        self.assertFalse(dpi.wine_server_running(self.prefix, self.proc))
        (self.proc / "123").mkdir()
        self.assertFalse(dpi.wine_server_running(self.prefix, self.proc))

    def test_active_or_uninspectable_session_produces_no_new_dpi(self):
        for result in (True, PermissionError("cannot inspect Wine session")):
            with self.subTest(result=result), \
                 patch.object(dpi, "wine_server_running", **(
                     {"side_effect": result} if isinstance(result, Exception) else {"return_value": result})), \
                 patch.object(dpi.subprocess, "run") as run, \
                 patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                 patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(dpi.main(["--prefix", str(self.prefix)]), 1)
                self.assertEqual(stdout.getvalue(), "")
                run.assert_not_called()

    def test_fixed_baseline_does_not_depend_on_display_or_compositor(self):
        with patch.object(dpi, "wine_server_running", return_value=False), \
             patch.object(dpi.subprocess, "run") as run, \
             patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(dpi.main(["--prefix", str(self.prefix), "--dpi", "96"]), 0)
            self.assertEqual(stdout.getvalue(), "96\n")
            run.assert_not_called()

    def test_fixed_baseline_still_refuses_live_or_uninspectable_sessions(self):
        for result in (True, PermissionError("cannot inspect Wine session")):
            with self.subTest(result=result), \
                 patch.object(dpi, "wine_server_running", **(
                     {"side_effect": result} if isinstance(result, Exception) else {"return_value": result})), \
                 patch.object(dpi.subprocess, "run") as run, \
                 patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                 patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(dpi.main(["--prefix", str(self.prefix), "--dpi", "96"]), 1)
                self.assertEqual(stdout.getvalue(), "")
                run.assert_not_called()

    def test_invalid_fixed_baselines_are_rejected_before_session_access(self):
        for value in ("0", "47", "385", "1.75"):
            with self.subTest(value=value), \
                 patch.object(dpi, "wine_server_running") as running, \
                 patch("sys.stderr", new_callable=io.StringIO), \
                 self.assertRaises(SystemExit):
                dpi.main(["--prefix", str(self.prefix), "--dpi", value])
            running.assert_not_called()


if __name__ == "__main__":
    unittest.main()
