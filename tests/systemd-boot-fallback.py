#!/usr/bin/env python3
"""Exercise the selected real bootctl against disposable ESP/XBOOTLDR fixtures.

Never mount a filesystem or access firmware variables. systemd explicitly supports
these environment paths for tests; command-line partition paths require a real ESP.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SYSTEMD = Path(sys.argv.pop(1)).resolve()
EFI = SYSTEMD / "lib/systemd/boot/efi/systemd-bootx64.efi"


class WindowsFallback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dotfiles-bootctl-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.esp = self.root / "esp"
        self.boot = self.root / "boot"
        self.managed = self.esp / "EFI/systemd/systemd-bootx64.efi"
        self.fallback = self.esp / "EFI/BOOT/BOOTX64.EFI"
        self.current = EFI.read_bytes()
        # Only the LoaderInfo marker is read during a version check. Derive an
        # older fixture from the selected real binary, without pinning an old
        # package or executing modified EFI code.
        older, count = re.subn(
            rb"#### LoaderInfo: systemd-boot [^\x00]+? ####",
            b"#### LoaderInfo: systemd-boot 0 ####",
            self.current,
            count=1,
        )
        self.assertEqual(count, 1, "review upstream LoaderInfo format")
        foreign = b"MZ Windows-owned fallback fixture without LoaderInfo\x00"
        fixtures = {
            self.managed: older,
            self.fallback: foreign,
            self.esp / "EFI/Microsoft/Boot/bootmgfw.efi": foreign,
            self.esp / "EFI/WindowsFallbackBackup/windows-fallback-original.efi": foreign,
            self.boot / "loader/entries/nixos-generation-108.conf": b"previous generation\n",
        }
        for path, data in fixtures.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.protected = {path: data for path, data in fixtures.items() if path != self.managed}

    def update(self, graceful=True):
        # Explicit test paths prevent automatic discovery of the machine's ESP;
        # suppress firmware and random-seed writes independently of privilege.
        env = dict(os.environ, SYSTEMD_ESP_PATH=str(self.esp),
                   SYSTEMD_XBOOTLDR_PATH=str(self.boot), SYSTEMD_IN_CHROOT="0")
        args = [str(SYSTEMD / "bin/bootctl"), "--variables=no", "--random-seed=no",
                "--entry-token=literal:dotfiles-test"]
        if graceful:
            args.append("--graceful")
        return subprocess.run(args + ["update"], env=env, capture_output=True,
                              text=True, timeout=30)

    def assert_protected(self):
        for path, data in self.protected.items():
            self.assertEqual(path.read_bytes(), data, str(path))

    def test_plain_update_reproduces_foreign_fallback_failure(self):
        result = self.update(graceful=False)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("owned by another boot loader", result.stderr)
        self.assertEqual(self.managed.read_bytes(), self.current)
        self.assert_protected()

    def test_graceful_update_and_retry_preserve_windows_and_entries(self):
        for _ in range(2):
            result = self.update()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.managed.read_bytes(), self.current)
            self.assert_protected()
            self.assertTrue((self.boot / "loader/entries.srel").is_file())

    def test_different_loader_product_is_also_preserved(self):
        foreign = b"MZ\x00#### LoaderInfo: AnotherBootLoader 1 ####\x00"
        self.fallback.write_bytes(foreign)
        self.protected[self.fallback] = foreign
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.managed.read_bytes(), self.current)
        self.assert_protected()

    def test_malformed_version_information_remains_an_error(self):
        malformed = b"MZ\x00#### LoaderInfo: systemd-boot missing terminator\x00"
        self.fallback.write_bytes(malformed)
        self.protected[self.fallback] = malformed
        result = self.update()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("malformed LoaderInfo", result.stderr)
        self.assert_protected()

    def test_managed_destination_io_error_remains_an_error(self):
        self.managed.unlink()
        self.managed.mkdir()
        result = self.update()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.managed.is_dir())
        self.assert_protected()


if __name__ == "__main__":
    unittest.main()
