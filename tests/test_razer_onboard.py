"""Exercise persistent-profile transactions without opening real HID devices."""
import argparse
from enum import Enum, IntFlag
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
Button = Enum("Button", "MIDDLE BOTTOM AIM MIDDLE_BACKWARD MIDDLE_FORWARD BACKWARD FORWARD WHEEL_LEFT WHEEL_RIGHT")
Profile = Enum("Profile", {"DIRECT": 0, "DEFAULT": 1, "RED": 2})
Modifier = IntFlag("Modifier", "LEFT_CONTROL LEFT_SHIFT LEFT_ALT LEFT_GUI RIGHT_CONTROL RIGHT_SHIFT RIGHT_ALT RIGHT_GUI")
protocol = types.ModuleType("qdrazer.protocol")
protocol.Button, protocol.Profile, protocol.FnKeyboardModifier = Button, Profile, Modifier
protocol.Hypershift = Enum("Hypershift", {"OFF": 0, "ON": 1})
qdrazer = types.ModuleType("qdrazer")
qdrazer.protocol = protocol
basilisk = types.ModuleType("basilisk_v3.device")
basilisk.BasiliskV3Pro35KPhantomGreenDevice = object
spec = importlib.util.spec_from_file_location("onboard_under_test", ROOT / "scripts/nixos/razer-onboard.py")
ONBOARD = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {"hid": types.ModuleType("hid"), "qdrazer": qdrazer,
                            "qdrazer.protocol": protocol, "basilisk_v3": types.ModuleType("basilisk_v3"),
                            "basilisk_v3.device": basilisk}):
    spec.loader.exec_module(ONBOARD)


class Device:
    def __init__(self):
        self.bindings = {
            (Profile.DEFAULT, Button.AIM): b"old-aim",
            (Profile.DEFAULT, Button.BACKWARD): b"old-bck",
            (Profile.DEFAULT, Button.MIDDLE): b"middle!",
            (Profile.RED, Button.AIM): b"other!!",
        }
        self.profiles = [Profile.DEFAULT, Profile.RED]
        self.writes = []
        self.fail = None
        self.before_write = None

    def get_profile_list(self):
        return self.profiles

    def get_button_function(self, button, *, profile):
        return self.bindings[profile, button]

    def set_button_function(self, value, button, *, profile):
        if self.before_write:
            self.before_write()
        self.writes.append((profile, button, value))
        self.bindings[profile, button] = value
        if button == self.fail:
            self.fail = None
            raise OSError("lost acknowledgement after write")


class OnboardPersistence(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.backups = self.root / "backups"
        self.device = Device()
        self.desired = {Button.AIM: b"new-aim", Button.BACKWARD: b"new-bck", Button.MIDDLE: b"middle!"}
        self.compiler = patch.object(ONBOARD, "compile_profile", return_value=(self.desired, {}))
        self.compiler.start()
        self.addCleanup(self.compiler.stop)

    def persist(self):
        return ONBOARD.persist_profile(self.device, self.root, "WoW", self.backups)

    def test_back_up_before_writing_and_preserve_other_bindings(self):
        before = dict(self.device.bindings)
        def check_backup():
            files = list(self.backups.glob("*.json"))
            self.assertEqual(len(files), 1)
            saved = json.loads(files[0].read_text())
            self.assertEqual(saved["bindings"]["AIM"], before[Profile.DEFAULT, Button.AIM].hex())
        self.device.before_write = check_backup
        result = self.persist()
        self.assertEqual(result["changed"], ["aim", "backward"])
        self.assertEqual(len(self.device.writes), 2)
        self.assertEqual(self.device.bindings[Profile.DEFAULT, Button.MIDDLE], b"middle!")
        self.assertEqual(self.device.bindings[Profile.RED, Button.AIM], b"other!!")
        self.assertEqual(json.loads(Path(result["backup"]).read_text())["selected_profile"], "WoW")

    def test_reapplication_skips_flash_writes_and_backups(self):
        self.persist()
        self.device.writes.clear()
        result = self.persist()
        self.assertEqual(result, {"changed": [], "backup": None})
        self.assertEqual(self.device.writes, [])
        self.assertEqual(len(list(self.backups.glob("*.json"))), 1)

    def test_failed_write_restores_every_attempted_binding(self):
        before = dict(self.device.bindings)
        self.device.fail = Button.BACKWARD
        with self.assertRaisesRegex(RuntimeError, "old bindings restored"):
            self.persist()
        self.assertEqual(self.device.bindings, before)
        self.assertEqual(len(list(self.backups.glob("*.json"))), 1)

    def test_bad_readback_rolls_back(self):
        before = dict(self.device.bindings)
        original = self.device.set_button_function
        def corrupt_once(value, button, *, profile):
            original(value, button, profile=profile)
            if len(self.device.writes) == 1:
                self.device.bindings[profile, button] = b"wrong!!"
        self.device.set_button_function = corrupt_once
        with self.assertRaisesRegex(RuntimeError, "old bindings restored"):
            self.persist()
        self.assertEqual(self.device.bindings, before)

    def test_failed_rollback_reports_backup_without_claiming_success(self):
        def fail(*args, **kwargs):
            raise OSError("offline")
        self.device.set_button_function = fail
        with self.assertRaisesRegex(RuntimeError, "rollback failed: AIM: offline.*backup:"):
            self.persist()

    def test_unavailable_or_missing_profile_does_not_write(self):
        self.device.profiles = [Profile.RED]
        with self.assertRaisesRegex(RuntimeError, "default onboard profile is missing"):
            self.persist()
        self.assertEqual(self.device.writes, [])
        self.assertFalse(self.backups.exists())

    def test_read_failure_does_not_write(self):
        with patch.object(self.device, "get_button_function", side_effect=OSError("asleep")):
            with self.assertRaisesRegex(OSError, "asleep"):
                self.persist()
        self.assertEqual(self.device.writes, [])
        self.assertFalse(self.backups.exists())

    def test_backup_failure_does_not_write(self):
        with patch.object(Path, "open", side_effect=PermissionError("read only")):
            with self.assertRaises(PermissionError):
                self.persist()
        self.assertEqual(self.device.writes, [])

    def test_compile_failure_does_not_touch_hardware(self):
        with patch.object(ONBOARD, "compile_profile", side_effect=ValueError("unsupported key")), \
             patch.object(self.device, "get_profile_list") as read:
            with self.assertRaises(ValueError):
                self.persist()
            read.assert_not_called()
        self.assertEqual(self.device.writes, [])

    def test_apply_and_reapply_persist_before_direct_and_save_after_success(self):
        for command in ("apply-profile", "reapply-profile"):
            args = argparse.Namespace(attempts=1, command=command, profile="WoW", profiles_dir=self.root,
                                      state_file=self.root / "current", transport="auto", onboard_backups=self.backups)
            calls = []
            self.device.close = lambda: calls.append("close")
            with patch.object(ONBOARD, "parse_args", return_value=args), \
                 patch.object(ONBOARD, "read_selected", return_value="WoW"), \
                 patch.object(ONBOARD, "connect", return_value=(self.device, "wireless", b"test")), \
                 patch.object(ONBOARD, "persist_profile", side_effect=lambda *a: calls.append("persist")), \
                 patch.object(ONBOARD, "apply_profile", side_effect=lambda *a: calls.append("direct")), \
                 patch.object(ONBOARD, "write_selected", side_effect=lambda *a: calls.append("remember")), \
                 patch("sys.stdout", new=io.StringIO()):
                ONBOARD.main()
            self.assertEqual(calls, ["persist", "direct", "remember", "close"] if command == "apply-profile"
                             else ["persist", "direct", "close"])


if __name__ == "__main__":
    unittest.main()
