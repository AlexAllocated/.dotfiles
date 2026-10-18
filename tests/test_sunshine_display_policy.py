import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest


source = Path(__file__).parents[1] / "scripts/nixos/sunshine-display-policy.py"
spec = importlib.util.spec_from_file_location("policy", source)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def output(width=3440, height=1440, fps=160, scale=1.5):
    return {
        "current_mode": 0,
        "logical": {"x": 0, "y": 0, "width": round(width / scale), "height": round(height / scale), "scale": scale},
        "modes": [{"width": width, "height": height, "refresh_rate": fps * 1000}],
    }


class FakeNiri:
    def __init__(self, outputs):
        self.outputs = outputs
        self.calls = []

    def __call__(self, command, **kwargs):
        args = command[3:]
        self.calls.append(args)
        if args[0] == "outputs":
            return SimpleNamespace(stdout=json.dumps(self.outputs))
        if args[0] == "create-virtual-output":
            self.outputs["Moonlight"] = output()
        elif args[0] == "remove-virtual-output":
            del self.outputs[args[1]]
        elif args[0] == "output" and args[2] == "mode":
            size, fps = args[3].split("@")
            width, height = size.split("x")
            self.outputs[args[1]] = output(int(width), int(height), int(fps))
        elif args[0] == "output" and args[2] == "scale":
            current = self.outputs[args[1]]
            scale = float(args[3])
            mode = current["modes"][current["current_mode"]]
            current["logical"].update(scale=scale, width=round(mode["width"] / scale), height=round(mode["height"] / scale))
        elif args[0] == "output" and args[2] == "position":
            self.outputs[args[1]]["logical"].update(x=int(args[4]), y=int(args[5]))
        return SimpleNamespace(stdout="null")


class Tests(unittest.TestCase):
    def render_nodes(self, drivers):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        sysfs = root / "sys"
        devices = root / "dev"
        devices.mkdir()
        for name, driver in drivers.items():
            node = sysfs / name / "device"
            node.mkdir(parents=True)
            (node / "driver").symlink_to(root / "drivers" / driver)
            (devices / name).touch()
        return sysfs, devices

    def test_headless_gpu_does_not_fall_back_to_integrated(self):
        sysfs, devices = self.render_nodes({"renderD128": "amdgpu", "renderD129": "nvidia"})
        self.assertEqual(policy.nvidia_render_node(sysfs, devices), str(devices / "renderD129"))

    def test_gpu_numbering_can_change(self):
        sysfs, devices = self.render_nodes({"renderD128": "nvidia", "renderD129": "amdgpu"})
        self.assertEqual(policy.nvidia_render_node(sysfs, devices), str(devices / "renderD128"))

    def test_missing_or_ambiguous_nvidia_fails_closed(self):
        for drivers in ({"renderD128": "amdgpu"}, {"renderD128": "nvidia", "renderD129": "nvidia"}):
            with self.subTest(drivers=drivers):
                with self.assertRaises(RuntimeError):
                    policy.nvidia_render_node(*self.render_nodes(drivers))

    def test_render_device_must_exist(self):
        sysfs, devices = self.render_nodes({"renderD129": "nvidia"})
        (devices / "renderD129").unlink()
        with self.assertRaises(RuntimeError):
            policy.nvidia_render_node(sysfs, devices)

    def run_policy(self, outputs, size=(2732, 2048, 120)):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        fake = FakeNiri(outputs)
        target = policy.Policy(fake, Path(temporary.name) / "selected")
        target.connectors = ["DP-4", "DP-1"]
        selected = target.prepare(size)
        self.assertEqual(target.state.read_text().strip(), selected)
        return target, fake

    def test_lg_is_extended_without_resizing(self):
        target, fake = self.run_policy({"DP-4": output()})
        self.assertEqual(fake.outputs["DP-4"], output())
        self.assertEqual(target.state.read_text(), "Moonlight\n")
        self.assertEqual(fake.outputs["Moonlight"]["logical"]["x"], 2293)
        self.assertIn(["output", "Moonlight", "position", "set", "2294", "0"], fake.calls)
        target.stop()
        self.assertNotIn("Moonlight", fake.outputs)
        self.assertEqual(fake.outputs["DP-4"], output())

    def test_extended_position_uses_lg_logical_bounds(self):
        lg = output(scale=2)
        lg["logical"].update(x=100, y=40)
        _, fake = self.run_policy({"DP-4": lg})
        self.assertEqual(fake.outputs["Moonlight"]["logical"]["x"], 1820)
        self.assertEqual(fake.outputs["Moonlight"]["logical"]["y"], 0)

    def test_ipad_matches_output_follow_service_at_global_top_edge(self):
        _, fake = self.run_policy({"DP-4": output(scale=1)})
        logical = fake.outputs["Moonlight"]["logical"]
        self.assertEqual(logical["x"], 3440)
        self.assertEqual(logical["y"], 0)

    def test_aligned_secondary_reconnect_does_not_nudge_geometry(self):
        existing = output(2732, 2048, 120, scale=1.75)
        existing["logical"].update(x=3440, y=0)
        _, fake = self.run_policy({"DP-4": output(scale=1), "Moonlight": existing})
        self.assertNotIn(["output", "Moonlight", "position", "set", "3441", "0"], fake.calls)

    def test_idle_with_lg_does_not_leave_an_extra_monitor(self):
        target, fake = self.run_policy({"DP-4": output()})
        target.idle()
        self.assertEqual(fake.outputs, {"DP-4": output()})
        self.assertEqual(target.state.read_text(), "DP-4\n")

    def test_headless_idle_retains_a_usable_virtual_display(self):
        target, fake = self.run_policy({})
        target.idle()
        self.assertEqual(fake.outputs["Moonlight"], output(1920, 1080, 60, scale=1.75))
        self.assertEqual(target.state.read_text(), "Moonlight\n")

    def test_headless_matches_client_and_keeps_last_output_on_disconnect(self):
        target, fake = self.run_policy({})
        self.assertEqual(fake.outputs["Moonlight"], output(2732, 2048, 120, scale=1.75))
        self.assertIn(["output", "Moonlight", "scale", "1.75"], fake.calls)
        target.stop()
        self.assertIn("Moonlight", fake.outputs)

    def test_paused_headless_session_is_cleaned_up_when_lg_returns(self):
        target, fake = self.run_policy({})
        self.assertFalse(target.stop())
        self.assertTrue(target.pending.exists())
        fake.outputs["DP-4"] = output()
        self.assertTrue(target.cleanup())
        self.assertNotIn("Moonlight", fake.outputs)
        self.assertEqual(target.state.read_text(), "DP-4\n")
        self.assertFalse(target.pending.exists())

    def test_resuming_cancels_deferred_cleanup(self):
        target, fake = self.run_policy({})
        target.stop()
        target.prepare((2732, 2048, 120))
        fake.outputs["DP-4"] = output()
        self.assertTrue(target.cleanup())
        self.assertIn("Moonlight", fake.outputs)
        self.assertFalse(target.pending.exists())

    def test_idle_headless_display_gets_deferred_cleanup(self):
        target, fake = self.run_policy({})
        target.idle()
        self.assertTrue(target.pending.exists())
        fake.outputs["DP-4"] = output()
        self.assertTrue(target.cleanup())
        self.assertNotIn("Moonlight", fake.outputs)

    def test_cleanup_is_idempotent(self):
        target, fake = self.run_policy({"DP-4": output()})
        self.assertTrue(target.stop())
        self.assertTrue(target.cleanup())
        self.assertEqual(fake.calls.count(["remove-virtual-output", "Moonlight"]), 1)

    def test_reconnect_resizes_existing_virtual(self):
        _, fake = self.run_policy({"Moonlight": output(1920, 1080, 60)})
        self.assertFalse(any(call[0] == "create-virtual-output" for call in fake.calls))
        self.assertEqual(fake.outputs["Moonlight"], output(2732, 2048, 120, scale=1.75))
        self.assertIn(["output", "Moonlight", "scale", "1.75"], fake.calls)
        self.assertEqual(fake.calls[-2:], [
            ["output", "Moonlight", "position", "set", "1", "0"],
            ["output", "Moonlight", "position", "set", "0", "0"],
        ])

    def test_unchanged_reconnect_does_not_nudge_geometry(self):
        _, fake = self.run_policy({"Moonlight": output(2732, 2048, 120, scale=1.75)})
        self.assertNotIn(["output", "Moonlight", "position", "set", "1", "0"], fake.calls)

    def test_scale_only_change_refreshes_xwayland_geometry(self):
        _, fake = self.run_policy({"Moonlight": output(2732, 2048, 120, scale=1)})
        self.assertIn(["output", "Moonlight", "position", "set", "1", "0"], fake.calls)
        self.assertEqual(fake.outputs["Moonlight"], output(2732, 2048, 120, scale=1.75))

    def test_lg_return_keeps_virtual_as_second_monitor(self):
        _, fake = self.run_policy({"DP-4": output(), "Moonlight": output()})
        self.assertIn("Moonlight", fake.outputs)
        self.assertEqual(fake.outputs["Moonlight"]["logical"]["x"], 2293)

    def test_lg_off_reconnect_moves_virtual_to_origin(self):
        existing = output(2732, 2048, 120, scale=1.75)
        existing["logical"]["x"] = 2293
        _, fake = self.run_policy({"Moonlight": existing})
        self.assertEqual(fake.outputs["Moonlight"], output(2732, 2048, 120, scale=1.75))
        self.assertIn(["output", "Moonlight", "position", "set", "1", "0"], fake.calls)

    def test_disabled_physical_does_not_win(self):
        disabled = output()
        disabled["current_mode"] = None
        target, _ = self.run_policy({"DP-4": disabled})
        self.assertEqual(target.state.read_text(), "Moonlight\n")

    def test_bad_client_parameters(self):
        for args in [(0, 1080, 60), (1920, 1080, 10000), (99999, 1080, 60), (1, 2)]:
            with self.assertRaises(ValueError):
                policy.dimensions(args)


if __name__ == "__main__":
    unittest.main()
