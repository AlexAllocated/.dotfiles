"""Exercise isolation and the decision boundaries around remote/local mutation."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context, atomic
import maintenance as m


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        self.root.mkdir()
        self.state = Path(self.tmp.name) / 'state'
        self.ctx = Context(self.root, self.state)
        self.ctx.policy = {'canonical_branch': 'main', 'remote': 'origin'}
        self.git('init', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.git('remote', 'add', 'origin', 'https://github.com/example/dotfiles.git')
        (self.root / 'flake.lock').write_text(json.dumps({'root':'root','nodes':{'root':{'inputs':{'nixpkgs':'nixpkgs','recovery':'recovery'}},'nixpkgs':{'locked':{'rev':'old'}},'recovery':{'locked':{'rev':'fixed'}}}}))
        (self.root / 'tests').mkdir()
        (self.root / 'tests/gate.py').write_text('assert True\n')
        self.git('add', '.')
        self.git('commit', '-m', 'baseline')
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def candidate(self, state='ready'):
        return {'schema_version': 1, 'id': 'system-fixture', 'group': 'system', 'profile': 'tracer',
                'repository': 'example/dotfiles', 'base': self.base, 'head': self.base,
                'tree': self.git('rev-parse', 'HEAD^{tree}'), 'branch': 'maintenance/system-fixture',
                'checkout': str(self.root), 'work': str(self.state / 'work'),
                'status': state, 'pr': 'https://github.com/example/dotfiles/pull/1', 'stages': {},
                'changed_paths': ['flake.lock']}

    def test_scope_rejects_verification_weakening(self):
        (self.root / 'tests/gate.py').write_text('pass\n')
        with self.assertRaisesRegex(RuntimeError, 'outside'):
            m.scope_guard(self.root, self.base, 'system')

    def test_lock_update_cannot_change_recovery_pin(self):
        data = json.loads((self.root / 'flake.lock').read_text())
        data['nodes']['recovery']['locked']['rev'] = 'changed'
        (self.root / 'flake.lock').write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError, 'Unrelated Nix input'):
            m.scope_guard(self.root, self.base, 'system')

    def test_scope_preserves_features(self):
        (self.root / 'flake.lock').unlink()
        with self.assertRaisesRegex(RuntimeError, 'remove'):
            m.scope_guard(self.root, self.base, 'system')

    def test_untracked_changes_are_checked(self):
        (self.root / '.env').write_text('private')
        with self.assertRaisesRegex(RuntimeError, 'outside'):
            m.scope_guard(self.root, self.base, 'system')

    def test_candidate_source_change_rejected(self):
        c = self.candidate()
        (self.root / 'flake.lock').write_text('{"changed": true}')
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            m.assert_candidate_unchanged(c)

    def test_only_one_candidate_selected(self):
        c = self.candidate()
        m.save(self.ctx, c)
        d = {**c, 'id': 'editor-fixture', 'group': 'editor'}
        m.save(self.ctx, d)
        with self.assertRaisesRegex(RuntimeError, 'Choose one'):
            m.select(self.ctx)
        self.assertEqual(m.select(self.ctx, c['id'])['id'], c['id'])

    def test_nested_lock_rejected(self):
        with self.ctx.lock():
            with self.assertRaisesRegex(RuntimeError, 'already running'):
                with self.ctx.lock():
                    self.fail('Entered a second maintenance operation')

    def test_failure_receipt_survives_interruption(self):
        c = self.candidate()
        def interrupt():
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            m.journal(self.ctx, c, 'apply', interrupt)
        saved = m.load(self.ctx, c['id'])
        self.assertEqual(saved['stages']['apply']['status'], 'failed')

    def test_local_profile_prevents_cross_host_apply(self):
        with self.assertRaisesRegex(RuntimeError, 'managed Mac'):
            m.assert_applicable('mac', 'tracer')

    def test_editor_apply_allowed_on_mac_but_preparation_owned_by_tracer(self):
        m.assert_applicable('editor', 'macos-managed')
        with self.assertRaises(RuntimeError):
            m.assert_applicable('editor', 'macos-managed', preparing=True)

    def test_flake_check_weakening_rejected(self):
        (self.root / 'flake.nix').write_text('checks = {};')
        self.git('add', 'flake.nix')
        self.git('commit', '-m', 'flake fixture')
        base = self.git('rev-parse', 'HEAD')
        (self.root / 'flake.nix').write_text('checks = null;')
        with self.assertRaisesRegex(RuntimeError, 'checks and outputs'):
            m.scope_guard(self.root, base, 'desktop')

    def test_post_merge_validation_failure_can_retry(self):
        c = self.candidate('failed')
        c['merged_revision'] = self.base
        m.save(self.ctx, c)
        with patch.object(m, 'updoot', return_value={'status': 'applied'}) as apply:
            self.assertEqual(m.retry(self.ctx, c['id'])['status'], 'applied')
            apply.assert_called_once_with(self.ctx, c['id'])

    def test_ci_requires_actual_success(self):
        for checks in ([], [{'conclusion': 'SKIPPED'}], [{'conclusion': 'FAILURE'}], [{'status': 'IN_PROGRESS'}]):
            with self.assertRaises(RuntimeError):
                m.assert_checks({'statusCheckRollup': checks})
        m.assert_checks({'statusCheckRollup': [{'name': name, 'conclusion': 'SUCCESS'} for name in ('flake (ubuntu-24.04)', 'flake (macos-15)')]})

    def test_base_drift_cannot_merge(self):
        c = self.candidate()
        m.save(self.ctx, c)
        pr = {'state': 'OPEN', 'headRefOid': self.base, 'baseRefOid': self.base}
        with patch.object(m, 'local_profile', return_value='tracer'), patch.object(m, 'pr_state', return_value=pr), \
             patch.object(m, 'fetch_base', return_value='0' * 40), patch.object(m, 'gh') as remote:
            with self.assertRaisesRegex(RuntimeError, 'Canonical base changed'):
                m.updoot(self.ctx, c['id'])
            remote.assert_not_called()
        self.assertEqual(m.load(self.ctx, c['id'])['status'], 'stale')

    def test_pr_head_drift_cannot_merge(self):
        c = self.candidate()
        m.save(self.ctx, c)
        with patch.object(m, 'local_profile', return_value='tracer'), \
             patch.object(m, 'pr_state', return_value={'headRefOid': '0' * 40}), patch.object(m, 'gh') as remote:
            with self.assertRaisesRegex(RuntimeError, 'PR head changed'):
                m.updoot(self.ctx, c['id'])
            remote.assert_not_called()

    def test_plain_apply_refuses_dirty_source_before_adapter(self):
        (self.root / 'flake.lock').write_text('{"dirty": true}')
        with patch.object(m.adapters, 'check') as checks:
            with self.assertRaisesRegex(RuntimeError, 'committed clean'):
                m.apply_revision(self.ctx, 'tracer')
            checks.assert_not_called()

    def test_failed_apply_retry_does_not_publish(self):
        c = self.candidate('apply-failed')
        m.save(self.ctx, c)
        with patch.object(m, 'updoot', return_value={'status': 'applied'}) as apply, patch.object(m, 'publish') as publish:
            self.assertEqual(m.retry(self.ctx, c['id'])['status'], 'applied')
            apply.assert_called_once_with(self.ctx, c['id'])
            publish.assert_not_called()

    def test_retry_refuses_remote_edits(self):
        c = self.candidate('stale')
        c['published_head'] = self.base
        m.save(self.ctx, c)
        with patch.object(m, 'pr_state', return_value={'state': 'OPEN', 'headRefOid': '1' * 40}), patch.object(m, 'git') as git:
            with self.assertRaisesRegex(RuntimeError, 'changed or closed'):
                m.retry(self.ctx, c['id'])
            git.assert_not_called()

    def test_bad_candidate_ids_do_not_escape_state(self):
        with self.assertRaises(ValueError):
            m.candidate_file(self.ctx, '../../secret')

    def test_repository_parser_preserves_dot_prefix(self):
        self.git('remote', 'set-url', 'origin', 'git@github.com:example/.dotfiles.git')
        self.assertEqual(m.repository(self.ctx), 'example/.dotfiles')

    def test_worktree_isolation_preserves_staged_and_dirty_files(self):
        (self.root / 'flake.lock').write_text('staged')
        self.git('add', 'flake.lock')
        (self.root / 'flake.lock').write_text('unstaged')
        before = self.git('diff', '--cached')
        worktree = Path(self.tmp.name) / 'candidate'
        self.git('worktree', 'add', '--detach', str(worktree), self.base)
        data = json.loads((worktree / 'flake.lock').read_text())
        data['nodes']['nixpkgs']['locked']['rev'] = 'candidate'
        (worktree / 'flake.lock').write_text(json.dumps(data))
        self.assertEqual((self.root / 'flake.lock').read_text(), 'unstaged')
        self.assertEqual(self.git('diff', '--cached'), before)
        self.assertEqual(m.scope_guard(worktree, self.base, 'system'), ['flake.lock'])


if __name__ == '__main__':
    unittest.main()
