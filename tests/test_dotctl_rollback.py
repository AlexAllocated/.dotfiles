"""OS rollback survives editor deployments and restores the matching controller source."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context
import maintenance as m


class RollbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'scripts/dotctl').write_text('# fixture\n')
        self.ctx = Context(self.root, Path(self.tmp.name) / 'state')
        for args in (('init', '-b', 'main'), ('config', 'user.name', 'Fixture'),
                     ('config', 'user.email', 'fixture@example.invalid'), ('add', '.'), ('commit', '-m', 'fixture')):
            subprocess.run(['git', '-C', str(self.root), *args], check=True, text=True, capture_output=True)
        self.revision = subprocess.run(['git', '-C', str(self.root), 'rev-parse', 'HEAD'],
                                       check=True, text=True, capture_output=True).stdout.strip()
        self.old = '/nix/store/' + 'a' * 32 + '-nixos-system-old'
        self.new = '/nix/store/' + 'b' * 32 + '-nixos-system-new'
        self.current = self.old
        self.profile = self.old
        exists, resolve = Path.exists, Path.resolve
        def fake_exists(path):
            if str(path) in {self.old + '/bin/switch-to-configuration', self.new + '/bin/switch-to-configuration', '/run/current-system'}:
                return True
            return exists(path)
        def fake_resolve(path, *args, **kwargs):
            if str(path) == '/run/current-system':
                return Path(self.current)
            if str(path) == '/nix/var/nix/profiles/system':
                return Path(self.profile)
            return resolve(path, *args, **kwargs)
        for context in (patch.object(Path, 'exists', fake_exists), patch.object(Path, 'resolve', fake_resolve)):
            context.start()
            self.addCleanup(context.stop)

    def candidate(self, group):
        return {'id': group + '-fixture', 'group': group, 'profile': 'tracer', 'activation_checkout': str(self.root),
                'work': str(self.ctx.state / ('work-' + group)), 'merged_revision': self.revision,
                'activation_validation': {'build_path': self.new}, 'stages': {}}

    def apply(self, group):
        def activation(*args):
            if group == 'system':
                self.current = self.profile = self.new
            return {'status': 'applied', 'target': self.current}
        with patch.object(m, 'apply_checked', side_effect=activation):
            m.activate(self.ctx, self.candidate(group))

    def rollback(self):
        real_run = m.run
        def run(argv, **kwargs):
            if argv[0] == 'git':
                return real_run(argv, **kwargs)
            self.assertEqual(argv[0], 'sudo')
            if argv[1] == 'nix-env':
                self.profile = argv[-1]
            elif argv[1].endswith('/bin/switch-to-configuration'):
                self.current = str(Path(argv[1]).parents[1])
            else:
                self.fail('Unexpected privileged action')
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(m, 'run', side_effect=run), patch.object(m.sys.stdin, 'isatty', return_value=True), \
             patch('builtins.input', return_value='yes'):
            return m.rollback(self.ctx)

    def test_system_then_editor_retains_system_rollback_target(self):
        self.apply('system')
        original = self.ctx.load('last-system-application.json')
        self.apply('editor')
        self.assertEqual(self.ctx.load('last-application.json')['group'], 'editor')
        self.assertEqual(self.ctx.load('last-system-application.json'), original)
        self.assertEqual(self.rollback()['target'], self.old)
        self.assertEqual(self.current, self.old)

    def test_rollback_restores_exact_previous_source_pointer(self):
        previous = {'kind': 'active-source', 'root': str(self.root), 'revision': self.revision,
                    'extra_evidence': 'must be preserved'}
        self.ctx.save('active-source.json', previous)
        self.apply('system')
        self.assertNotEqual(self.ctx.load('active-source.json'), previous)
        self.rollback()
        self.assertEqual(self.ctx.load('active-source.json'), previous)

    def test_plain_source_apply_then_editor_keeps_system_receipt(self):
        def activation(ctx, group, *args):
            if group == 'system':
                self.current = self.profile = self.new
            return {'status': 'applied', 'target': self.current}
        with patch.object(m.adapters, 'check', return_value={'build_path': self.new}), \
             patch.object(m, 'apply_checked', side_effect=activation):
            m.apply_revision(self.ctx, profile='tracer')
            original = self.ctx.load('last-system-application.json')
            m.apply_revision(self.ctx, profile='tracer', group='editor')
        self.assertEqual(original['previous_system'], self.old)
        self.assertEqual(self.ctx.load('last-system-application.json'), original)
        self.assertEqual(self.rollback()['target'], self.old)

    def test_rollback_removes_pointer_when_previous_generation_had_none(self):
        self.assertFalse((self.ctx.state / 'active-source.json').exists())
        self.apply('system')
        self.assertTrue((self.ctx.state / 'active-source.json').exists())
        self.rollback()
        self.assertFalse((self.ctx.state / 'active-source.json').exists())

    def test_changed_previous_source_holds_rollback_before_os_mutation(self):
        self.ctx.save('active-source.json', {'root': str(self.root), 'revision': self.revision})
        self.apply('system')
        (self.root / 'scripts/dotctl').write_text('unreviewed source change')
        with self.assertRaisesRegex(RuntimeError, 'Previous controller source changed'):
            self.rollback()
        self.assertEqual(self.current, self.new)
        self.assertEqual(self.profile, self.new)


if __name__ == '__main__':
    unittest.main()
