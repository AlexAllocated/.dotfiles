"""Exercise archive installation and preservation using real temporary ZIPs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location(
    "unreal_engine", Path(__file__).resolve().parents[1] / "scripts/unreal/engine.py"
)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "engine.zip"
        self.base = self.root / "installed"

    def archive_with(self, extra=None):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("Engine/Build/Build.version", json.dumps({
                "MajorVersion": 5, "MinorVersion": 8, "PatchVersion": 3,
                "IsPromotedBuild": 1,
            }))
            executable = zipfile.ZipInfo("Engine/Binaries/Linux/UnrealEditor")
            executable.external_attr = 0o100755 << 16
            bundle.writestr(executable, "editor fixture")
            bundle.writestr("Engine/Plugins/Experimental/ModelContextProtocol/ModelContextProtocol.uplugin", "{}")
            if extra:
                bundle.writestr(*extra)

    def test_install_records_hash_and_preserves_writable_runtime_on_repeat(self):
        self.archive_with()
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        engine.install(self.archive, self.base, digest)
        root = self.base / "5.8.3"
        (root / "Engine/Saved").mkdir()
        (root / "Engine/Saved/user-settings").write_text("preserve me")
        engine.install(self.archive, self.base, digest)
        self.assertEqual((root / "Engine/Saved/user-settings").read_text(), "preserve me")
        self.assertEqual((self.base / "current").resolve(), root)
        self.assertEqual(json.loads((root / ".dotfiles-install.json").read_text())["sha256"], digest)
        self.assertTrue((root / "Engine/Binaries/Linux/UnrealEditor").stat().st_mode & 0o111)

    def test_checksum_failure_does_not_extract(self):
        self.archive_with()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            engine.install(self.archive, self.base, "0" * 64)
        self.assertFalse(self.base.exists())

    def test_path_traversal_does_not_extract(self):
        self.archive_with(("../outside", "unsafe"))
        with self.assertRaisesRegex(ValueError, "Unsafe archive"):
            engine.install(self.archive, self.base, None)
        self.assertFalse((self.root / "outside").exists())

    def test_different_archive_cannot_replace_existing_install(self):
        self.archive_with()
        engine.install(self.archive, self.base, None)
        self.archive_with(("new-file", "different engine contents"))
        with self.assertRaisesRegex(ValueError, "Preserving existing"):
            engine.install(self.archive, self.base, None)
        self.assertFalse((self.base / "5.8.3/new-file").exists())
