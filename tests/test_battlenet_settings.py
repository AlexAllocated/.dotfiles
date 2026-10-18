import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
	"battlenet_settings", Path(__file__).parents[1] / "scripts/gaming/battlenet-settings.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class BattleNetSettingsTests(unittest.TestCase):
	def test_preserves_account_game_and_unrelated_client_settings(self):
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "Battle.net.config"
			original = {
				"Client": {"HardwareAcceleration": "true", "Locale": "enUS", "Account": "test-account"},
				"Games": {"wow": {"AdditionalLaunchArguments": "-console"}},
			}
			before = json.dumps(original).encode()
			path.write_bytes(before)
			self.assertTrue(settings.reconcile(path))
			actual = json.loads(path.read_bytes())
			original["Client"]["HardwareAcceleration"] = "false"
			self.assertEqual(actual, original)
			backups = list(path.parent.glob("Battle.net.config.before-browser-renderer-*"))
			self.assertEqual(len(backups), 1)
			self.assertEqual(backups[0].read_bytes(), before)
			self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
			self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
			self.assertFalse(settings.reconcile(path))
			self.assertEqual(len(list(path.parent.glob("Battle.net.config.before-browser-renderer-*"))), 1)

	def test_invalid_settings_are_not_overwritten(self):
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "Battle.net.config"
			for invalid in [b"not json", b"[]", b'{"Client": []}']:
				path.write_bytes(invalid)
				with self.assertRaises(ValueError):
					settings.reconcile(path)
				self.assertEqual(path.read_bytes(), invalid)

	def test_bootstraps_new_profile_with_only_browser_setting(self):
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "Battle.net" / "Battle.net.config"
			self.assertTrue(settings.reconcile(path))
			self.assertEqual(json.loads(path.read_bytes()), {"Client": {"HardwareAcceleration": "false"}})


if __name__ == "__main__":
	unittest.main()
