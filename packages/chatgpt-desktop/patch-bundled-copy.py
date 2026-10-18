#!/usr/bin/env python3
"""Patch the Linux bundled plugin copy, failing closed when vendor code changes."""

import pathlib
import sys


ORIGINAL = (
    "async function Tne(e,t){if(P.default.platform===`darwin`){"
    "await nne(`/usr/bin/ditto`,[`--noqtn`,e,t]);return}"
    "if(P.default.platform!==`win32`){"
    "await b.default.cp(e,t,{recursive:!0,verbatimSymlinks:!0});return}"
)
REPLACEMENT = ORIGINAL.replace(
    "verbatimSymlinks:!0});return}",
    'verbatimSymlinks:!0});await require("./bundled-copy.cjs").makeDirectoryWritable(t);return}',
)
EXECUTOR_ORIGINAL = "await b.default.cp(n.cwd,e,{recursive:!0})"
EXECUTOR_REPLACEMENT = (
    'await b.default.mkdir(e,{recursive:!0}),'
    'await require("./bundled-copy.cjs").makeDirectoryWritable(e),'
    'await b.default.cp(n.cwd,e,{recursive:!0,verbatimSymlinks:!0}),'
    'await require("./bundled-copy.cjs").makeDirectoryWritable(e)'
)


def patch(source):
    if source.count(ORIGINAL) != 1:
        raise ValueError("Expected exactly one Linux bundled-plugin copy; review vendor update")
    if source.count(EXECUTOR_ORIGINAL) != 1:
        raise ValueError("Expected exactly one executor-plugin copy; review vendor update")
    return source.replace(ORIGINAL, REPLACEMENT, 1).replace(EXECUTOR_ORIGINAL, EXECUTOR_REPLACEMENT, 1)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise ValueError("Expected exactly one main bundle; review vendor update")
    target = pathlib.Path(sys.argv[1])
    target.write_text(patch(target.read_text()))
