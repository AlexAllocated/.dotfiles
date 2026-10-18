"""Nix identity follows reviewed Git content, never ignored runtime caches."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import nix_source
from adapters import _source_digest


class SourceIdentity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'source with spaces'
        self.root.mkdir()
        self.git(self.root, 'init', '-q')
        (self.root / '.gitignore').write_text('__pycache__/\n')
        (self.root / 'payload').write_text('reviewed')
        (self.root / 'flake.nix').write_text('''{
          outputs = { self }: { identity = {
            source = builtins.toString self.outPath;
            payload = builtins.readFile ./payload;
            added = if builtins.pathExists ./added.nix then builtins.readFile ./added.nix else "absent";
          }; };
        }''')
        self.git(self.root, 'add', '.')
        self.git(self.root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'reviewed')
        self.other = self.base / 'other'
        self.git(self.root, 'worktree', 'add', '--detach', str(self.other), 'HEAD')

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', root, *args], text=True, stderr=subprocess.DEVNULL)

    def add_ignored_cache(self):
        cache = self.root / '__pycache__'
        cache.mkdir()
        (cache / 'runtime.pyc').write_bytes(b'checkout-local runtime bytes')
        (self.root / 'payload').chmod(0o600)

    def test_digest_ignores_caches_and_nonexecutable_permissions_but_tracks_executable_bit(self):
        before = _source_digest(self.other)
        self.add_ignored_cache()
        self.assertEqual(_source_digest(self.root), before)
        (self.root / 'payload').chmod(0o700)
        self.assertNotEqual(_source_digest(self.root), before)
        self.assertIn('source%20with%20spaces', nix_source(self.root))

    def test_git_source_normalizes_symlinked_temporary_directory_ancestors(self):
        alias = self.base / 'temporary-alias'
        alias.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(nix_source(alias / self.root.name), nix_source(self.root))

    @unittest.skipUnless(shutil.which('nix'), 'native Nix is needed for a real Git-flake identity check')
    def test_nix_git_source_matches_across_worktrees_and_includes_reviewed_changes(self):
        def evaluate(root):
            command = ['nix', '--store', str(self.base / 'nix-store'),
                       '--extra-experimental-features', 'nix-command flakes', 'eval', '--offline',
                       '--no-write-lock-file', '--json', nix_source(root) + '#identity']
            return json.loads(subprocess.check_output(command, text=True, stderr=subprocess.PIPE,
                                                     env={**os.environ, 'XDG_CACHE_HOME': str(self.base / 'cache')}, timeout=60))
        clean = evaluate(self.other)
        self.add_ignored_cache()
        self.assertEqual(evaluate(self.root), clean)
        (self.root / 'payload').write_text('reviewed tracked change')
        (self.root / 'added.nix').write_text('reviewed new module')
        self.git(self.root, 'add', '--', 'added.nix')
        dirty = evaluate(self.root)
        self.assertEqual(dirty['payload'], 'reviewed tracked change')
        self.assertEqual(dirty['added'], 'reviewed new module')
        self.assertNotEqual(dirty['source'], clean['source'])


if __name__ == '__main__':
    unittest.main()
