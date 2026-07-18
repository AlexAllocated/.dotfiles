#!/usr/bin/env python3
"""Create the normalized Codex portion of a NixOS handoff capsule."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import time


THREAD_ID = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def find_codex_writers() -> list[str]:
    writers: list[str] = []
    own_pid = os.getpid()
    for process in Path("/proc").iterdir():
        if not process.name.isdigit() or int(process.name) == own_pid:
            continue
        try:
            arguments = (process / "cmdline").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        for argument in arguments[:3]:
            name = Path(os.fsdecode(argument)).name.lower()
            if name in {"codex", "codex.exe", "codex.js"}:
                writers.append(f"pid {process.name}: {os.fsdecode(arguments[0])}")
                break
    return writers


def resolve_rollout(codex_home: Path, rollout_path: str) -> tuple[Path, Path]:
    source = Path(rollout_path).resolve(strict=True)
    try:
        relative = source.relative_to(codex_home.resolve(strict=True))
    except ValueError as error:
        raise SystemExit(f"rollout is outside CODEX_HOME: {source}") from error

    parts = relative.parts
    dated = (
        len(parts) == 5
        and parts[0] == "sessions"
        and all(part.isdigit() for part in parts[1:4])
        and parts[4].startswith("rollout-")
        and parts[4].endswith(".jsonl")
    )
    archived = (
        len(parts) == 2
        and parts[0] == "archived_sessions"
        and parts[1].startswith("rollout-")
        and parts[1].endswith(".jsonl")
    )
    if not (dated or archived):
        raise SystemExit(f"rollout path does not match the capsule allowlist: {relative}")
    return source, relative


def copy_stable_jsonl(source: Path, target: Path) -> None:
    for _attempt in range(30):
        before = source.stat().st_size
        data = source.read_bytes()
        after = source.stat().st_size
        if before == after == len(data) and data.endswith(b"\n"):
            try:
                for line in data.splitlines():
                    json.loads(line)
            except json.JSONDecodeError:
                pass
            else:
                target.write_bytes(data)
                return
        time.sleep(0.1)
    raise SystemExit(f"could not take a stable complete-line snapshot of {source}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--codex-home", type=Path, required=True)
    parser.add_argument("--sqlite-home", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--allow-live-thread")
    args = parser.parse_args()

    if not THREAD_ID.fullmatch(args.thread_id):
        raise SystemExit("thread ID is not a UUID")

    if args.allow_live_thread and args.allow_live_thread.lower() != args.thread_id.lower():
        raise SystemExit("--allow-live-thread must name the exported thread ID")

    writers = find_codex_writers()
    if writers and not args.allow_live_thread:
        details = "\n".join(f"  {writer}" for writer in writers)
        raise SystemExit(
            "Codex still has live WSL writers. Close every Codex session first:\n"
            + details
        )

    codex_home = args.codex_home.resolve(strict=True)
    sqlite_home = args.sqlite_home.resolve(strict=True)
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, mode=0o700, exist_ok=True)

    matches: list[tuple[Path, str]] = []
    for database in sorted(sqlite_home.glob("state_*.sqlite")):
        uri = f"file:{database}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            try:
                rows = connection.execute(
                    "SELECT rollout_path FROM threads WHERE id = ?", (args.thread_id,)
                ).fetchall()
            except sqlite3.OperationalError:
                continue
        matches.extend((database, row[0]) for row in rows)

    if len(matches) != 1:
        raise SystemExit(
            f"expected one state database row for {args.thread_id}, found {len(matches)}"
        )

    source_database, rollout_value = matches[0]
    rollout_source, rollout_relative = resolve_rollout(codex_home, rollout_value)
    if args.thread_id not in rollout_source.read_text(encoding="utf-8", errors="replace"):
        raise SystemExit("selected rollout does not contain the requested thread ID")

    output_codex = destination / "codex"
    output_sqlite = output_codex / "sqlite"
    output_sqlite.mkdir(parents=True, mode=0o700)
    database_target = output_sqlite / source_database.name
    with sqlite3.connect(source_database) as source_connection:
        with sqlite3.connect(database_target) as target_connection:
            source_connection.backup(target_connection)
            result = target_connection.execute("PRAGMA integrity_check").fetchone()
            if result != ("ok",):
                raise SystemExit(f"online SQLite backup failed integrity check: {result!r}")

    auth_source = codex_home / "auth.json"
    if not auth_source.is_file() or auth_source.is_symlink():
        raise SystemExit(f"Codex authentication file is missing or unsafe: {auth_source}")
    shutil.copy2(auth_source, output_codex / "auth.json")

    (output_codex / "config.toml").write_text(
        "# Sanitized migration configuration.\n"
        "# Database overrides, notify hooks, MCP commands, and host-specific paths are omitted.\n",
        encoding="utf-8",
    )
    history_source = codex_home / "history.jsonl"
    if history_source.is_file() and not history_source.is_symlink():
        shutil.copy2(history_source, output_codex / "history.jsonl")

    rollout_target = output_codex / rollout_relative
    rollout_target.parent.mkdir(parents=True, mode=0o700)
    copy_stable_jsonl(rollout_source, rollout_target)

    for path in destination.rglob("*"):
        if path.is_dir():
            path.chmod(0o700)
        elif path.is_file():
            path.chmod(0o600)

    print(f"Backed up {source_database.name} and {rollout_relative.as_posix()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
