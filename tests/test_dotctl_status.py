"""Status evidence must not claim freshness or activation that has not been observed."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
from core import Context, now
import status
import catalog


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        (self.root / 'catalog').mkdir()
        (self.root / 'catalog/policy.json').write_text('{}')
        self.ctx = Context(self.root, Path(self.temporary.name) / 'state')

    def tearDown(self):
        self.temporary.cleanup()

    def test_first_cached_status_never_creates_state_or_runs_commands(self):
        with patch.object(status, 'run', side_effect=AssertionError('subprocess from cached status')), \
             patch.object(status, 'fetch', side_effect=AssertionError('network from cached status')):
            result = status.cached(self.ctx)
        self.assertTrue(result['stale'])
        self.assertIsNone(result['deployment']['reboot_required'])
        self.assertFalse(self.ctx.state.exists())
        self.assertEqual(result['schema_version'], 1)

    def test_cached_read_does_not_rewrite_observations(self):
        self.ctx.save('status.json', {'kind': 'status', 'schema_version': 1, 'observed_at': now(),
                                     'upstream': {'driver': {'observed_at': now(), 'value': '123'}}})
        before = (self.ctx.state / 'status.json').read_bytes()
        with patch.object(self.ctx, 'save', side_effect=AssertionError('write from cached status')):
            status.cached(self.ctx)
        self.assertEqual(before, (self.ctx.state / 'status.json').read_bytes())

    def test_cached_missing_local_background_observation_is_unknown_without_probing(self):
        (self.root / 'catalog/components.json').write_text(json.dumps([
            {'id': 'radio', 'platforms': ['nixos'], 'startup': ['radio.service'], 'runtime': {'mode': 'unknown'}},
            {'id': 'remote-task', 'platforms': ['windows'], 'runtime': {'mode': 'scheduled-task'}},
            {'id': 'helper', 'platforms': ['nixos'], 'runtime': {'mode': 'manual'}},
        ]))
        with patch.object(catalog, '_platforms', return_value={'nixos', 'linux'}), \
             patch.object(status, 'run', side_effect=AssertionError('cached status ran a probe')), \
             patch.object(status, 'runtime', side_effect=AssertionError('cached status ran a probe')):
            result = status.cached(self.ctx)
        self.assertEqual(result['health']['unknown_runtime'], ['radio'])
        self.assertEqual(result['health']['runtime_issues'], [])
        self.assertFalse(self.ctx.state.exists())

    def test_grouped_runtime_counts_failed_and_unknown_units_but_not_inactive_timers(self):
        self.ctx.save('status.json', {'observed_at': now(), 'runtime': [
            {'id': 'desktop', 'state': 'observed', 'units': {
                'shell.service': {'state': 'failed'}, 'portal.service': {'state': 'unknown'}}},
            {'id': 'maintenance-schedules', 'state': 'observed', 'units': {
                'daily.timer': {'state': 'inactive'}, 'weekly.timer': {'state': 'inactive'}}},
        ]})
        result = status.cached(self.ctx)
        self.assertEqual(result['health']['runtime_issues'], ['desktop'])
        self.assertEqual(result['health']['unknown_runtime'], ['desktop'])

    def test_refresh_probes_groups_and_retains_explicit_unknown_background_state(self):
        (self.root / 'catalog/components.json').write_text(json.dumps([
            {'id': 'radio', 'platforms': ['nixos'], 'startup': ['radio.service'],
             'runtime': {'mode': 'unknown', 'reason': 'Radio availability needs verification'}},
            {'id': 'maintenance-schedules', 'platforms': ['nixos'],
             'runtime': {'mode': 'services', 'units': [
                 {'unit': 'daily.timer', 'scope': 'user'}, {'unit': 'weekly.timer', 'scope': 'user'}]}},
            {'id': 'manual-helper', 'runtime': {'mode': 'manual'}},
        ]))
        with patch.object(catalog, '_platforms', return_value={'nixos', 'linux'}), \
             patch.object(catalog.Path, 'exists', return_value=True), \
             patch.object(catalog, '_service', return_value={'state': 'inactive'}) as service, \
             patch.object(status, 'providers', return_value={}), \
             patch.object(status, 'os_local', return_value={}), \
             patch.object(status, 'editor_local', return_value={}), \
             patch.object(status.shutil, 'which', return_value=None), \
             patch.object(status.platform, 'system', return_value='Linux'):
            result = status.refresh(self.ctx)
        self.assertEqual({item['id'] for item in result['runtime']}, {'radio', 'maintenance-schedules'})
        self.assertEqual(service.call_count, 2)
        self.assertEqual(result['health']['unknown_runtime'], ['radio'])
        self.assertEqual(result['health']['runtime_issues'], [])
        self.assertIn('Radio availability', next(item for item in result['runtime'] if item['id'] == 'radio')['evidence'])

    def test_failed_refresh_retains_value_and_old_observation(self):
        old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=4)).isoformat()
        def fail():
            raise TimeoutError('registry timed out')
        observation = status.observe({'value': {'version': '1.2'}, 'observed_at': old}, fail)
        self.assertEqual(observation['value']['version'], '1.2')
        self.assertEqual(observation['observed_at'], old)
        self.assertIn('timed out', observation['error'])
        self.assertTrue(status.stale(observation['observed_at']))
        self.ctx.save('status.json', {'observed_at': now(), 'upstream': {'tool': observation}})
        with patch.object(status.platform, 'system', return_value='Linux'):
            cached = status.cached(self.ctx)
        self.assertFalse(cached['stale'])
        self.assertTrue(cached['upstream']['tool']['stale'])
        self.assertEqual(cached['next_step'], 'dotctl status --refresh')

    def test_invalid_future_or_naive_timestamps_are_not_fresh(self):
        for value in (None, 'invalid', '2026-01-01T00:00:00',
                      (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=4)).isoformat()):
            self.assertTrue(status.stale(value))

    def boot_fixture(self):
        current, booted, store = (Path(self.temporary.name) / p for p in ('current', 'booted', 'store'))
        for path in (current, booted, store):
            path.mkdir()
        for name in ('kernel', 'kernel-modules', 'initrd'):
            (store / name).touch()
            (current / name).symlink_to(store / name)
            (booted / name).symlink_to(store / name)
        return current, booted, store

    def test_generation_change_alone_does_not_require_reboot(self):
        current, booted, _ = self.boot_fixture()
        self.assertNotEqual(current, booted)
        self.assertFalse(status.boot_state(current, booted)['reboot_required'])

    def test_missing_boot_evidence_is_unknown(self):
        current, booted, _ = self.boot_fixture()
        (booted / 'initrd').unlink()
        self.assertIsNone(status.boot_state(current, booted)['reboot_required'])

    def test_changed_kernel_requires_reboot(self):
        current, booted, store = self.boot_fixture()
        (store / 'new-kernel').touch()
        (current / 'kernel').unlink()
        (current / 'kernel').symlink_to(store / 'new-kernel')
        result = status.boot_state(current, booted)
        self.assertTrue(result['reboot_required'])
        self.assertEqual(result['boot_changes'], ['kernel'])

    def test_nvidia_channels_never_borrow_each_others_version(self):
        def result(version, production, feature, beta='0'):
            return json.dumps({'Success': '1', 'IDS': [{'downloadInfo': {
                'DisplayVersion': version, 'IsRecommended': production, 'IsFeaturePreview': feature,
                'IsBeta': beta, 'OsCode': 'linux64', 'DetailsURL': 'https://www.nvidia.com/example'}}]})
        with patch.object(status, 'fetch', side_effect=[result('600.10', '1', '0'), result('615.12.3', '0', '1')]):
            self.assertEqual(status.nvidia()['channels'], {'production': '600.10', 'new-feature': '615.12.3'})
        with patch.object(status, 'fetch', return_value=result('615.12.3', '0', '1')):
            with self.assertRaises(ValueError):
                status.nvidia()
        with patch.object(status, 'fetch', return_value=result('600.10', '1', '0', beta='1')):
            with self.assertRaises(ValueError):
                status.nvidia()

    def test_only_direct_nix_inputs_are_probed(self):
        (self.root / 'flake.lock').write_text(json.dumps({'root': 'root', 'nodes': {
            'root': {'inputs': {'nixpkgs': 'nixpkgs'}},
            'nixpkgs': {'original': {'type': 'github', 'owner': 'NixOS', 'repo': 'nixpkgs', 'ref': 'nixos-26.05'}},
            'transitive': {'original': {'type': 'github', 'owner': 'Other', 'repo': 'Other'}}}}))
        with patch.object(status.platform, 'system', return_value='Linux'):
            providers = status.providers(self.ctx)
        self.assertEqual(set(providers), {'os-release', 'nvidia', 'kernel', 'codex', 'input:nixpkgs'})

    def test_version_summary_separates_policy_upstream_and_running_driver(self):
        result = status.version_summary({'local': {'nvidia_installed': '615.71.09', 'nvidia_loaded': '595.71.05'},
            'inventory': {'nvidia_declared': '615.71.09'}, 'driver_policy': {'channel': 'new-feature', 'reason': 'game fix'},
            'upstream': {'nvidia': {'value': {'channels': {'production': '595.104.02', 'new-feature': '615.78.08'}}}}})
        driver = next(item for item in result if item['id'] == 'nvidia')
        self.assertEqual(driver['freshness'], 'behind')
        self.assertEqual(driver['deployment'], 'different')
        self.assertEqual(driver['policy']['reason'], 'game fix')
        self.assertEqual(driver['upstream_channels']['production'], '595.104.02')

    def test_codex_official_rust_tag_compares_as_a_version(self):
        self.assertEqual(status.normalize_version('rust-v0.163.0'), '0.163.0')
        result = status.version_summary({'local': {'codex_installed': '0.160.0'},
                                         'upstream': {'codex': {'value': {'version': 'rust-v0.163.0'}}}})
        self.assertEqual(next(item for item in result if item['id'] == 'codex')['freshness'], 'behind')

    def test_managed_mac_only_fetches_its_declared_claude_provider(self):
        with patch.object(status.platform, 'system', return_value='Darwin'), \
             patch.object(status, 'fetch', return_value='{"version":"2.1.0"}') as fetch:
            providers = status.providers(self.ctx)
            self.assertEqual(set(providers), {'claude'})
            self.assertEqual(providers['claude']()['version'], '2.1.0')
            fetch.assert_called_once_with('https://formulae.brew.sh/api/cask/claude-code.json')

    def test_mac_status_reports_claude_homebrew_installed_and_available_versions(self):
        data = {'local': {'platform': 'Darwin', 'macos_installed': '26.0'},
                'brew': {'casks': [{'name': 'claude-code', 'installed': '2.0.0', 'version': '2.1.0'}]},
                'upstream': {'claude': {'value': {'version': '2.1.0'}}}}
        result = status.version_summary(data)
        self.assertEqual([item['id'] for item in result], ['macos', 'claude'])
        self.assertEqual(result[1]['installed'], '2.0.0')
        self.assertEqual(result[1]['freshness'], 'behind')

    def test_editor_receipts_do_not_claim_running_version(self):
        (self.root / 'nvim').mkdir()
        (self.root / 'nvim/mason-lock.json').write_text('{"packages":{"yaml-language-server":"1.25.0"}}')
        data = self.root.parent / 'data'
        package = data / 'nvim/mason/packages/yaml-language-server'
        package.mkdir(parents=True)
        (package / 'mason-receipt.json').write_text('{"source":{"id":"pkg:npm/yaml-language-server@1.24.0"}}')
        with patch.object(status.platform, 'system', return_value='Linux'), \
             patch.dict(status.os.environ, {'XDG_DATA_HOME': str(data)}), \
             patch.object(status, 'run', side_effect=AssertionError('editor was launched')):
            result = status.editor_local(self.ctx)['mason'][0]
        self.assertEqual(result['declared_version'], '1.25.0')
        self.assertEqual(result['installed_version'], '1.24.0')
        self.assertIsNone(result['running_version'])
        self.assertEqual(result['deployment'], 'different')

    def test_mac_editor_status_selects_managed_locks(self):
        (self.root / 'nvim').mkdir()
        (self.root / 'nvim/mason-lock.json').write_text('{"packages":{"personal-tool":"1"}}')
        (self.root / 'nvim/mason-lock.macos-managed.json').write_text('{"packages":{"managed-tool":"2"}}')
        with patch.object(status.platform, 'system', return_value='Darwin'):
            result = status.editor_local(self.ctx)
        self.assertEqual(result['profile'], 'macos-managed')
        self.assertEqual(result['mason'][0]['name'], 'managed-tool')

    def test_nix_duplicate_package_versions_share_one_stable_catalog_id(self):
        variants = [{'id': 'nix:tool', 'name': 'tool', 'description': 'A tool', 'version': version,
                     'installed_version': version if version == '1' else None, 'source_attribute': 'host',
                     'store_path': '/nix/store/' + version} for version in ('1', '2')]
        result = status.group_nix_packages(variants)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['id'], 'nix:tool')
        self.assertEqual(result[0]['declared_versions'], ['1', '2'])
        self.assertEqual(result[0]['installed_versions'], ['1'])
        self.assertEqual(len(result[0]['variants']), 2)

    def test_dirty_source_invalidates_declared_inventory(self):
        (self.root / 'flake.nix').write_text('original')
        self.ctx.save('status.json', {'observed_at': now(), 'inventory': {
            'observed_at': now(), 'source_fingerprint': status.source_fingerprint(self.ctx)}})
        self.assertFalse(status.cached(self.ctx)['inventory']['source_changed'])
        (self.root / 'flake.nix').write_text('uncommitted change')
        self.assertTrue(status.cached(self.ctx)['inventory']['source_changed'])

    def patch_fixture(self):
        (self.root / 'patches').mkdir()
        (self.root / 'patches/fix.patch').write_text('old patch')
        record = {'id': 'patch-fix', 'source': 'patches/fix.patch',
                  'source_paths': ['patches/fix.patch'], 'removal': {'requires_live': True, 'regression': 'Test the app'}}
        (self.root / 'catalog/patches.json').write_text(json.dumps([record]))
        evidence = {'state': 'removal validated', 'source_fingerprint': status.patch_fingerprint(self.ctx, record),
                    'target_fingerprint': status.source_fingerprint(self.ctx),
                    'build_passed': True, 'regression_passed': True, 'live_passed': True}
        self.ctx.save('patch-evidence/patch-fix.json', evidence)
        return evidence

    def test_patch_source_change_invalidates_previous_removal_evidence(self):
        self.patch_fixture()
        self.assertEqual(status.patches(self.ctx)['items'][0]['state'], 'removal validated')
        (self.root / 'patches/fix.patch').write_text('changed patch')
        result = status.patches(self.ctx)['items'][0]
        self.assertEqual(result['state'], 'unknown')
        self.assertFalse(result['evidence_current'])

    def test_patch_target_change_invalidates_previous_removal_evidence(self):
        self.patch_fixture()
        (self.root / 'flake.lock').write_text('{}')
        self.assertEqual(status.patches(self.ctx)['items'][0]['state'], 'unknown')

    def test_build_alone_cannot_validate_hardware_patch_removal(self):
        evidence = self.patch_fixture()
        evidence['live_passed'] = False
        self.ctx.save('patch-evidence/patch-fix.json', evidence)
        self.assertEqual(status.patches(self.ctx)['items'][0]['state'], 'removal testing needed')

    def test_brew_formula_cask_identity_and_auto_update_are_explicit(self):
        for path in ('platforms/macos-managed', 'platforms/macos'):
            (self.root / path).mkdir(parents=True)
        (self.root / 'platforms/macos-managed/Brewfile').write_text('brew "tool"\ncask "tool"\n')
        (self.root / 'platforms/macos/Brewfile').write_text('cask "other"\n')
        calls = []
        def fake_run(argv, **kwargs):
            calls.append((argv, kwargs))
            return type('Result', (), {'stdout': '{"formulae": [], "casks": []}'})()
        with patch.object(status, 'run', side_effect=fake_run), \
             patch.object(status, 'fetch', return_value='{"version":"1"}'), \
             patch.object(status.shutil, 'which', return_value=None):
            result = status.brew_snapshot(self.ctx)
        self.assertEqual(result['declarations'], {'brew': ['tool'], 'cask': ['other', 'tool']})
        self.assertEqual(len(calls), 2)
        self.assertIn('--formula', calls[0][0])
        self.assertIn('--cask', calls[1][0])
        self.assertTrue(all(call[1]['env']['HOMEBREW_NO_AUTO_UPDATE'] == '1' for call in calls))
        self.assertFalse(any('update' in call[0] or 'install' in call[0] for call in calls))


if __name__ == '__main__':
    unittest.main()
