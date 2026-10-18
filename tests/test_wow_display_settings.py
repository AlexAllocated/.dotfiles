import importlib.util
from pathlib import Path
import tempfile
import unittest
import os


spec = importlib.util.spec_from_file_location(
	"wow_display_settings", Path(__file__).resolve().parents[1] / "scripts/gaming/wow-display-settings.py"
)
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class WoWDisplaySettingsTests(unittest.TestCase):
	def test_game_keeps_borderless_mode_to_agree_with_compositor_fullscreen(self):
		updated = settings.reconcile_text('SET GxMaximize "0"\n')
		self.assertIn('SET GxMaximize "1"\n', updated)
		self.assertEqual(settings.reconcile_text(updated), updated)

	def test_removes_stale_sizes_and_duplicate_cvars_preserving_other_settings(self):
		original = ('SET GxMaximize "0"\r\nSET gxmaximize "0"\r\n'
			'SET GxWindowedResolution "1950x1385"\r\nSET GxNewResolution "2732x2048"\r\n'
			'SET GxFullscreenResolution "2732x2048"\r\nSET GxMonitor "2"\r\n'
			'SET RenderScale "0.7"\r\nSET Sound_MasterVolume "0.4"\r\n')
		updated = settings.reconcile_text(original)
		self.assertIn('SET Sound_MasterVolume "0.4"\r\n', updated)
		self.assertNotIn("1950x1385", updated)
		self.assertNotIn("2732x2048", updated)
		self.assertEqual(updated.lower().count("gxmaximize"), 1)
		self.assertIn('SET GxFullscreenResolution "0x0"\r\n', updated)
		self.assertIn('SET GxMonitor "0"\r\n', updated)
		self.assertEqual(settings.reconcile_text(updated), updated)

	def test_check_is_read_only_and_apply_preserves_original_bytes(self):
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "Config.wtf"
			original = b'SET GxMaximize "0"\nSET accountName "test"'
			path.write_bytes(original)
			self.assertFalse(settings.reconcile(path, check=True))
			self.assertEqual(path.read_bytes(), original)
			self.assertEqual(len(list(path.parent.iterdir())), 1)
			settings.reconcile(path)
			backups = list(path.parent.glob("Config.wtf.before-borderless-*"))
			self.assertEqual(len(backups), 1)
			self.assertEqual(backups[0].read_bytes(), original)
			settings.reconcile(path)
			self.assertEqual(len(list(path.parent.glob("Config.wtf.before-borderless-*"))), 1)

	def test_detects_retail_and_forever_without_matching_launcher(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			process = root / "123"
			process.mkdir()
			prefix = root / "pfx"
			(process / "comm").write_text("unrelated thread name\n")
			(process / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix) + b"\0")
			for name, expected in [("Battle.net.exe", False), ("Wow.exe", True), ("WowB.exe", True),
			                       ("WowClassicT.exe", True)]:
				(process / "cmdline").write_bytes(os.fsencode(name) + b"\0")
				self.assertEqual(settings.wow_running(prefix, root), expected)
				self.assertFalse(settings.wow_running(root / "other-prefix", root))
			(process / "cmdline").write_bytes(b"")
			(process / "environ").write_bytes(b"")
			thread = process / "task/124"
			thread.mkdir(parents=True)
			(thread / "cmdline").write_bytes(b"WowB.exe\0")
			(thread / "environ").write_bytes(b"WINEPREFIX=" + os.fsencode(prefix) + b"\0")
			self.assertTrue(settings.wow_running(prefix, root))


if __name__ == "__main__":
	unittest.main()
