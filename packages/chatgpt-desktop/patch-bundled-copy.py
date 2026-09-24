#!/usr/bin/env python3
"""Patch the Linux bundled plugin copy, failing closed when vendor code changes."""

import pathlib
import sys


ORIGINAL = (
    "async function jre(e,t){if(k.default.platform===`darwin`){"
    "await cre(`/usr/bin/ditto`,[`--noqtn`,e,t]);return}"
    "if(k.default.platform!==`win32`){"
    "await b.default.cp(e,t,{recursive:!0,verbatimSymlinks:!0});return}"
)
REPLACEMENT = ORIGINAL.replace(
    "verbatimSymlinks:!0});return}",
    'verbatimSymlinks:!0});await require("./bundled-copy.cjs").makeDirectoryWritable(t);return}',
)


def patch(source):
    if source.count(ORIGINAL) != 1:
        raise ValueError("Expected exactly one Linux bundled-plugin copy; review vendor update")
    return source.replace(ORIGINAL, REPLACEMENT, 1)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise ValueError("Expected exactly one main bundle; review vendor update")
    target = pathlib.Path(sys.argv[1])
    target.write_text(patch(target.read_text()))
