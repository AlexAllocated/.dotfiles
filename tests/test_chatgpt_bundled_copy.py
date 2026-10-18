"""Guard the exact vendor operations while allowing harmless minifier churn."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PATCHER = Path(__file__).resolve().parents[1] / 'packages/chatgpt-desktop/patch-bundled-copy.py'
SPEC = importlib.util.spec_from_file_location('bundled_copy_patch', PATCHER)
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)

# Inspected 26.1013.40934 functions. Keep one fixture; 26.930.41038 differs
# only in the identifiers used by the two patched operations.
BUNDLED = (
    'async function Hne(e,t){if(L.default.platform===`darwin`){'
    'await yne(`/usr/bin/ditto`,[`--noqtn`,e,t]);return}'
    'if(L.default.platform!==`win32`){'
    'await k.default.cp(e,t,{recursive:!0,verbatimSymlinks:!0});return}'
    'let{copyDirectoryAllowDecryptedDestinationOnEncryptionFailure:n}='
    'await Promise.resolve().then(()=>require("./windows-file-copy-B2PsciEv.js"));'
    'await n({copy:()=>k.default.cp(e,t,{recursive:!0,verbatimSymlinks:!0}),destination:t,source:e})}'
)
EXECUTOR = (
    'async function xc({executorPluginRoot:e,resourcesPath:t}){'
    'let n=await Cc({useWsl:!1,resourcesPath:t});return n==null?null:('
    'await k.default.cp(n.cwd,e,{recursive:!0}),'
    'process.platform!==`win32`&&(n.command=S.default.join(e,S.default.relative(n.cwd,n.command))),'
    'n.cwd=e,n.enabled=!0,n.env={...n.env,CODEX_APP_TOOLS_CALLER_HOST_ID:i.Ai},'
    'await k.default.writeFile(S.default.join(e,`.mcp.json`),'
    '`${JSON.stringify({mcpServers:{codex_app:n}},null,2)}\\n`,`utf8`),e)}'
)


def rename(source, names):
    return re.sub(r'(?<!\\)[A-Za-z_$][\w$]*', lambda match: names.get(match[0], match[0]), source)


class BundledCopyPatchTests(unittest.TestCase):
    def test_both_inspected_layouts_only_change_the_two_copy_operations(self):
        current = BUNDLED + EXECUTOR
        expected = current.replace(
            'verbatimSymlinks:!0});return}',
            'verbatimSymlinks:!0});await require("./bundled-copy.cjs").makeDirectoryWritable(t);return}',
        ).replace(
            'await k.default.cp(n.cwd,e,{recursive:!0})',
            'await k.default.mkdir(e,{recursive:!0}),'
            'await require("./bundled-copy.cjs").makeDirectoryWritable(e),'
            'await k.default.cp(n.cwd,e,{recursive:!0,verbatimSymlinks:!0}),'
            'await require("./bundled-copy.cjs").makeDirectoryWritable(e)',
        )
        old_names = {'Hne': 'Tne', 'L': 'P', 'yne': 'nne', 'k': 'b', 'xc': 'Yc', 'Cc': 'Zc', 'i': 'r', 'Ai': 'An'}
        for version, names in [('26.1013.40934', {}), ('26.930.41038', old_names)]:
            with self.subTest(version=version):
                self.assertEqual(PATCH.patch(rename(current, names)), rename(expected, names))

    def test_future_identifier_churn_and_function_order(self):
        names = {name: f'new${index}' for index, name in enumerate(
            ('Hne', 'L', 'yne', 'k', 'xc', 'Cc', 'S', 'i', 'Ai', 'e', 't', 'n'))}
        source = EXECUTOR + BUNDLED
        self.assertEqual(PATCH.patch(rename(source, names)), rename(PATCH.patch(source), names))

    def test_ambiguous_copy_roles_fail_closed(self):
        for extra in (BUNDLED, EXECUTOR, BUNDLED + EXECUTOR,
                      BUNDLED.replace('verbatimSymlinks:!0', 'verbatimSymlinks:!1'),
                      EXECUTOR.replace('recursive:!0', 'recursive:!1')):
            with self.subTest(extra=extra[:25]), self.assertRaises(ValueError):
                PATCH.patch(BUNDLED + EXECUTOR + extra)

    def test_changed_copy_or_executor_semantics_fail_closed(self):
        changes = (
            ('recursive:!0', 'recursive:!1'),
            ('verbatimSymlinks:!0', 'verbatimSymlinks:!1'),
            ('`--noqtn`', '`--other-option`'),
            ('useWsl:!1', 'useWsl:!0'),
            ('n==null?null:', 'n==null?false:'),
            ('n.enabled=!0', 'n.enabled=!1'),
            ('`.mcp.json`', '`other.json`'),
            ('n.cwd=e', 'n.cwd=t'),
        )
        for before, after in changes:
            with self.subTest(change=before), self.assertRaises(ValueError):
                PATCH.patch((BUNDLED + EXECUTOR).replace(before, after))

    def test_mismatched_filesystem_aliases_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'different filesystems'):
            PATCH.patch(BUNDLED + rename(EXECUTOR, {'k': 'otherFilesystem'}))

    def test_unrelated_copy_is_untouched(self):
        other = 'async function unrelated(){await k.default.cp(n.cwd,e,{recursive:!0})}'
        self.assertEqual(PATCH.patch(BUNDLED + EXECUTOR + other), PATCH.patch(BUNDLED + EXECUTOR) + other)

    def test_second_application_fails_closed(self):
        with self.assertRaises(ValueError):
            PATCH.patch(PATCH.patch(BUNDLED + EXECUTOR))

    def test_cli_rejection_preserves_the_original_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'main.js'
            original = BUNDLED + EXECUTOR.replace('recursive:!0', 'recursive:!1')
            target.write_text(original)
            result = subprocess.run([sys.executable, '-B', str(PATCHER), str(target)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), original)


if __name__ == '__main__':
    unittest.main()
