"""Exercise destructive-cleanup boundaries with real filesystem changes."""
import datetime as dt
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context
import storage


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve() / 'repo'
        self.root.mkdir()
        (self.root / 'catalog').mkdir()
        self.backups = self.root.parent / 'backups'
        self.backups.mkdir()
        (self.root / 'catalog/policy.json').write_text(json.dumps({'artifact_roots': [str(self.backups)]}))
        self.ctx = Context(self.root, self.root.parent / 'state')
        self.mounts = patch.object(storage, 'mount_table', return_value=[])
        self.mounts.start()

    def tearDown(self):
        self.mounts.stop()
        self.temporary.cleanup()

    def scratch(self, name='scratch', *, inactive=True, old=True):
        target = self.ctx.state / 'scratch' / name
        target.mkdir(parents=True)
        (target / 'log').write_text('disposable log')
        storage.register(self.ctx, target, purpose='test scratch', category='scratch', creator='test', disposable=True)
        if inactive:
            storage.update_registration(self.ctx, target, active=False)
        if old:
            then = time.time() - 31 * 86400
            for path in (target / 'log', target):
                os.utime(path, (then, then))
            entries = self.ctx.load('artifact-ownership.json')
            entries[str(target)]['created_at'] = dt.datetime.fromtimestamp(then, dt.timezone.utc).isoformat()
            self.ctx.save('artifact-ownership.json', entries)
        return target

    def test_cached_storage_does_not_scan_or_create_state(self):
        with patch.object(storage, 'scan', side_effect=AssertionError('implicit scan')):
            self.assertEqual(storage.cached(self.ctx)['items'], [])
        self.assertFalse(self.ctx.state.exists())

    def test_unknown_and_backups_stay_protected_even_when_old(self):
        unknown = self.backups / 'old-unknown'
        unknown.mkdir()
        known = self.backups / 'old-known'
        known.mkdir()
        storage.register(self.ctx, known, purpose='precious backup', category='backup', creator='test')
        result = storage.plan(self.ctx)
        self.assertEqual(result['items'], [])
        self.assertEqual(result['protected_count'], 2)

    def test_only_owned_inactive_old_disposable_scratch_is_removed(self):
        disposable = self.scratch()
        active = self.scratch('active', inactive=False)
        fresh = self.scratch('fresh', old=False)
        result = storage.cleanup(self.ctx)
        self.assertEqual(result['removed'], [str(disposable)])
        self.assertFalse(disposable.exists())
        self.assertTrue(active.exists())
        self.assertTrue(fresh.exists())
        self.assertEqual(self.ctx.load('cleanup-last.json')['status'], 'complete')

    def test_new_content_protects_old_scratch(self):
        target = self.scratch()
        (target / 'new').write_text('new valuable content')
        self.assertEqual(storage.plan(self.ctx)['items'], [])

    def test_candidate_reference_protects_disposable_scratch(self):
        target = self.scratch()
        self.ctx.save('candidates/job/candidate.json', {'id': 'job', 'log_path': str(target), 'status': 'failed'})
        self.assertEqual(storage.plan(self.ctx)['items'], [])

    def test_git_worktrees_are_never_assumed_disposable(self):
        target = self.scratch()
        (target / '.git').write_text('gitdir: /some/real/worktree')
        then = time.time() - 31 * 86400
        os.utime(target / '.git', (then, then))
        os.utime(target, (then, then))
        result = storage.scan(self.ctx)['items'][0]
        self.assertIn('git-data', result['flags'])
        self.assertTrue(result['protected'])

    def test_symlink_outside_root_is_not_followed_or_deleted(self):
        target = self.scratch()
        precious = self.root.parent / 'precious'
        precious.mkdir()
        (precious / 'data').write_text('keep')
        (target / 'link').symlink_to(precious)
        result = storage.measure(target, mounts=[])
        self.assertIn('symlink', result['flags'])
        self.assertEqual(result['entries'], 3)
        self.assertEqual(storage.cleanup(self.ctx)['removed'], [])
        self.assertTrue((precious / 'data').exists())

    def test_symlinked_root_and_ancestor_are_skipped(self):
        alias = self.root.parent / 'alias'
        alias.symlink_to(self.backups, target_is_directory=True)
        (self.backups / 'nested').mkdir()
        self.ctx.policy['artifact_roots'] = [str(alias / 'nested')]
        result = storage.scan(self.ctx)
        self.assertTrue(any('symlink ancestry' in error for error in result['errors']))

    def test_automount_root_is_not_touched(self):
        self.ctx.policy['artifact_roots'] = ['/would-trigger-auto/backup']
        with patch.object(storage, 'mount_table', return_value=[{'path': Path('/would-trigger-auto'), 'type': 'autofs'}]):
            result = storage.scan(self.ctx)
        self.assertTrue(any('automounted' in error for error in result['errors']))
        self.assertEqual(result['items'], [])

    def test_nested_mount_is_not_walked(self):
        target = self.scratch()
        mount = target / 'mounted'
        mount.mkdir()
        (mount / 'precious').write_text('protected')
        result = storage.measure(target, mounts=[{'path': mount, 'type': 'ext4'}])
        self.assertFalse(result['complete'])
        self.assertIn('nested-mount', result['flags'])
        self.assertEqual(result['entries'], 2)

    def test_hardlinked_allocations_are_counted_once_across_artifacts(self):
        one = self.backups / 'one'
        one.write_bytes(b'x' * 10000)
        two = self.backups / 'two'
        os.link(one, two)
        result = storage.scan(self.ctx)
        self.assertEqual(result['allocated_bytes'], one.stat().st_blocks * 512)

    def test_nested_registered_roots_do_not_double_count(self):
        nested = self.backups / 'nested'
        nested.mkdir()
        (nested / 'file').write_bytes(b'content')
        self.ctx.policy['artifact_roots'].append(str(nested))
        result = storage.scan(self.ctx)
        self.assertEqual(len(result['items']), 1)
        self.assertEqual(result['allocated_bytes'], storage.measure(nested, mounts=[])['allocated_bytes'])

    def test_nested_registered_backup_has_metadata_without_double_count(self):
        folder = self.backups / 'existing'
        folder.mkdir()
        backup = folder / 'backup'
        backup.mkdir()
        (backup / 'file').write_bytes(b'precious')
        storage.register(self.ctx, backup, purpose='Documented nested backup', category='backup', creator='fixture')
        result = storage.scan(self.ctx)
        self.assertEqual(len(result['items']), 2)
        nested = next(item for item in result['items'] if item['path'] == str(backup))
        self.assertEqual(nested['purpose'], 'Documented nested backup')
        self.assertEqual(nested['accounted_bytes'], 0)
        self.assertTrue(nested['protected'])
        self.assertEqual(result['allocated_bytes'], storage.measure(folder, mounts=[])['allocated_bytes'])

    def test_replaced_owned_path_loses_ownership(self):
        target = self.scratch()
        target.rename(target.with_name('original'))
        target.mkdir()
        result = next(item for item in storage.scan(self.ctx)['items'] if item['path'] == str(target))
        self.assertFalse(result['owned'])
        self.assertTrue(result['protected'])

    def test_changed_contents_between_plan_and_delete_abort_with_receipt(self):
        target = self.scratch()
        original = storage.plan
        def racing_plan(ctx):
            result = original(ctx)
            (target / 'log').write_text('changed without changing root directory entry')
            return result
        with patch.object(storage, 'plan', side_effect=racing_plan):
            with self.assertRaisesRegex(RuntimeError, 'contents changed'):
                storage.cleanup(self.ctx)
        self.assertTrue(target.exists())
        self.assertEqual(self.ctx.load('cleanup-last.json')['status'], 'failed')

    def test_nix_store_is_rejected_without_traversal(self):
        with self.assertRaisesRegex(ValueError, 'managed by Nix'):
            storage.check_path('/nix/store/anything', [])

    def test_disposable_backup_registration_is_rejected(self):
        target = self.backups / 'backup'
        target.mkdir()
        with self.assertRaisesRegex(ValueError, 'Only direct controller scratch'):
            storage.register(self.ctx, target, purpose='backup', category='backup', creator='test', disposable=True)

    def candidate(self, identity='resolved', state='no-change'):
        def git(*args):
            return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                                  text=True, capture_output=True).stdout.strip()
        git('init')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        git('add', '.')
        git('commit', '-m', 'fixture')
        head = git('rev-parse', 'HEAD')
        directory = self.ctx.state / 'candidates' / identity
        directory.mkdir(parents=True)
        tree = directory / 'repo'
        git('worktree', 'add', '--detach', str(tree), head)
        candidate = {'id': identity, 'status': state, 'repository': 'owner/repo', 'base': head,
                     'head': head, 'checkout': str(tree), 'created_at': '2020-01-01T00:00:00+00:00',
                     'updated_at': '2020-01-01T00:00:00+00:00'}
        self.ctx.save('candidates/' + identity + '/candidate.json', candidate)
        storage.register(self.ctx, directory, purpose='update candidate', category='candidate', creator='dotctl', references=[identity])
        self.age_tree(directory)
        return directory, candidate

    def age_tree(self, directory):
        then = time.time() - 31 * 86400
        for path in sorted(directory.rglob('*'), reverse=True):
            os.utime(path, (then, then), follow_symlinks=False)
        os.utime(directory, (then, then))

    def test_resolved_clean_candidate_removed_via_git_with_tombstone(self):
        directory, candidate = self.candidate()
        result = storage.cleanup(self.ctx)
        self.assertEqual(result['removed'], [str(directory)])
        self.assertEqual(result['worktrees_removed'], [candidate['checkout']])
        self.assertFalse(directory.exists())
        self.assertEqual(self.ctx.load('retired-candidates/resolved.json')['status'], 'no-change')
        worktrees = subprocess.run(['git', '-C', str(self.root), 'worktree', 'list'],
                                  check=True, text=True, capture_output=True).stdout
        self.assertNotIn(candidate['checkout'], worktrees)

    def test_unknown_candidate_siblings_survive_cleanup_after_retention(self):
        directory, _ = self.candidate()
        notes = directory / 'manual-recovery.txt'
        notes.write_text('Recovery instructions outside the owned checkout')
        backup = directory / 'manual-backup'
        backup.mkdir()
        (backup / 'important.txt').write_text('Unclassified user data')
        self.age_tree(directory)
        inventory = storage.scan(self.ctx)
        item = next(item for item in inventory['items'] if item['path'] == str(directory))
        self.assertTrue(item['protected'])
        self.assertIn('Unclassified candidate siblings', item['protection_reason'])
        self.assertEqual(storage.cleanup(self.ctx)['removed'], [])
        self.assertEqual(notes.read_text(), 'Recovery instructions outside the owned checkout')
        self.assertEqual((backup / 'important.txt').read_text(), 'Unclassified user data')

    def test_declared_candidate_workspace_is_owned_but_unlisted_workspace_is_not(self):
        directory, candidate = self.candidate()
        work = directory / 'work'
        work.mkdir()
        (work / 'adapter-check.json').write_text('{"status":"passed"}')
        self.age_tree(directory)
        self.assertEqual(storage.plan(self.ctx)['items'], [])
        candidate['work'] = str(work)
        self.ctx.save('candidates/resolved/candidate.json', candidate)
        self.age_tree(directory)
        self.assertEqual([item['path'] for item in storage.plan(self.ctx)['items']], [str(directory)])

    def test_dirty_and_ignored_candidate_worktrees_are_protected(self):
        directory, candidate = self.candidate()
        (Path(candidate['checkout']) / 'untracked').write_text('valuable')
        self.age_tree(directory)
        self.assertEqual(storage.plan(self.ctx)['items'], [])
        (Path(candidate['checkout']) / 'untracked').unlink()
        (self.root / '.git/info/exclude').write_text('ignored\n')
        (Path(candidate['checkout']) / 'ignored').write_text('valuable too')
        self.age_tree(directory)
        self.assertEqual(storage.plan(self.ctx)['items'], [])

    def test_candidate_with_open_or_unreachable_pr_is_protected(self):
        directory, candidate = self.candidate()
        candidate['pr'] = 'https://github.com/owner/repo/pull/1'
        self.ctx.save('candidates/resolved/candidate.json', candidate)
        self.age_tree(directory)
        real_run = storage.run
        def lookup(argv, **kwargs):
            if argv[0] == 'gh':
                return type('Result', (), {'stdout': json.dumps({'state': 'OPEN', 'headRefOid': candidate['head']})})()
            return real_run(argv, **kwargs)
        with patch.object(storage, 'run', side_effect=lookup):
            self.assertEqual(storage.plan(self.ctx)['items'], [])
        with patch.object(storage, 'run', side_effect=RuntimeError('offline')):
            self.assertEqual(storage.plan(self.ctx)['items'], [])

    def test_recent_two_applied_and_last_good_generations_are_protected(self):
        directory, candidate = self.candidate(state='applied')
        self.assertEqual(storage.plan(self.ctx)['items'], [])
        candidate['status'] = 'superseded'
        target = '/nix/store/' + 'a' * 32 + '-nixos-system-test'
        candidate['validation'] = {'build_path': target}
        self.ctx.save('candidates/resolved/candidate.json', candidate)
        self.ctx.save('last-application.json', {'previous_system': target})
        self.age_tree(directory)
        self.assertEqual(storage.plan(self.ctx)['items'], [])

    def test_active_editor_pointer_protects_retained_candidate_checkout(self):
        directory, candidate = self.candidate()
        self.ctx.save('active-editor.json', {'kind': 'active-editor', 'profiles': {'default': {
            'root': candidate['checkout'], 'revision': candidate['head'], 'selected_at': '2020-01-01T00:00:00+00:00'}}})
        self.assertEqual(storage.plan(self.ctx)['items'], [])
        self.assertTrue(directory.exists())

    def test_active_controller_source_protects_older_candidate(self):
        directory, candidate = self.candidate()
        self.ctx.save('active-source.json', {'kind': 'active-source', 'root': candidate['checkout'],
                                            'revision': candidate['head'], 'candidate': candidate['id']})
        self.assertEqual(storage.plan(self.ctx)['items'], [])
        self.assertTrue(directory.exists())

    def test_pending_system_application_protects_previous_source_and_generation(self):
        directory, candidate = self.candidate()
        target = '/nix/store/' + 'd' * 32 + '-nixos-system-recovery'
        candidate['validation'] = {'build_path': target}
        self.ctx.save('candidates/resolved/candidate.json', candidate)
        self.age_tree(directory)
        for pending in ({'previous_active_source': {'present': True, 'value': {'root': candidate['checkout']}}},
                        {'previous_system': target}):
            self.ctx.save('pending-system-application.json', pending)
            self.assertEqual(storage.plan(self.ctx)['items'], [])
            self.assertTrue(directory.exists())
        (self.ctx.state / 'pending-system-application.json').unlink()
        self.assertEqual([item['path'] for item in storage.plan(self.ctx)['items']], [str(directory)])

    def test_live_managed_symlink_protects_candidate_without_recent_receipt(self):
        directory, candidate = self.candidate()
        home = self.root.parent / 'test-home'
        home.mkdir()
        (home / '.zshrc').symlink_to(Path(candidate['checkout']) / '.zshrc')
        with patch.object(storage.Path, 'home', return_value=home):
            result = storage.plan(self.ctx)
        self.assertEqual(result['items'], [])
        self.assertTrue(directory.exists())

    def test_maintenance_lock_prevents_candidate_cleanup_during_activation(self):
        directory, _ = self.candidate()
        with self.ctx.lock('maintenance'):
            with self.assertRaisesRegex(RuntimeError, 'maintenance is already running'):
                storage.cleanup(self.ctx)
        self.assertTrue(directory.exists())


if __name__ == '__main__':
    unittest.main()
