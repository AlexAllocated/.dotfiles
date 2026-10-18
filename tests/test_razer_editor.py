import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import test_razer_profiles as profiles


IMPORTER, CONTROL = profiles.IMPORTER, profiles.CONTROL
EDITOR = profiles.module("razer_editor", "scripts/nixos/razer-editor-model.py")


class RazerEditor(unittest.TestCase):
    setUp = profiles.RazerProfiles.setUp
    mappings = profiles.RazerProfiles.mappings

    def edit(self, **values):
        request = {"revision": EDITOR.revision([]), "profile": "Heroes", "device": "mouse",
                   "input": "RepeatScrollLeft", "kind": "key", "key": "KEY_J", **values}
        return EDITOR.update(self.source, [], request, IMPORTER)

    def test_editor_preserves_baseline_and_other_bindings(self):
        original = json.dumps(self.source, sort_keys=True)
        overrides = self.edit()
        IMPORTER.generate(EDITOR.merge(self.source, overrides), self.generated)
        hardware = {m["name"]: m["output_symbol"] for m in json.loads((self.generated / "hardware/Heroes.json").read_text())}
        self.assertEqual(hardware["Synapse direct: RepeatScrollLeft"], "KEY_J")
        self.assertEqual(hardware["Synapse direct: RepeatScrollRight"], "KEY_B")
        self.assertEqual(original, json.dumps(self.source, sort_keys=True))
        self.assertEqual(len(overrides), 1)

    def test_editor_materializes_fallback(self):
        overrides = self.edit(device="keyboard", input="KEY_A", key="KEY_B")
        self.assertEqual(overrides[0]["profile"]["name"], "Heroes")
        merged = EDITOR.merge(self.source, overrides)
        self.assertEqual(EDITOR.profile(merged, "keyboard", "WoW")["name"], "Keyboard Default")
        self.assertEqual(len(EDITOR.mappings(overrides[0]["profile"])), 3)

    def test_editor_hypershift_preserves_normal_mapping(self):
        overrides = self.edit(shift=True, modifiers=["KEY_LEFTCTRL"])
        IMPORTER.generate(EDITOR.merge(self.source, overrides), self.generated)
        text = self.mappings("mouse", "Heroes")["Synapse: RepeatScrollLeft"]["output_symbol"]
        self.assertIn("hold_keys(KEY_LEFTCTRL, KEY_J)", text)
        self.assertIn("hold_keys(KEY_Z)", text)

    def test_editor_default_removes_only_selected_control(self):
        IMPORTER.generate(EDITOR.merge(self.source, self.edit(kind="default")), self.generated)
        hardware = json.loads((self.generated / "hardware/Heroes.json").read_text())
        self.assertNotIn("Synapse direct: RepeatScrollLeft", [m["name"] for m in hardware])
        self.assertIn("Synapse direct: RepeatScrollRight", [m["name"] for m in hardware])

    def test_editor_rejects_stale_writes(self):
        with self.assertRaisesRegex(ValueError, "another window"):
            self.edit(revision="old")

    def test_editor_rejects_invalid_symbols_and_unsupported_controls(self):
        for values in [{"key": "KEY_NOPE"}, {"input": "BTN_LEFT"}, {"modifiers": ["KEY_A"]}, {"device": "unknown"}]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.edit(**values)

    def test_editor_duplicate_preserves_all_devices_and_keymaps(self):
        overrides = self.edit(operation="duplicate", name="My game")
        self.assertEqual(len(overrides), 3)
        merged = EDITOR.merge(self.source, overrides)
        self.assertEqual(len(EDITOR.profile(merged, "keypad", "My game")["keymaps"]), 3)
        IMPORTER.generate(merged, self.generated)
        for device in IMPORTER.DEVICES:
            self.assertEqual(self.mappings(device, "My game"), self.mappings(device, "Heroes"))

    def test_editor_rejects_unsafe_or_duplicate_names(self):
        for name in ["", "../escape", "/tmp/foo", "a\\b", "Heroes", ".", "a\nB", "x"*65]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.edit(operation="duplicate", name=name)

    def test_editor_keypad_active_keymap(self):
        overrides = self.edit(device="keypad", input="KEY_1", key="KEY_F9")
        before = EDITOR.profile(self.source, "keypad", "Heroes")
        self.assertEqual(before["keymaps"][1:], overrides[0]["profile"]["keymaps"][1:])
        IMPORTER.generate(EDITOR.merge(self.source, overrides), self.generated)
        self.assertEqual(self.mappings("keypad", "Heroes")["Synapse: KEY_1"]["output_symbol"], "KEY_F9")

    def test_editor_alias_does_not_duplicate_input(self):
        overrides = self.edit(device="keyboard", input="KEY_CAPSLOCK", key="KEY_F9")
        self.assertEqual(len(EDITOR.mappings(overrides[0]["profile"])), 2)

    def test_transaction_retains_compiled_source(self):
        result = CONTROL.prepare(self.generated, self.root, self.manifest, "Heroes", self.manifest["devices"])
        self.assertEqual((result / "source/hardware/Heroes.json").read_text(),
                         (self.generated / "hardware/Heroes.json").read_text())

    def test_failed_apply_restores_pre_edit_source_and_publishes_rollback(self):
        state = self.root / "state"
        state.mkdir()
        (state / "current").write_text("Heroes")
        before = CONTROL.prepare(self.generated, state, self.manifest, "Heroes", self.manifest["devices"])
        config = self.root / "config"
        config.symlink_to(before)
        after = state / "restored"
        after.mkdir()
        args = SimpleNamespace(source=self.generated, state=state, config=config,
                               command="apply-profile", profile="Heroes", hardware="hardware", attempts=1)
        with patch.object(CONTROL, "run"), patch.object(CONTROL, "apply", side_effect=[RuntimeError("failure"), after]) as apply:
            with self.assertRaisesRegex(RuntimeError, "restored Heroes"):
                CONTROL.execute(args)
        self.assertEqual(apply.call_args_list[1].args[0], before / "source")
        self.assertEqual(config.resolve(), after)
