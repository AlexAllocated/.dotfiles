import datetime as dt
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context
import scheduling as s


class Schedules(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = Context(Path(self.tmp.name), Path(self.tmp.name) / 'state')

    def test_daily_catchup_before_schedule_uses_yesterday(self):
        date = dt.datetime(2026, 10, 19, 8, tzinfo=dt.timezone.utc)
        _, slot = s.due(self.ctx, 'daily', date)
        self.assertEqual(slot, '2026-10-18T09:00:00+00:00')

    def test_weekly_catchup_uses_last_sunday(self):
        date = dt.datetime(2026, 10, 19, 8, tzinfo=dt.timezone.utc)
        _, slot = s.due(self.ctx, 'weekly', date)
        self.assertEqual(slot, '2026-10-18T04:00:00+00:00')

    def test_sunday_before_four_uses_previous_week(self):
        date = dt.datetime(2026, 10, 18, 3, tzinfo=dt.timezone.utc)
        self.assertEqual(s.due(self.ctx, 'weekly', date)[1], '2026-10-11T04:00:00+00:00')

    def test_failed_or_interrupted_run_can_retry_slot(self):
        date = dt.datetime(2026, 10, 19, 10, tzinfo=dt.timezone.utc)
        _, slot = s.due(self.ctx, 'daily', date)
        for status in ('failed', 'running'):
            self.ctx.save('schedule-daily.json', {'slot': slot, 'status': status})
            self.assertTrue(s.due(self.ctx, 'daily', date)[0])
        self.ctx.save('schedule-daily.json', {'slot': slot, 'status': 'completed'})
        self.assertFalse(s.due(self.ctx, 'daily', date)[0])

    def test_acceptance_requires_same_tree_on_both_hosts(self):
        for host in ('tracer', 'work-mac'):
            self.ctx.save(f'acceptance/{host}.json', self.receipt(host, tree=host))
        with self.assertRaisesRegex(RuntimeError, 'different source trees'):
            s.accepted(self.ctx)

    def receipt(self, host, tree='tree', digest='source-digest'):
        checks = {'ok': True, 'dirty': False, 'revision': 'revision',
                  'result': {'source_digest': digest, 'build_path': '/nix/store/test-system'}}
        if host == 'work-mac':
            checks['live'] = {'kind': 'native-mac-acceptance', 'status': 'accepted',
                              'editor_check': {'source_digest': digest}}
        return {'kind': 'host-acceptance', 'host': host, 'checks': checks,
                'platform': 'Darwin' if host == 'work-mac' else 'Linux',
                'tree': tree, 'revision': 'revision', 'source_digest': digest}

    def test_tracer_receipt_cannot_stand_in_for_mac_acceptance(self):
        self.ctx.save('acceptance/tracer.json', self.receipt('tracer'))
        self.ctx.save('acceptance/work-mac.json', self.receipt('tracer'))
        with self.assertRaisesRegex(RuntimeError, 'actual host acceptance: work-mac'):
            s.accepted(self.ctx)

    def test_mac_recipe_checks_without_live_installation_are_rejected(self):
        self.ctx.save('acceptance/tracer.json', self.receipt('tracer'))
        mac = self.receipt('work-mac')
        del mac['checks']['live']
        self.ctx.save('acceptance/work-mac.json', mac)
        with self.assertRaisesRegex(RuntimeError, 'actual host acceptance: work-mac'):
            s.accepted(self.ctx)

    def test_same_git_tree_with_different_validated_bytes_is_rejected(self):
        self.ctx.save('acceptance/tracer.json', self.receipt('tracer'))
        self.ctx.save('acceptance/work-mac.json', self.receipt('work-mac', digest='different-bytes'))
        with self.assertRaisesRegex(RuntimeError, 'different source trees'):
            s.accepted(self.ctx)

    def test_matching_native_receipts_satisfy_acceptance_gate(self):
        for host in ('tracer', 'work-mac'):
            self.ctx.save(f'acceptance/{host}.json', self.receipt(host))
        self.assertEqual(set(s.accepted(self.ctx)), {'tracer', 'work-mac'})

    def test_source_commit_after_checks_cannot_be_accepted(self):
        revision = ['revision']
        def git(*args):
            return '' if args[0] == 'status' else revision[0] if args[-1] == 'HEAD' else 'tree'
        def check(*args, **kwargs):
            revision[0] = 'new-unchecked-commit'
            return {'ok': True, 'dirty': False, 'revision': 'revision', 'result': {
                'source_digest': 'digest', 'build_path': str(Path('/run/current-system').resolve())}}
        with patch.object(self.ctx, 'git', side_effect=git), \
             patch.object(s.maintenance, 'local_profile', return_value='tracer'), \
             patch.object(s.adapters, '_source_digest', return_value='digest'), \
             patch.object(s.maintenance, 'check', side_effect=check):
            with self.assertRaisesRegex(RuntimeError, 'Source changed during native acceptance'):
                s.acceptance(self.ctx)
        self.assertIsNone(self.ctx.load('acceptance/tracer.json'))

    def test_check_result_for_different_source_is_rejected(self):
        def git(*args):
            return '' if args[0] == 'status' else 'revision' if args[-1] == 'HEAD' else 'tree'
        with patch.object(self.ctx, 'git', side_effect=git), \
             patch.object(s.maintenance, 'local_profile', return_value='tracer'), \
             patch.object(s.adapters, '_source_digest', return_value='digest'), \
             patch.object(s.maintenance, 'check', return_value={'ok': True, 'dirty': False,
                 'revision': 'other-revision', 'result': {'source_digest': 'digest'}}):
            with self.assertRaisesRegex(RuntimeError, 'different source revision'):
                s.acceptance(self.ctx)
        self.assertIsNone(self.ctx.load('acceptance/tracer.json'))

    def test_launch_agents_use_active_source_entrypoint_and_remain_disabled(self):
        home = Path(self.tmp.name) / 'home'
        with patch.object(s.Path, 'home', return_value=home), \
             patch.object(s.maintenance, 'local_profile', return_value='macos-managed'), \
             patch.object(s, 'run') as run:
            result = s.install(self.ctx, enable=False)
        self.assertFalse(result['enabled'])
        run.assert_not_called()
        for name in ('daily', 'weekly'):
            data = plistlib.loads((home / 'Library/LaunchAgents' / ('local.dotfiles.' + name + '.plist')).read_bytes())
            self.assertEqual(data['ProgramArguments'], [str(home / '.local/bin/dotctl'), 'schedule', name])
            self.assertEqual(data['WorkingDirectory'], str(home))
            self.assertEqual(data['EnvironmentVariables']['DOTFILES_ROOT'], '')

    def test_disabled_job_does_no_work(self):
        with patch.object(s.status, 'refresh') as refresh:
            self.assertEqual(s.run_job(self.ctx, 'daily')['status'], 'disabled')
            refresh.assert_not_called()


if __name__ == '__main__':
    unittest.main()
