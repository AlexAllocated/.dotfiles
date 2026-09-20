import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


IMPORTER = module("razer_import", "scripts/nixos/razer-import-profiles.py")
CONTROL = module("razer_control", "scripts/nixos/razer-profile.py")


class RazerProfiles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.generated = self.root / "generated"
        self.source = json.loads((ROOT / "razer/synapse-profiles.json").read_text())
        IMPORTER.generate(self.source, self.generated)
        self.manifest = json.loads((self.generated / "manifest.json").read_text())

    def mappings(self, device, profile):
        path = self.generated / "presets" / IMPORTER.DEVICES[device] / f"{profile}.json"
        return {m["name"]: m for m in json.loads(path.read_text())}

    def test_all_profiles_apply_to_all_three_devices(self):
        self.assertEqual(len(self.manifest["profiles"]), 18)
        for name in self.manifest["profiles"]:
            for device in IMPORTER.DEVICES:
                self.assertTrue((self.generated / "presets" / IMPORTER.DEVICES[device] / f"{name}.json").exists())
                if device != "mouse":
                    self.assertTrue(self.mappings(device, name))
        self.assertEqual(self.manifest["defaults"]["BG3"]["keypad"], "DEFAULT")
        self.assertEqual(self.manifest["defaults"]["Heroes"]["keypad"], "Heroes")

    def test_keyboard_swap_survives_every_game(self):
        for name in self.manifest["profiles"]:
            mappings = self.mappings("keyboard", name)
            self.assertEqual(mappings["Synapse: KEY_ESC"]["output_symbol"], "KEY_CAPSLOCK")
            self.assertEqual(mappings["Synapse: KEY_CAPS_LOCK"]["output_symbol"], "KEY_ESC")

    def test_hypershift_is_shared_and_held(self):
        mouse = self.mappings("mouse", "Satisfactory")
        keypad = self.mappings("keypad", "Satisfactory")
        self.assertEqual(mouse["Synapse: DKM_SB_02"]["output_symbol"],
                         "set(razer_hypershift, 1).hold().set(razer_hypershift, 0)")
        self.assertIn("$razer_hypershift", keypad["Synapse: KEY_3"]["output_symbol"])
        self.assertIn("hold_keys(KEY_LEFTCTRL, KEY_C)", keypad["Synapse: KEY_3"]["output_symbol"])
        self.assertIn("hold_keys(KEY_LEFTALT, KEY_F10)", mouse["Synapse: DKM_SB_03"]["output_symbol"])

    def test_macro_preserves_order_and_delays(self):
        mapping = self.mappings("mouse", "DEFAULT (1)")["Synapse: Button5"]
        self.assertEqual(mapping["target_uinput"], "keyboard + mouse")
        self.assertEqual(mapping["output_symbol"],
                         "key_down(BTN_RIGHT).key_down(KEY_SPACE).wait(200).key_up(KEY_SPACE).wait(300).key_up(BTN_RIGHT).wait(20)")

    def test_unknown_mapping_rejected(self):
        with self.assertRaises(ValueError):
            IMPORTER.compile_mappings([{"inputID": "KEY_A", "outputType": "unknown"}], {}, "keypad")

    def test_hardware_bridge_only_for_software_actions(self):
        for preset in (self.generated / "hardware").glob("*.json"):
            for mapping in json.loads(preset.read_text()):
                if mapping["name"].startswith("Synapse bridge:"):
                    self.assertIn(mapping["output_symbol"], ["KEY_F13", "KEY_F14", "KEY_F15", "KEY_F16"])

    def test_heroes_simple_actions_programmed_directly(self):
        self.assertEqual(self.mappings("mouse", "Heroes"), {})
        hardware = {m["name"]: m for m in json.loads((self.generated / "hardware/Heroes.json").read_text())}
        for source, key in [("RepeatScrollLeft", "KEY_Z"), ("RepeatScrollRight", "KEY_B"),
                            ("DKM_SB_02", "KEY_LEFTALT")]:
            self.assertEqual(hardware[f"Synapse direct: {source}"]["output_symbol"], key)

    def test_all_simple_mouse_actions_match_synapse_directly(self):
        checked = 0
        for entry in self.source["profiles"]:
            if entry["device"] != "mouse":
                continue
            profile = entry["profile"]
            hardware = {m["name"]: m for m in json.loads(
                (self.generated / "hardware" / f'{profile["name"]}.json').read_text())}
            software = self.mappings("mouse", profile["name"])
            shifted = {m["inputID"] for m in profile["mappings"] if m.get("isHyperShift")}
            for mapping in profile["mappings"]:
                source = mapping["inputID"]
                value = mapping.get("mapping", [mapping])[0]
                if mapping.get("isHyperShift") or source in shifted or value.get("outputType") != "keyboardGroup":
                    continue
                keys = value["keyboardGroup"]
                if not keys.get("key"):
                    continue
                expected = " + ".join(IMPORTER.ALIASES.get(key, key)
                                      for key in [*keys.get("modifiers", []), keys["key"]])
                with self.subTest(profile=profile["name"], source=source):
                    self.assertEqual(hardware[f"Synapse direct: {source}"]["output_symbol"], expected)
                    self.assertNotIn(f"Synapse: {source}", software)
                checked += 1
        self.assertGreater(checked, 80)

    def test_live_interface_enumeration_closes_devices(self):
        class Device:
            name = IMPORTER.DEVICES["mouse"]
            closed = False

            def capabilities(self, absinfo):
                return {1: [184], 17: [0]}

            def close(self):
                self.closed = True

        device = Device()
        with patch("evdev.list_devices", return_value=["/dev/input/test"]), \
             patch("evdev.InputDevice", return_value=device):
            result = CONTROL.mouse_interfaces(device.name)
        self.assertEqual(len(result), 1)
        self.assertTrue(device.closed)

    def test_mouse_bridge_uses_keyboard_interface_with_leds(self):
        interfaces = [({1: [184], 2: [6]}, "consumer"),
                      ({1: [184], 17: [0, 1]}, "keyboard"),
                      ({1: [275], 2: [6]}, "mouse")]
        mappings = [{"input_combination": [{"type": 1, "code": 184}]}]
        CONTROL.bind_mouse_inputs(mappings, interfaces)
        self.assertEqual(mappings[0]["input_combination"][0]["origin_hash"], "keyboard")

    def test_missing_mouse_interface_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "interface unavailable"):
            CONTROL.bind_mouse_inputs([{"input_combination": [{"type": 1, "code": 184}]}], [])

    def test_mouse_scroll_uses_pointer_interface(self):
        interfaces = [({1: [184], 2: [6]}, "consumer"),
                      ({1: [275], 2: [0, 1, 6]}, "mouse")]
        mappings = [{"input_combination": [{"type": 2, "code": 6}]}]
        CONTROL.bind_mouse_inputs(mappings, interfaces)
        self.assertEqual(mappings[0]["input_combination"][0]["origin_hash"], "mouse")

    def test_direct_mouse_profile_does_not_start_injector(self):
        state = self.root / "state"
        interfaces = [({1: list(range(256)), 17: [0]}, "keyboard"),
                      ({1: list(range(256, 280)), 2: [0, 1, 6]}, "mouse")]
        with patch.object(CONTROL, "bus") as bus, \
             patch.object(CONTROL, "run", return_value=IMPORTER.DEVICES["mouse"]), \
             patch.object(CONTROL, "mouse_interfaces", return_value=interfaces):
            CONTROL.apply(self.generated, state, self.manifest, "Heroes", "hardware", 1)
        self.assertNotIn("start_injecting", [call.args[0] for call in bus.call_args_list])
        self.assertEqual(json.loads((state / "applied.json").read_text())["profile"], "Heroes")

    def test_mouse_alias_and_missing_devices(self):
        self.assertEqual(CONTROL.connected(self.manifest, ["Razer Razer Basilisk V3 Pro 35K"]),
                         {"mouse": "Razer Razer Basilisk V3 Pro 35K"})
        self.assertEqual(CONTROL.connected(self.manifest, ["Generic Mouse"]), {})

    def test_each_transaction_has_unique_shift_state_and_all_presets(self):
        devices = self.manifest["devices"]
        first = CONTROL.prepare(self.generated, self.root, self.manifest, "Satisfactory", devices)
        second = CONTROL.prepare(self.generated, self.root, self.manifest, "Satisfactory", devices)
        for device in devices.values():
            self.assertEqual(len(list((first / "presets" / device).glob("*.json"))), 18)
        file = Path("presets") / devices["mouse"] / "Satisfactory.json"
        self.assertNotEqual((first / file).read_text(), (second / file).read_text())
        self.assertIn(f"razer_hypershift_{first.name}", (first / file).read_text())

    def test_previous_config_backed_up_and_symlink_updates(self):
        config = self.root / "config"
        config.mkdir()
        (config / "custom.json").write_text("original")
        first = self.root / "first"
        first.mkdir()
        CONTROL.publish_config(config, first, self.root)
        backups = list(self.root.glob("legacy-input-remapper-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "custom.json").read_text(), "original")
        second = self.root / "second"
        second.mkdir()
        CONTROL.publish_config(config, second, self.root)
        self.assertEqual(config.resolve(), second)
        self.assertTrue(first.exists())

    def test_rejected_injector_is_not_reported_applied(self):
        calls = []
        def bus(method, signature=None, *args):
            calls.append((method, args))
            return "b false" if method == "start_injecting" else ""
        state = self.root / "state"
        with patch.object(CONTROL, "bus", bus), patch.object(CONTROL, "run", return_value=IMPORTER.DEVICES["keyboard"]):
            with self.assertRaisesRegex(RuntimeError, "rejected"):
                CONTROL.apply(self.generated, state, self.manifest, "Heroes", "hardware", 1)
        self.assertFalse((state / "applied.json").exists())


if __name__ == "__main__":
    unittest.main()
