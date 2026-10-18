"""The default status is a readable summary; JSON retains all collected evidence."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/dotfiles'))
import cli


class StatusDisplayTests(unittest.TestCase):
    def render(self, result):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            cli.display(result)
        return stream.getvalue()

    def fixture(self):
        return {
            'kind': 'status', 'schema_version': 1, 'observed_at': '2026-10-18T20:00:00+00:00',
            'stale': False,
            'local': {'release': {'VERSION_ID': '26.05', 'DOCUMENTATION_URL': 'https://example.org/os-docs'},
                      'installed_generation': '/nix/store/long-system-generation'},
            'inventory': {'source_changed': True, 'working_tree_dirty': True,
                          'packages': [{'name': 'unrelated-inventory-detail'}] * 300},
            'versions': [
                {'id': 'kernel', 'declared': '6.18.55', 'installed': '6.18.55', 'running': '6.18.55',
                 'latest_upstream': '7.2.11', 'freshness': 'behind', 'deployment': 'matches'},
                {'id': 'nvidia', 'declared': '615.71.09', 'installed': '615.71.09', 'running': '595.71.05',
                 'latest_upstream': '615.78.08', 'freshness': 'behind', 'deployment': 'different'},
            ],
            'health': {'runtime_issues': ['desktop-session'], 'unknown_runtime': ['remote-agent']},
            'freshness': {'unverified_sources': ['input:nixpkgs']},
            'deployment': {'reboot_required': True},
            'schedules': {'enabled': False, 'reason': 'Both supported hosts need acceptance before enabling'},
            'candidates': [{'id': 'editor-123', 'group': 'editor', 'status': 'ready',
                            'head': 'a' * 40, 'pr': 'https://example.org/pull/123'},
                           {'id': 'old-456', 'group': 'system', 'status': 'applied'}],
            'upstream': {
                'input:nixpkgs': {'value': {'revision': 'b' * 40, 'url': 'https://example.org/input'},
                                  'error': 'request timed out\nretry later', 'stale': True},
                'kernel': {'value': {'version': '7.2.11', 'url': 'https://example.org/kernel'}, 'error': None},
            },
        }

    def test_summary_exposes_actionable_evidence_without_provider_or_os_dumps(self):
        result = self.fixture()
        original = copy.deepcopy(result)
        output = self.render(result)
        self.assertLessEqual(len(output.splitlines()), 35)
        for expected in ('Observed:', 'Source: changed since observation', 'Declared', 'Installed',
                         'Running', 'Latest', 'Health: 1 runtime issues, 1 unknown',
                         'Reboot: required', 'Schedules: off', 'acceptance before enabling',
                         'Candidates: 1 pending, 1 completed or retired', 'editor-123 [editor: ready]',
                         'Upstream error (input:nixpkgs): request timed out retry later',
                         'dotctl status --refresh', 'dotctl status --json'):
            self.assertIn(expected, output)
        for omitted in ('DOCUMENTATION_URL', 'https://example.org', '/nix/store',
                        'unrelated-inventory-detail', "'revision':", 'old-456'):
            self.assertNotIn(omitted, output)
        kernel = next(line for line in output.splitlines() if line.startswith('kernel '))
        self.assertIn('informational', kernel)
        self.assertNotIn('behind', kernel)
        self.assertIn('selected Nix channel', output)
        driver = next(line for line in output.splitlines() if line.startswith('nvidia '))
        self.assertIn('behind; running differs', driver)
        self.assertEqual(result, original)

    def test_first_run_does_not_claim_observed_health_or_no_reboot_needed(self):
        output = self.render({'kind': 'status', 'observed_at': None, 'stale': True})
        for expected in ('Observed: never [stale]', 'Source: not observed', 'Versions: not observed',
                         'runtime not observed', 'Reboot: unknown', 'Schedules: off',
                         'acceptance of the same baseline'):
            self.assertIn(expected, output)
        self.assertNotIn('Reboot: not required', output)

    def test_managed_mac_stays_company_managed_and_failed_evidence_is_visible(self):
        result = self.fixture()
        result['versions'] = [
            {'id': 'macos', 'installed': '26.0', 'offered': {'value': {'output': 'large softwareupdate report'}}},
            {'id': 'claude', 'declared': '2.1.0', 'installed': '2.0.0', 'latest_upstream': '2.1.0',
             'freshness': 'behind', 'upstream_error': 'offline', 'upstream_stale': True},
        ]
        result['editor'] = {'error': 'Mason receipts could not be read'}
        output = self.render(result)
        self.assertIn('company managed', output)
        self.assertIn('claude', output)
        self.assertIn('refresh failed', output)
        self.assertIn('Editor error: Mason receipts could not be read', output)
        self.assertNotIn('large softwareupdate report', output)
        self.assertNotIn('codex', output)

    def test_large_candidate_and_error_history_remains_bounded_with_explicit_overflow(self):
        result = self.fixture()
        result['candidates'] = [{'id': f'candidate-{i}', 'group': 'editor', 'status': 'failed',
                                 'error': 'multiline failure\n' * 50} for i in range(100)]
        result['upstream'] = {f'input:{i}': {'error': 'request timed out\n' * 50} for i in range(100)}
        output = self.render(result)
        self.assertLessEqual(len(output.splitlines()), 35)
        self.assertIn('Candidates: 100 pending', output)
        self.assertIn('+96 more pending; see --json', output)
        self.assertIn('+97 more upstream errors; see --json', output)
        self.assertLess(max(map(len, output.splitlines())), 160)

    def test_json_command_retains_full_original_evidence(self):
        result = self.fixture()
        stream = io.StringIO()
        with patch.object(cli, 'Context'), patch.object(cli, 'execute', return_value=result), \
             contextlib.redirect_stdout(stream):
            self.assertEqual(cli.main(['status', '--json']), 0)
        self.assertEqual(json.loads(stream.getvalue()), result)

    def test_codex_share_help_does_not_call_mutating_legacy_tool_read_only(self):
        help_text = cli.parser().format_help()
        self.assertIn('legacy shared-storage tooling', help_text)
        self.assertNotIn('read-only', help_text)


if __name__ == '__main__':
    unittest.main()
