#!/usr/bin/env python3
"""Boundaries that prevent maintenance preparation from mutating a machine."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
import adapters
from core import Context, atomic, read


def result(stdout='', returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, '')


class Adapters(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'candidate'
        self.work = Path(self.tmp.name) / 'work'
        self.root.mkdir()
        (self.root / 'flake.nix').write_text('{}')
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        subprocess.run(['git', '-C', self.root, 'add', 'flake.nix'], check=True)
        subprocess.run(['git', '-C', self.root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.ctx = Context(self.root, Path(self.tmp.name) / 'state')

    def write(self, relative, data):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        atomic(target, data)

    def test_candidate_does_not_use_default_checkout(self):
        with patch.object(adapters, '_require'), patch.object(adapters, '_release_module'), patch.object(adapters, '_shell'), patch.object(adapters, 'run') as run:
            adapters.prepare(self.ctx, 'system', self.root, self.work)
        command = run.call_args.args[0]
        self.assertEqual(command[-1], adapters.nix_source(self.root))
        self.assertEqual(tuple(command[3:-2]), adapters.SYSTEM_INPUTS)
        self.assertNotIn('mango', command)
        self.assertNotIn('migration-nixpkgs', command)
        self.assertNotIn('nvidia-afx-nixpkgs', command)

    def test_system_update_never_resolves_os_release(self):
        with patch.object(adapters, '_require'), patch.object(adapters, '_release_module') as release, patch.object(adapters, '_shell'), patch.object(adapters, '_nix_update'):
            adapters.prepare(self.ctx, 'system', self.root, self.work)
        release.return_value.refs.assert_not_called()
        release.return_value.update_flake.assert_not_called()

    def test_os_release_group_only_changes_os_inputs(self):
        with patch.object(adapters, '_require'), patch.object(adapters, '_release_module') as release, patch.object(adapters, '_nix_update') as update:
            module = release.return_value
            module.refs.side_effect = [['26.05', '26.11'], ['nixos-26.11'], ['release-26.11'], ['nix-darwin-26.11']]
            module.version.side_effect = lambda value: value
            module.replace_ref.side_effect = lambda source, repo, ref: source + '\n' + repo + '/' + ref
            adapters.prepare(self.ctx, 'os-release', self.root, self.work)
        update.assert_called_once_with(self.root, adapters.RELEASE_INPUTS)
        module.update_desktop.assert_not_called()
        module.update_flake.assert_not_called()
        self.assertNotIn('stateVersion', (self.root / 'flake.nix').read_text())

    def test_drivers_hold_is_explicit_and_has_no_mutation(self):
        with patch.object(adapters, 'run') as run:
            with self.assertRaisesRegex(adapters.AdapterHold, 'game-specific'):
                adapters.prepare(self.ctx, 'drivers', self.root, self.work)
        run.assert_not_called()
        self.assertEqual((self.root / 'flake.nix').read_text(), '{}')

    def test_editor_prepare_only_calls_isolated_action(self):
        self.write('nvim/lazy-lock.json', {'plugin': {'commit': 'a'}})
        self.write('nvim/mason-lock.json', {'schema_version': 1, 'packages': {'tool': '1'}})
        self.write('nvim/lazy-lock.macos-managed.json', {})
        self.write('nvim/mason-lock.macos-managed.json', {'schema_version': 1, 'packages': {}})
        with patch.object(adapters, '_require'), patch.object(adapters, '_shell') as shell:
            evidence = adapters.prepare(self.ctx, 'editor', self.root, self.work)
        self.assertEqual(shell.call_count, 2)
        self.assertEqual([call.kwargs['profile'] for call in shell.call_args_list], ['tracer', 'macos-managed'])
        self.assertTrue(evidence['runtime_isolated'])

    def test_editor_check_rejects_mutated_lock(self):
        self.write('nvim/lazy-lock.json', {'plugin': {'commit': 'a'}})
        self.write('nvim/mason-lock.json', {'schema_version': 1, 'packages': {'tool': '1'}})
        self.write('nvim/lazy-lock.macos-managed.json', {})
        self.write('nvim/mason-lock.macos-managed.json', {'schema_version': 1, 'packages': {}})
        with patch.object(adapters, '_require'), patch.object(adapters, '_shell', side_effect=lambda *a, **kw: self.write('nvim/mason-lock.json', {'tool': '2'})):
            with self.assertRaisesRegex(RuntimeError, 'changed reviewed locks'):
                adapters.check(self.ctx, 'editor', self.root, self.work)

    def test_editor_apply_receipt_is_resumable_without_second_restore(self):
        self.write('nvim/lazy-lock.json', {})
        self.write('nvim/mason-lock.json', {'schema_version': 1, 'packages': {}})
        with patch.object(adapters, '_shell') as shell:
            adapters.apply(self.ctx, 'editor', self.root, self.work, profile='tracer')
            adapters.apply(self.ctx, 'editor', self.root, self.work, profile='tracer')
        self.assertEqual(shell.call_count, 1)
        self.write('nvim/mason-lock.json', {'schema_version': 1, 'packages': {'tool': '2'}})
        with self.assertRaisesRegex(adapters.AdapterHold, 'pins changed'):
            adapters.apply(self.ctx, 'editor', self.root, self.work, profile='tracer')

    def test_editor_validation_rejects_source_change_outside_locks(self):
        for variant in ('tracer', 'macos-managed'):
            for relative in adapters.editor_locks(variant):
                self.write(relative, {})
        with patch.object(adapters, '_require'), patch.object(adapters, '_shell',
                side_effect=lambda *a, **kw: (self.root / 'flake.nix').write_text('{changed = true;}')):
            with self.assertRaisesRegex(RuntimeError, 'source changed while validation'):
                adapters.check(self.ctx, 'editor', self.root, self.work)

    def test_failed_editor_apply_keeps_selected_config(self):
        for relative in adapters.editor_locks('tracer'):
            self.write(relative, {})
        previous = {'schema_version': 1, 'profiles': {'default': {'root': '/retained/previous'}}}
        self.ctx.save('active-editor.json', previous)
        with patch.object(adapters, '_shell', side_effect=RuntimeError('download interrupted')):
            with self.assertRaisesRegex(RuntimeError, 'download interrupted'):
                adapters.apply(self.ctx, 'editor', self.root, self.work, profile='tracer')
        self.assertEqual(self.ctx.load('active-editor.json'), previous)
        self.assertEqual(read(self.work / 'adapter-apply.json')['status'], 'failed')

    @unittest.skipUnless(shutil.which('nvim'), 'native Neovim is needed to exercise ordinary startup')
    def test_ordinary_editor_launch_uses_applied_config_not_developer_checkout(self):
        source = Path(__file__).resolve().parents[1]
        for relative in adapters.editor_locks('tracer'):
            self.write(relative, {})
        nvim = self.root / 'nvim'
        (nvim / 'lua/config').mkdir(parents=True)
        (nvim / 'init.lua').write_text((source / 'nvim/init.lua').read_text())
        (nvim / 'lua/config/lazy.lua').write_text('vim.fn.writefile({vim.g.dotfiles_editor_root}, vim.env.DOTCTL_CAPTURE)')
        with patch.object(adapters, '_shell'):
            adapters.apply(self.ctx, 'editor', self.root, self.work, profile='tracer')
        capture = Path(self.tmp.name) / 'selected.txt'
        initial = Path(self.tmp.name) / 'initial-init.lua'
        initial.write_text((source / 'nvim/init.lua').read_text())
        env = {**os.environ, 'DOTCTL_STATE_HOME': str(self.ctx.state), 'DOTCTL_CAPTURE': str(capture),
               'DOTFILES_ROOT': '/unrelated/developer-checkout', 'DOTFILES_NVIM_CONFIG_ROOT': '/unrelated/stale-config',
               'DOTFILES_PROFILE': 'tracer', 'XDG_STATE_HOME': str(Path(self.tmp.name) / 'xdg-state'),
               'XDG_DATA_HOME': str(Path(self.tmp.name) / 'xdg-data'), 'XDG_CACHE_HOME': str(Path(self.tmp.name) / 'xdg-cache')}
        env.pop('DOTFILES_NVIM_AUTOMATION', None)
        subprocess.run(['nvim', '--headless', '-i', 'NONE', '-u', initial, '+qa'], env=env, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(capture.read_text().strip(), str(nvim))

    def test_runtime_under_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            adapters.prepare(self.ctx, 'editor', self.root, self.root / 'temp')

    def test_nix_check_rejects_untracked_source_without_staging_developer_index(self):
        (self.root / 'new-module.nix').write_text('{}')
        before = subprocess.check_output(['git', '-C', self.root, 'diff', '--cached'])
        with patch.object(adapters, '_require'):
            with self.assertRaisesRegex(adapters.AdapterHold, 'refuses untracked source files'):
                adapters.check(self.ctx, 'system', self.root, self.work)
        self.assertEqual(subprocess.check_output(['git', '-C', self.root, 'diff', '--cached']), before)

    @unittest.skipUnless(shutil.which('nvim'), 'native Neovim is needed to exercise reviewed plugin pins')
    def test_plugin_bootstrap_and_restore_keep_older_reviewed_commits(self):
        # Real Git history makes the reviewed pin differ from both HEAD and
        # stable. No external repository or network is needed in the Nix check.
        plugin = Path(self.tmp.name) / 'plugin-origin'
        plugin.mkdir()
        subprocess.run(['git', 'init', '-q', plugin], check=True)
        commits = []
        for contents in ('reviewed', 'newer'):
            (plugin / 'version').write_text(contents)
            subprocess.run(['git', '-C', plugin, 'add', 'version'], check=True)
            subprocess.run(['git', '-C', plugin, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                            'commit', '-qm', contents], check=True)
            commits.append(subprocess.check_output(['git', '-C', plugin, 'rev-parse', 'HEAD'], text=True).strip())
        subprocess.run(['git', '-C', plugin, 'branch', 'stable'], check=True)
        lock = Path(self.tmp.name) / 'reviewed.json'
        # Deliberately nonstandard whitespace proves byte preservation.
        original = json.dumps({'first': {'commit': commits[0], 'branch': 'main'},
                               'later-import': {'commit': commits[0], 'branch': 'main'}}, indent=3).encode()
        lock.write_bytes(original)
        destination = Path(self.tmp.name) / 'fresh-plugin'
        script = Path(self.tmp.name) / 'verify.lua'
        module = Path(__file__).resolve().parents[1] / 'nvim/lua/config/plugin_pins.lua'
        script.write_text('''
local pins = dofile(vim.env.DOTCTL_PIN_MODULE)
pins.bootstrap(vim.env.DOTCTL_PLUGIN_DEST, vim.env.DOTCTL_REVIEWED_COMMIT, vim.env.DOTCTL_PLUGIN_ORIGIN)
assert(vim.fn.readfile(vim.env.DOTCTL_PLUGIN_DEST .. '/version')[1] == 'reviewed')
-- Reproduce Lazy's destructive first-round writer and missing later spec.
local lock = { update = function() error('original lock writer must not run') end }
package.loaded['lazy.manage.lock'] = lock
pins.protect(vim.env.DOTCTL_REVIEWED_LOCK)
lock.update()
assert(lock.get({name='later-import'}).commit == vim.env.DOTCTL_REVIEWED_COMMIT)
assert(not pcall(lock.get, {name='unreviewed-plugin'}))
package.loaded['lazy.core.config'] = {plugins={first={
  dir=vim.env.DOTCTL_PLUGIN_DEST, _={installed=true}
}}}
assert(pins.verify())
vim.fn.system({'git', '-C', vim.env.DOTCTL_PLUGIN_DEST, 'checkout', '--detach', vim.env.DOTCTL_NEWER_COMMIT})
assert(vim.v.shell_error == 0)
local ok, err = pcall(pins.verify)
assert(not ok and tostring(err):find('differs from reviewed commit', 1, true))
''')
        env = {**os.environ, 'DOTCTL_PIN_MODULE': str(module), 'DOTCTL_PLUGIN_DEST': str(destination),
               'DOTCTL_PLUGIN_ORIGIN': str(plugin), 'DOTCTL_REVIEWED_COMMIT': commits[0],
               'DOTCTL_NEWER_COMMIT': commits[1], 'DOTCTL_REVIEWED_LOCK': str(lock),
               'XDG_STATE_HOME': str(Path(self.tmp.name) / 'xdg-state'),
               'XDG_DATA_HOME': str(Path(self.tmp.name) / 'xdg-data'),
               'XDG_CACHE_HOME': str(Path(self.tmp.name) / 'xdg-cache')}
        subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', script], env=env,
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(lock.read_bytes(), original)

    def test_nix_activation_cannot_escape_controller_gate(self):
        with self.assertRaisesRegex(adapters.AdapterHold, 'controller receipt'):
            adapters.apply(self.ctx, 'system', self.root, self.work)

    def test_recipe_identity_ignores_installed_state_and_tracks_recipe(self):
        base = {'versions': {'stable': '1.2'}, 'revision': 1, 'full_name': 'foo',
                'ruby_source_checksum': {'sha256': 'a'}, 'installed': []}
        target, initial = adapters._brew_recipe('formula', base)
        self.assertEqual(target, '1.2_1')
        changed = dict(base, installed=[{'version': '1'}], outdated=True)
        self.assertEqual(adapters._brew_recipe('formula', changed)[1], initial)
        changed['ruby_source_checksum'] = {'sha256': 'b'}
        self.assertNotEqual(adapters._brew_recipe('formula', changed)[1], initial)
        with self.assertRaises(adapters.AdapterHold):
            adapters._brew_recipe('cask', {'version': 'latest'})

    def manifest(self):
        return {'brewfiles': {'file': 'digest'}, 'packages': {
            'formula:one': {'name': 'one', 'kind': 'formula', 'target': '1', 'recipe_identity': 'a'},
            'formula:two': {'name': 'two', 'kind': 'formula', 'target': '2', 'recipe_identity': 'b'}},
            'manual_holds': {}, 'native_components': {}, 'ai_policy': 'Claude only'}

    def test_mac_drift_aborts_before_any_package_install(self):
        manifest = self.manifest()
        self.write(adapters.MAC_MANIFEST, manifest)
        current = self.manifest()
        current['packages']['formula:one']['recipe_identity'] = 'changed'
        with patch.object(adapters, 'resolve_mac', return_value=current), patch.object(adapters, '_brew') as brew:
            with self.assertRaisesRegex(adapters.AdapterHold, 'Prepare and review'):
                adapters.apply(self.ctx, 'mac', self.root, self.work)
        brew.assert_not_called()

    def test_nightly_hold_does_not_block_other_mac_packages_or_install_codex(self):
        for relative in adapters.BREWFILES:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('')
        def brew(*args):
            if args[0] == 'update':
                return result()
            if args[:2] == ('bundle', 'list'):
                managed = 'macos-managed' in args[3]
                return result('claude-code\n' if managed and args[-1] == '--cask' else
                              'wezterm@nightly\n' if not managed and args[-1] == '--cask' else '')
            name = args[-1]
            entry = {'version': 'latest' if name == 'wezterm@nightly' else '2.0.1',
                     'token': name, 'ruby_source_checksum': {'sha256': 'recipe'}}
            return result(json.dumps({'casks': [entry]}))
        with patch.object(adapters.platform, 'system', return_value='Darwin'), patch.object(adapters, '_require'), \
             patch.object(adapters, '_brew', side_effect=brew), patch.object(adapters, 'lan_mouse_pin', return_value={'version': '0.11.0'}), \
             patch.object(adapters, 'run') as native:
            manifest = adapters.resolve_mac(self.root, refresh=True)
        native.assert_not_called()
        self.assertIn('cask:claude-code', manifest['packages'])
        self.assertIn('cask:wezterm@nightly', manifest['manual_holds'])
        self.assertNotIn('bun_codex', manifest)
        self.write(adapters.MAC_MANIFEST, manifest)
        with patch.object(adapters, 'resolve_mac', return_value=manifest), patch.object(adapters, '_installed_matches', return_value=True), \
             patch.object(adapters, '_shell'), patch.object(adapters, '_brew') as brew_mutation:
            receipt = adapters.apply(self.ctx, 'mac', self.root, self.work)
        brew_mutation.assert_not_called()
        self.assertEqual(receipt['status'], 'applied-with-holds')
        self.assertTrue(any(stage['status'] == 'held' for stage in receipt['stages']))

    def test_mac_partial_failure_keeps_successful_package_receipt(self):
        manifest = self.manifest()
        self.write(adapters.MAC_MANIFEST, manifest)
        with patch.object(adapters, 'resolve_mac', return_value=manifest), patch.object(adapters, '_require'), \
             patch.object(adapters, '_installed_matches', side_effect=[False, True, False]), \
             patch.object(adapters, 'run', return_value=result(returncode=1)), \
             patch.object(adapters, '_brew', side_effect=[result(), RuntimeError('download failed')]) as brew:
            with self.assertRaisesRegex(RuntimeError, 'download failed'):
                adapters.apply(self.ctx, 'mac', self.root, self.work)
        receipt = read(self.work / 'adapter-apply.json')
        self.assertEqual(receipt['status'], 'partial-failure')
        self.assertEqual(receipt['stages'][0]['name'], 'formula:one')
        self.assertEqual(receipt['stages'][0]['status'], 'applied')
        self.assertEqual(brew.call_count, 2)

    def test_acceptance_reads_installed_receipts_and_parser_revisions(self):
        self.write('nvim/lazy-lock.json', {'example': {'commit': 'abc'}, 'disabled-plugin': {'commit': 'def'}})
        self.write('nvim/mason-lock.json', {'packages': {'cmakelang': '0.6.13'}})
        live = Path(self.tmp.name) / 'live'
        validation = Path(self.tmp.name) / 'validated'
        (live / 'lazy/example').mkdir(parents=True)
        atomic(live / 'mason/packages/cmakelang/mason-receipt.json',
               {'source': {'id': 'pkg:pypi/cmakelang@0.6.13?extra=YAML'}})
        for runtime in (live, validation):
            (runtime / 'site/parser-info').mkdir(parents=True)
            (runtime / 'site/parser-info/lua.revision').write_text('revision-a')
            (runtime / 'site/queries/lua').mkdir(parents=True)
        manifest = {'schema_version': 1, 'lock_sha256': adapters.digest(self.root / 'nvim/lazy-lock.json'),
                    'plugins': {'example': 'abc'}, 'inactive': ['disabled-plugin']}
        atomic(validation / 'dotfiles-plugin-pins.json', manifest)
        (live / 'site/parser').mkdir()
        (live / 'site/parser/lua.so').write_bytes(b'compiled parser')
        with patch.object(adapters, 'run', return_value=result('abc')):
            evidence = adapters._installed_editor_evidence(self.root, validation, live)
            self.assertEqual(evidence['mason']['cmakelang'], '0.6.13')
            self.assertEqual(evidence['inactive_plugins'], ['disabled-plugin'])
            (live / 'site/parser-info/lua.revision').write_text('old-revision')
            with self.assertRaisesRegex(adapters.AdapterHold, 'parser lua differs'):
                adapters._installed_editor_evidence(self.root, validation, live)
        with patch.object(adapters, 'run', return_value=result('old-commit')):
            with self.assertRaisesRegex(adapters.AdapterHold, 'plugin example differs'):
                adapters._installed_editor_evidence(self.root, validation, live)
        manifest['lock_sha256'] = 'stale'
        atomic(validation / 'dotfiles-plugin-pins.json', manifest)
        with self.assertRaisesRegex(adapters.AdapterHold, 'no matching active-plugin evidence'):
            adapters._installed_editor_evidence(self.root, validation, live)

    def test_shell_editor_preparation_does_not_inherit_live_xdg(self):
        # Execute the real shell boundary with a fake Neovim runtime recorder.
        source = Path(__file__).resolve().parents[1]
        for relative in ('scripts/maintenance-adapter.sh', 'scripts/lib/common.sh', 'scripts/commands/update.sh'):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((source / relative).read_text())
        (self.root / 'nvim').mkdir()
        binary = Path(self.tmp.name) / 'bin'
        binary.mkdir()
        capture = Path(self.tmp.name) / 'env.json'
        nvim = binary / 'nvim'
        nvim.write_text('#!' + sys.executable + '\nimport os,json\nfrom pathlib import Path\nPath(os.environ["CAPTURE"]).write_text(json.dumps(dict(os.environ)))\n')
        nvim.chmod(0o755)
        # Hide nix to avoid the existing host-runtime path preference; purpose
        # here is XDG isolation, not shell tool discovery.
        for executable in ('bash', 'dirname', 'mkdir', 'ln', 'readlink', 'uname', 'python3'):
            location = __import__('shutil').which(executable)
            (binary / executable).symlink_to(location)
        env = {**os.environ, 'PATH': str(binary), 'CAPTURE': str(capture),
               'XDG_DATA_HOME': '/never-touch/live-data', 'XDG_CACHE_HOME': '/never-touch/live-cache',
               'XDG_STATE_HOME': '/never-touch/live-state'}
        subprocess.run([str(binary / 'bash'), self.root / 'scripts/maintenance-adapter.sh', 'editor-prepare',
                        self.root, self.work, 'tracer'], env=env, check=True)
        observed = read(capture)
        for key, child in [('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'), ('XDG_CONFIG_HOME', 'config')]:
            self.assertEqual(observed[key], str(self.work / child))
        self.assertEqual(observed['DOTFILES_ROOT'], str(self.root))
        self.assertEqual(observed['DOTFILES_NVIM_PIN_UPDATE'], '1')
        self.assertEqual(observed['DOTFILES_NVIM_PLUGIN_UPDATE'], '1')
        subprocess.run([str(binary / 'bash'), self.root / 'scripts/maintenance-adapter.sh', 'editor-check',
                        self.root, self.work, 'tracer'], env=env, check=True)
        self.assertEqual(read(capture)['DOTFILES_NVIM_PLUGIN_UPDATE'], '0')


if __name__ == '__main__':
    unittest.main()
