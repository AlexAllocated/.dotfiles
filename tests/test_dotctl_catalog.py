#!/usr/bin/env python3
"""Catalog coverage and read-only runtime behavior, without touching the host."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/dotfiles'))
import catalog
from core import Context


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'checkout'
        self.root.mkdir()
        (self.root / 'catalog').mkdir()
        self.ctx = Context(self.root, Path(self.tmp.name) / 'state')
        self.items = []

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, path, text):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def component(self, identity='helper', source='scripts/helper.py', **changes):
        item = {
            'id': identity, 'name': 'Helper', 'aliases': ['purpose words'],
            'purpose': 'An explicit helper for a known job.', 'capability': 'foundation',
            'platforms': ['nixos'], 'classification': 'unreviewed', 'sources': [source],
            'owns': [source], 'commands': ['helper'], 'startup': [], 'effects': [],
            'state_locations': [], 'installed_locations': [],
            'disable': 'Remove the declaration and apply the reviewed configuration.',
            'verification': {'procedure': 'Exercise the actual helper.', 'last_verified': None,
                             'evidence': 'Not yet verified live.'},
            'relationships': [], 'runtime': {'mode': 'manual'},
            'desired': {'state': 'native-evaluation-required', 'evidence': 'Consult the actual target profile.'},
        }
        item.update(changes)
        self.items.append(item)
        return item

    def save(self, snapshot=True, patches=None):
        self.write('catalog/components.json', json.dumps(self.items))
        self.write('catalog/patches.json', json.dumps(patches or []))
        if snapshot:
            self.write('catalog/surfaces.json', json.dumps({
                key: {**surface, 'owner': catalog.source_owner(surface['source'], self.items)}
                for key, surface in catalog.discovered(self.root).items()
            }))

    def errors(self):
        return '\n'.join(catalog.validate(self.ctx)['errors'])

    def test_new_executable_requires_explicit_catalog_review(self):
        self.write('scripts/helper.py', 'print("ready")\n')
        self.component()
        self.save()
        self.assertTrue(catalog.validate(self.ctx)['ok'])
        self.write('scripts/forgotten.py', 'print("forgotten")\n')
        errors = self.errors()
        self.assertIn('uncataloged operational surface: scripts/forgotten.py', errors)
        self.assertIn('unowned source: scripts/forgotten.py', errors)

    def test_generated_assets_do_not_change_clean_worktree_catalog(self):
        self.write('packages/amps/ui/.gitignore', 'web/\ntest-results/\n')
        self.write('packages/amps/ui/src/app.js', '// authoritative source\n')
        self.write('packages/amps/ui/web/assets/bundle.js', '// ignored generated bundle\n')
        self.write('packages/amps/ui/test-results/report.json', '{}\n')
        self.component('amps', source='packages/amps/ui')
        self.save()
        self.assertTrue(catalog.validate(self.ctx)['ok'])
        self.assertFalse(any('/web/' in key or '/test-results/' in key
                             for key in catalog.discovered(self.root)))

        def git(*args):
            subprocess.run(['git', '-C', str(self.root), *args], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        git('init', '-q')
        git('add', '.')
        git('-c', 'user.name=Catalog test', '-c', 'user.email=catalog@example.invalid',
            'commit', '-qm', 'catalog source fixture')
        clean = Path(self.tmp.name) / 'clean-worktree'
        git('worktree', 'add', '--detach', str(clean), 'HEAD')
        self.assertFalse((clean / 'packages/amps/ui/web').exists())
        self.assertEqual(catalog.discovered(self.root), catalog.discovered(clean))
        report = catalog.validate(Context(clean, Path(self.tmp.name) / 'clean-state'))
        self.assertTrue(report['ok'], '\n'.join(report['errors']))

    def test_generated_exclusions_do_not_hide_other_web_sources_or_ignored_helpers(self):
        self.write('packages/other/web/app.js', '// real source\n')
        self.write('scripts/.gitignore', 'forgotten.py\n')
        self.write('scripts/forgotten.py', 'print("must be reviewed")\n')
        found = catalog.discovered(self.root)
        self.assertIn('packages/other/web/app.js', found)
        self.assertIn('scripts/forgotten.py', found)

    def test_new_alias_or_service_inside_existing_block_is_detected(self):
        self.write('modules/sample.nix', '''{
  programs.zsh.shellAliases = { ls = "eza"; };
  systemd.user.services = {
    existing = { Service.ExecStart = "/bin/true"; };
  };
}''')
        self.component(source='modules/sample.nix')
        self.save()
        self.write('modules/sample.nix', '''{
  programs.zsh.shellAliases = { ls = "eza"; forgotten = "custom"; };
  systemd.user.services = {
    existing = { Service.ExecStart = "/bin/true"; };
    forgotten = { Service.ExecStart = "/bin/custom"; };
  };
}''')
        errors = self.errors()
        self.assertIn('attribute:programs.zsh.shellAliases.forgotten', errors)
        self.assertIn('attribute:systemd.user.services.forgotten', errors)

    def test_wrapper_command_name_change_is_detected(self):
        self.write('modules/helper.nix', 'pkgs.writeShellApplication {\n  name = "old-tool";\n  text = "true";\n}')
        self.component(source='modules/helper.nix')
        self.save()
        self.write('modules/helper.nix', 'pkgs.writeShellApplication {\n  name = "new-tool";\n  text = "true";\n}')
        self.assertIn('uncataloged operational surface: modules/helper.nix::name = "new-tool";', self.errors())

    def test_routine_pin_values_do_not_duplicate_native_configuration(self):
        self.write('packages/helper.nix', '{ version = "1.2.3"; rev = "old"; }')
        self.write('flake.nix', '{ nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"; }')
        before = catalog.discovered(self.root)
        self.write('packages/helper.nix', '{ version = "1.2.4"; rev = "new"; }')
        self.write('flake.nix', '{ nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.11"; }')
        self.assertEqual(before, catalog.discovered(self.root))
        self.write('flake.nix', '{ nixpkgs.url = "github:someone/other-repo/nixos-26.11"; }')
        self.assertNotEqual(before, catalog.discovered(self.root))

    def test_pin_normalization_preserves_new_declaration_slots(self):
        self.write('packages/helper.nix', '{\n  rev = "old";\n}')
        before = catalog.discovered(self.root)
        self.write('packages/helper.nix', '{\n  rev = "new";\n  nested = {\n    rev = "second";\n  };\n}')
        self.assertGreater(len(catalog.discovered(self.root)), len(before))

    def test_snapshot_alone_does_not_approve_an_inline_patch(self):
        self.write('packages/helper.nix', 'pkg.overrideAttrs (old: {\n  postPatch = "new code";\n})')
        self.component(source='packages/helper.nix')
        self.save()
        self.assertIn('customization missing lifecycle record:', self.errors())

    def test_repeated_patch_hooks_are_not_collapsed(self):
        self.write('packages/helper.nix', '''{
  one = {
    postPatch = "change";
  };
  two = {
    postPatch = "change";
  };
}''')
        found = catalog.discovered(self.root)
        hooks = [key for key in found if 'postPatch' in key]
        self.assertEqual(len(hooks), 2)
        self.assertTrue(any('occurrence-2' in key for key in hooks))

    def test_most_specific_owner_groups_internal_files(self):
        self.write('packages/app/src/main.rs', '// implementation\n')
        self.write('packages/app/tool.py', '# standalone helper\n')
        self.component('app', source='packages/app')
        self.component('helper', source='packages/app/tool.py')
        self.save()
        self.assertEqual(catalog.source_owner('packages/app/src/main.rs', self.items), 'app')
        self.assertEqual(catalog.source_owner('packages/app/tool.py', self.items), 'helper')
        self.assertTrue(catalog.validate(self.ctx)['ok'])

    def test_shared_source_references_do_not_claim_duplicate_ownership(self):
        self.write('modules/shared.nix', '{}')
        self.component('integration', source='modules/shared.nix')
        self.component('helper', source='modules/shared.nix', owns=[])
        self.save()
        self.assertTrue(catalog.validate(self.ctx)['ok'])
        self.items[1]['owns'] = ['modules/shared.nix']
        self.save()
        self.assertIn('ambiguous source ownership', self.errors())

    def test_missing_metadata_and_dangling_relationship_fail(self):
        self.write('scripts/helper.py', '# helper\n')
        item = self.component(relationships=['vanished'])
        del item['verification']
        self.save()
        errors = self.errors()
        self.assertIn('helper: missing verification', errors)
        self.assertIn('dangling relationship vanished', errors)

    def test_retired_tombstone_is_searchable_without_live_source(self):
        self.component(classification='retired', source='scripts/removed.py', owns=[])
        self.save()
        self.assertTrue(catalog.validate(self.ctx)['ok'])
        self.assertEqual(catalog.search(self.ctx, 'purpose words')['items'][0]['id'], 'helper')

    def test_source_cannot_escape_through_symlink(self):
        outside = Path(self.tmp.name) / 'outside.py'
        outside.write_text('# private\n')
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/helper.py').symlink_to(outside)
        self.component()
        self.save()
        self.assertIn('missing/unsafe source scripts/helper.py', self.errors())

    def test_patch_and_pin_files_need_lifecycle_records(self):
        self.write('patches/helper.patch', 'diff --git a/a b/a\n')
        self.write('pins/helper.json', '{}')
        self.component(source='patches/helper.patch', owns=['patches/helper.patch', 'pins/helper.json'])
        self.save()
        errors = self.errors()
        self.assertIn('unregistered patch: helper.patch', errors)
        self.assertIn('unregistered pin: helper.json', errors)

    def test_runtime_manual_does_not_search_processes(self):
        item = self.component()
        with patch.object(catalog, '_platforms', return_value={'nixos'}), patch.object(catalog, 'run') as run:
            self.assertEqual(catalog.runtime(item)['state'], 'on-demand')
            run.assert_not_called()

    def test_windows_helper_is_not_probed_from_linux(self):
        item = self.component(platforms=['windows'], runtime={'mode': 'scheduled-task', 'task': 'Dotfiles Slack Presence Pulse'})
        with patch.object(catalog, '_platforms', return_value={'nixos', 'linux'}), patch.object(catalog, 'run') as run:
            self.assertEqual(catalog.runtime(item)['state'], 'not-applicable')
            run.assert_not_called()

    def test_windows_probe_reads_task_api_and_never_executes_helper(self):
        item = self.component(platforms=['windows'], runtime={'mode': 'scheduled-task', 'task': 'Dotfiles Slack Presence Pulse'})
        result = subprocess.CompletedProcess([], 0, '{"TaskName":"Dotfiles Slack Presence Pulse","State":"Running"}', '')
        with patch.object(catalog, '_platforms', return_value={'windows'}), patch.object(catalog.platform, 'system', return_value='Windows'), patch.object(catalog, 'run', return_value=result) as run:
            self.assertEqual(catalog.runtime(item)['state'], 'Running')
            argv = run.call_args.args[0]
            self.assertIn('Get-ScheduledTask', argv[-1])
            self.assertNotIn('keep-slack-active.ps1', ' '.join(argv))
            self.assertNotIn('-Mode Ensure', ' '.join(argv))

    def test_missing_unit_is_unknown_not_an_inactive_failure(self):
        result = subprocess.CompletedProcess([], 0, 'LoadState=not-found\nActiveState=inactive\n', '')
        with patch.object(catalog, 'run', return_value=result):
            self.assertEqual(catalog._service({'unit': 'missing.service', 'scope': 'user'})['state'], 'unknown')

    def test_timed_out_probe_is_unknown(self):
        with patch.object(catalog, 'run', side_effect=subprocess.TimeoutExpired('systemctl', 5)):
            self.assertEqual(catalog._service({'unit': 'slow.service'})['state'], 'unknown')

    def test_native_manifest_inventory_is_read_only_and_deduplicates_brew(self):
        self.write('platforms/macos-managed/Brewfile', 'brew "python@3.13"\ncask "neovide"\n')
        self.write('platforms/macos/Brewfile', 'cask "neovide"\n')
        with patch.object(catalog, 'run') as run:
            tools = catalog.native_manifests(self.ctx)
            run.assert_not_called()
        self.assertEqual(len(tools), 2)
        neovide = next(tool for tool in tools if tool['name'] == 'neovide')
        self.assertEqual(len(neovide['sources']), 2)
        self.assertIsNone(neovide['version'])
        self.assertFalse(self.ctx.state.exists())
        inspected = catalog.inspect(self.ctx, 'brew:cask:neovide')
        self.assertEqual(inspected['kind'], 'managed-tool')
        self.assertEqual(inspected['runtime']['state'], 'unknown')

    def test_personal_mac_codex_is_not_a_managed_mac_declaration(self):
        self.write('platforms/macos-managed/Brewfile', 'cask "claude-code"\n')
        self.write('platforms/macos/Brewfile', 'cask "wezterm@nightly"\n')
        self.write('platforms/macos-personal/Brewfile', 'cask "codex-app"\n')
        tools = {item['name']: item for item in catalog.native_manifests(self.ctx)}
        self.assertEqual(tools['codex-app']['platforms'], ['darwin'])
        self.assertEqual(tools['codex-app']['classification'], 'legacy')
        self.assertEqual(tools['claude-code']['platforms'], ['macos-managed'])
        self.assertIn('macos-managed', tools['wezterm@nightly']['platforms'])

    def test_patch_inspection_and_component_relationships(self):
        self.write('scripts/helper.py', '# helper\n')
        self.write('scripts/other.py', '# other\n')
        self.component(relationships=['other'])
        self.component('other', source='scripts/other.py')
        self.save(patches=[{'id': 'patch-helper', 'owner': 'helper', 'source': 'scripts/helper.py'}])
        self.assertEqual(catalog.inspect(self.ctx, 'patch-helper')['kind'], 'patch')
        with patch.object(catalog, '_platforms', return_value={'nixos'}):
            result = catalog.inspect(self.ctx, 'helper')
        self.assertEqual(result['related'][0]['id'], 'other')
        self.assertEqual(result['patches'][0]['id'], 'patch-helper')
        self.assertFalse(self.ctx.state.exists())

    def test_retired_artifact_inspection_delegates_to_storage(self):
        self.save()
        with patch('storage.inspect', return_value={'kind': 'artifact', 'artifact': {'id': 'retired-artifact', 'status': 'removed'}}) as inspect:
            result = catalog.inspect(self.ctx, 'retired-artifact')
            inspect.assert_called_once_with(self.ctx, 'retired-artifact')
        self.assertEqual(result['artifact']['status'], 'removed')

    def test_legacy_filter_includes_unreviewed_windows_helper(self):
        self.component(platforms=['windows'], classification='unreviewed')
        self.save()
        self.assertEqual(len(catalog.search(self.ctx, scope='legacy')['items']), 1)

    def test_background_filter_preserves_unobserved_services_but_not_shells_or_manual_tools(self):
        self.component('unobserved-service', startup=['Device-triggered service'], runtime={'mode': 'unknown'})
        self.component('shell', startup=['Interactive shell startup'], runtime={'mode': 'configuration'})
        self.component('manual-tool', runtime={'mode': 'manual'})
        self.component('service-group', runtime={'mode': 'services', 'units': []})
        self.save()
        self.assertEqual({item['id'] for item in catalog.search(self.ctx, scope='background')['items']},
                         {'unobserved-service', 'service-group'})

    def test_repository_catalog_is_complete_and_slack_remains_unverified(self):
        ctx = Context(ROOT, Path(self.tmp.name) / 'unused')
        result = catalog.validate(ctx)
        self.assertTrue(result['ok'], '\n'.join(result['errors']))
        slack = next(item for item in catalog.records(ctx) if item['id'] == 'slack-presence')
        self.assertIsNone(slack['verification']['last_verified'])
        self.assertEqual(slack['runtime']['task'], 'Dotfiles Slack Presence Pulse')
        self.assertIn('Ensure', ' '.join(slack['effects']))
        self.assertTrue(any('Remove' in command for command in slack['commands']))
        self.assertGreater(result['components'], 50)
        self.assertGreater(result['patches'], 50)


if __name__ == '__main__':
    unittest.main()
