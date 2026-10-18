import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "obs_migration", Path(__file__).resolve().parents[1] / "scripts/nixos/migrate-obs-windows.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class ObsMigrationTests(unittest.TestCase):
    def setUp(self):
        self.source = {
            "name": "HiveTech 1440p",
            "DesktopAudioDevice1": {},
            "modules": {"scripts-tool": [{"path": "C:/old.lua"}], "captions": {}},
            "sources": [
                {"name": "Game", "id": "game_capture", "uuid": "game", "settings": {}},
                {"name": "Desktop", "id": "monitor_capture", "settings": {}},
                {"name": "Camera", "id": "dshow_input", "settings": {},
                 "filters": [{"id": "nv_greenscreen_filter", "settings": {"mode": 3}}]},
                {"name": "Camera Raw", "id": "scene", "settings": {"items": [
                    {"name": "Camera", "visible": True}]}},
                {"name": "Stream + Bumblebee", "id": "scene", "settings": {"items": [
                    {"name": "Camera Raw", "visible": True},
                    {"name": "Bee Dev", "visible": True},
                    {"name": "Bumblebee Overlay", "visible": False}]}},
                {"name": "Bumblebee Overlay", "id": "browser_source", "mixers": 197,
                 "settings": {"url": "https://example.test/private-token"}},
                {"name": "Clean", "id": "scene", "settings": {}, "filters": [
                    {"id": "osi_branch_output", "settings": {
                        "path": "C:/Videos", "video_encoder": "obs_nvenc_hevc_tex",
                        "audio_track": 2, "audio_track_5": 6}}]},
            ],
        }
        for index in range(1, 5):
            self.source[f"AuxAudioDevice{index}"] = {"uuid": str(index), "volume": 0.8}
        self.scene, self.unsupported = migration.migrate_scene(
            self.source, Path("/home/test"), Path("/dev/v4l/by-id/camera"))

    def test_separate_audio_and_no_desktop_duplication(self):
        self.assertNotIn("DesktopAudioDevice1", self.scene)
        for index, (_, device, mask) in enumerate(migration.AUDIO, 1):
            audio = self.scene[f"AuxAudioDevice{index}"]
            self.assertEqual(audio["settings"]["device_id"], device)
            self.assertEqual(audio["mixers"], mask)
            self.assertEqual(audio["uuid"], str(index))
            self.assertEqual(audio["volume"], 0.8)
            self.assertEqual(audio["monitoring_type"], 0)

    def test_camera_fails_closed_and_original_is_untouched(self):
        self.assertEqual(len(self.unsupported), 1)
        self.assertEqual(self.scene["sources"][2]["filters"], [])
        self.assertFalse(self.scene["sources"][4]["settings"]["items"][0]["visible"])
        self.assertEqual(self.source["sources"][2]["id"], "dshow_input")

    def test_linux_sources_and_preserved_branch_tracks(self):
        self.assertEqual(self.scene["sources"][0]["id"], "vkcapture-source")
        self.assertEqual(self.scene["sources"][0]["uuid"], "game")
        branch = self.scene["sources"][-1]["filters"][0]["settings"]
        self.assertEqual(branch["path"], "/home/test/Videos/OBS Clean")
        self.assertEqual((branch["audio_track"], branch["audio_track_5"]), (2, 6))
        self.assertNotIn("scripts-tool", self.scene["modules"])

    def test_production_overlay_without_stem_contamination(self):
        overlay = self.scene["sources"][5]
        self.assertEqual(overlay["settings"], self.source["sources"][5]["settings"])
        self.assertEqual(overlay["mixers"], 1)
        items = self.scene["sources"][4]["settings"]["items"]
        self.assertFalse(items[1]["visible"])
        self.assertTrue(items[2]["visible"])


if __name__ == "__main__":
    unittest.main()
