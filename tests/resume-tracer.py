import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/nixos/resume-tracer.sh"
THREAD = "019ffbbd-47ec-7503-ab99-e20720aff1e4"


class ResumeTracerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".codex").mkdir()
        (self.root / ".dotfiles/.git").mkdir(parents=True)
        self.marker = self.root / ".codex/tracer-thread-id"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("codex", "tmux"):
            tool = self.bin / name
            tool.write_text(f"#!{shutil.which('bash')}\nprintf '%s\\n' \"$PWD\" \"$@\"\n")
            tool.chmod(0o700)

    def run_launcher(self, marker, in_tmux=False):
        self.marker.write_bytes(marker)
        env = dict(os.environ, HOME=str(self.root), PATH=f"{self.bin}:{os.environ['PATH']}", TMUX="test" if in_tmux else "")
        return subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True)

    def test_lf_and_crlf_in_both_launch_modes(self):
        for ending in ("\n", "\r\n"):
            for in_tmux in (False, True):
                with self.subTest(ending=ending, in_tmux=in_tmux):
                    result = self.run_launcher((THREAD + ending).encode(), in_tmux)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(THREAD, result.stdout)
                    self.assertIn(str(self.root / ".dotfiles"), result.stdout)
                    self.assertNotIn("\r", result.stdout)

    def test_invalid_markers(self):
        for marker in ("-" * 36, THREAD + "\nextra", THREAD.replace("-", "x"), THREAD + "\r\r\n"):
            with self.subTest(marker=marker):
                result = self.run_launcher(marker.encode())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid", result.stderr)

    def test_missing_marker(self):
        result = subprocess.run(["bash", str(SCRIPT)], env=dict(os.environ, HOME=str(self.root)), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
