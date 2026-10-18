#!/usr/bin/env python3
"""Patch the Linux bundled plugin copy, failing closed when vendor code changes."""

import pathlib
import re
import sys


# Match the inspected 26.930 / 26.1013 control flow and copy options. Minifier
# identifiers may change; an algorithm change still requires an explicit review.
BUNDLED_ROLE = re.compile(
    r"async function [\w$]+\([\w$]+,[\w$]+\)\{if\([\w$]+\.default\.platform===`darwin`\)\{"
    r"await [\w$]+\(`/usr/bin/ditto`,\[`--noqtn`,"
)
EXECUTOR_ROLE = re.compile(r"async function [\w$]+\(\{executorPluginRoot:")
BUNDLED = re.compile(
    r"""async[ ]function[ ](?P<copy>[\w$]+)\((?P<src>[\w$]+),(?P<dst>[\w$]+)\)\{
    if\((?P<platform>[\w$]+)\.default\.platform===`darwin`\)\{
    await[ ](?P<ditto>[\w$]+)\(`/usr/bin/ditto`,\[`--noqtn`,(?P=src),(?P=dst)\]\);return\}
    if\((?P=platform)\.default\.platform!==`win32`\)\{
    (?P<operation>await[ ](?P<filesystem>[\w$]+)\.default\.cp\(
    (?P=src),(?P=dst),\{recursive:!0,verbatimSymlinks:!0\}\);)return\}
    """,
    re.VERBOSE,
)
EXECUTOR = re.compile(
    r"""async[ ]function[ ](?P<executor>[\w$]+)\(\{
    executorPluginRoot:(?P<dst>[\w$]+),resourcesPath:(?P<resources>[\w$]+)\}\)\{
    let[ ](?P<descriptor>[\w$]+)=await[ ](?P<resolve>[\w$]+)\(\{
    useWsl:!1,resourcesPath:(?P=resources)\}\);return[ ](?P=descriptor)==null\?null:\(
    (?P<operation>await[ ](?P<filesystem>[\w$]+)\.default\.cp\(
    (?P=descriptor)\.cwd,(?P=dst),\{recursive:!0\}\)),
    process\.platform!==`win32`&&\((?P=descriptor)\.command=(?P<path>[\w$]+)\.default\.join\(
    (?P=dst),(?P=path)\.default\.relative\((?P=descriptor)\.cwd,(?P=descriptor)\.command\)\)\),
    (?P=descriptor)\.cwd=(?P=dst),(?P=descriptor)\.enabled=!0,
    (?P=descriptor)\.env=\{\.\.\.(?P=descriptor)\.env,CODEX_APP_TOOLS_CALLER_HOST_ID:[\w$]+\.[\w$]+\},
    await[ ](?P=filesystem)\.default\.writeFile\((?P=path)\.default\.join\((?P=dst),`\.mcp\.json`\),
    `\$\{JSON\.stringify\(\{mcpServers:\{codex_app:(?P=descriptor)\}\},null,2\)\}\\n`,`utf8`\),(?P=dst)\)\}
    """,
    re.VERBOSE,
)


def patch(source):
    bundled_matches = list(BUNDLED.finditer(source))
    if len(bundled_matches) != 1 or len(BUNDLED_ROLE.findall(source)) != 1:
        raise ValueError("Expected exactly one Linux bundled-plugin copy; review vendor update")
    executor_matches = list(EXECUTOR.finditer(source))
    if len(executor_matches) != 1 or len(EXECUTOR_ROLE.findall(source)) != 1:
        raise ValueError("Expected exactly one executor-plugin copy; review vendor update")
    bundled, executor = bundled_matches[0], executor_matches[0]
    filesystem = executor['filesystem']
    if filesystem != bundled['filesystem']:
        raise ValueError("Bundled and executor copies use different filesystems; review vendor update")
    destination, descriptor = executor['dst'], executor['descriptor']
    bundled_replacement = (
        bundled['operation']
        + f'await require("./bundled-copy.cjs").makeDirectoryWritable({bundled["dst"]});'
    )
    executor_replacement = (
        f'await {filesystem}.default.mkdir({destination},{{recursive:!0}}),'
        f'await require("./bundled-copy.cjs").makeDirectoryWritable({destination}),'
        f'await {filesystem}.default.cp({descriptor}.cwd,{destination},{{recursive:!0,verbatimSymlinks:!0}}),'
        f'await require("./bundled-copy.cjs").makeDirectoryWritable({destination})'
    )
    # Replace only the two reviewed operations, preserving every other byte.
    changes = [(bundled.span('operation'), bundled_replacement), (executor.span('operation'), executor_replacement)]
    for (start, end), replacement in sorted(changes, reverse=True):
        source = source[:start] + replacement + source[end:]
    return source


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise ValueError("Expected exactly one main bundle; review vendor update")
    target = pathlib.Path(sys.argv[1])
    target.write_text(patch(target.read_text()))
