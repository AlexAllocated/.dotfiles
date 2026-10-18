"""Regression cases from review of maintenance promotion boundaries."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context
import adapters
import maintenance


class PromotionReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        self.root.mkdir()
        self.ctx = Context(self.root, Path(self.tmp.name) / 'state')
        self.git('init', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.git('remote', 'add', 'origin', 'https://github.com/example/dotfiles.git')
        (self.root / 'flake.nix').write_text('{}\n')
        (self.root / 'modules').mkdir()
        (self.root / 'modules/feature.nix').write_text('{\n  services.example.enable = true;\n}\n')
        self.git('add', '.')
        self.git('commit', '-m', 'baseline')
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', self.root, *args], text=True, stderr=subprocess.DEVNULL).strip()

    def test_apply_refuses_source_changed_after_native_validation(self):
        validation = {'source_digest': adapters._source_digest(self.root), 'status': 'passed'}
        (self.root / 'flake.nix').write_text('{ changed = true; }\n')
        with patch.object(maintenance.adapters, 'apply') as apply:
            with self.assertRaisesRegex(RuntimeError, '(?i)source|validation|changed'):
                maintenance.apply_checked(self.ctx, 'editor', self.root,
                                          self.ctx.state / 'work', 'tracer', validation)
            apply.assert_not_called()

    def test_pr_retargeted_during_confirmation_cannot_merge_or_apply(self):
        candidate = {'schema_version': 1, 'id': 'system-review', 'group': 'system', 'profile': 'tracer',
                     'repository': 'example/dotfiles', 'base': self.base, 'head': self.base,
                     'tree': self.git('rev-parse', 'HEAD^{tree}'), 'branch': 'maintenance/system-review',
                     'checkout': str(self.root), 'work': str(self.ctx.state / 'work'),
                     'status': 'ready', 'pr': 'https://github.com/example/dotfiles/pull/1', 'stages': {},
                     'changed_paths': ['flake.lock']}
        maintenance.save(self.ctx, candidate)
        initial = {'state': 'OPEN', 'headRefOid': self.base, 'baseRefOid': self.base,
                   'baseRefName': 'main', 'isDraft': False, 'statusCheckRollup': [{'name': name, 'conclusion': 'SUCCESS'} for name in ('flake (ubuntu-24.04)', 'flake (macos-15)')]}
        retargeted = {**initial, 'baseRefName': 'other-branch'}
        with patch.object(maintenance, 'local_profile', return_value='tracer'), \
             patch.object(maintenance, 'pr_state', side_effect=[initial, retargeted]), \
             patch.object(maintenance, 'fetch_base', return_value=self.base), \
             patch.object(maintenance, 'verify', return_value={'status': 'passed'}), \
             patch.object(maintenance, 'confirm'), \
             patch.object(maintenance, 'gh', side_effect=RuntimeError('REMOTE MUTATION REACHED')) as remote:
            with self.assertRaisesRegex(RuntimeError, '(?i)base|changed|retarget'):
                maintenance.updoot(self.ctx, candidate['id'])
            remote.assert_not_called()

    def test_repair_cannot_disable_capability_by_removing_its_enable_line(self):
        (self.root / 'modules/feature.nix').write_text('{}\n')
        with self.assertRaisesRegex(RuntimeError, '(?i)capability|remove|enable'):
            maintenance.scope_guard(self.root, self.base, 'desktop')


if __name__ == '__main__':
    unittest.main()
