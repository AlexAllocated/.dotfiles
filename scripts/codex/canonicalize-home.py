#!/usr/bin/env python3
"""Rewrite functional Codex thread paths after a Linux home rename."""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import re
import sqlite3
import tempfile


HOME_RE = re.compile(r"^/home/[^/]+$")


def quick_check(connection: sqlite3.Connection) -> None:
    result = [row[0] for row in connection.execute("PRAGMA quick_check")]
    if result != ["ok"]:
        raise RuntimeError(f"SQLite quick_check failed: {result}")


def backup_database(source: sqlite3.Connection, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    final_path = backup_dir / f"state_5-before-home-rewrite-{stamp}.sqlite"
    if final_path.exists():
        raise RuntimeError(f"Backup already exists: {final_path}")

    with tempfile.NamedTemporaryFile(dir=backup_dir, prefix="state_5-backup-", delete=False) as handle:
        temporary_path = Path(handle.name)
    try:
        backup = sqlite3.connect(temporary_path)
        source.backup(backup)
        quick_check(backup)
        backup.close()
        temporary_path.chmod(0o600)
        temporary_path.replace(final_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return final_path


def canonicalize(database: Path, old_home: str, new_home: str, backup_dir: Path) -> tuple[int, int, Path]:
    if not HOME_RE.fullmatch(old_home) or not HOME_RE.fullmatch(new_home) or old_home == new_home:
        raise ValueError("old and new homes must be distinct /home/USER paths")
    if not database.is_file():
        raise FileNotFoundError(database)

    connection = sqlite3.connect(database, timeout=30)
    connection.execute("PRAGMA busy_timeout = 30000")
    quick_check(connection)
    backup_path = backup_database(connection, backup_dir)

    try:
        connection.execute("BEGIN IMMEDIATE")
        cwd_count = connection.execute(
            """
            UPDATE threads
               SET cwd = ? || substr(cwd, length(?) + 1)
             WHERE cwd = ? OR cwd LIKE ?
            """,
            (new_home, old_home, old_home, f"{old_home}/%"),
        ).rowcount
        sandbox_count = connection.execute(
            """
            UPDATE threads
               SET sandbox_policy = replace(sandbox_policy, ?, ?)
             WHERE instr(sandbox_policy, ?) > 0
            """,
            (old_home, new_home, old_home),
        ).rowcount
        connection.commit()
        quick_check(connection)
    except BaseException:
        connection.rollback()
        raise
    finally:
        connection.close()

    return cwd_count, sandbox_count, backup_path


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        database = root / "state_5.sqlite"
        connection = sqlite3.connect(database)
        connection.execute(
            "CREATE TABLE threads (cwd TEXT, sandbox_policy TEXT, title TEXT)"
        )
        connection.executemany(
            "INSERT INTO threads VALUES (?, ?, ?)",
            [
                ("/home/legacy/code/app", '{"writable_roots":["/home/legacy/code/app"]}', "/home/legacy title"),
                ("/home/current/code/app", "{}", "unchanged"),
            ],
        )
        connection.commit()
        connection.close()

        cwd_count, sandbox_count, backup = canonicalize(
            database, "/home/legacy", "/home/current", root / "backups"
        )
        assert cwd_count == 1
        assert sandbox_count == 1
        assert backup.is_file()
        connection = sqlite3.connect(database)
        rows = connection.execute("SELECT cwd, sandbox_policy, title FROM threads ORDER BY title").fetchall()
        connection.close()
        assert rows[0] == (
            "/home/current/code/app",
            '{"writable_roots":["/home/current/code/app"]}',
            "/home/legacy title",
        )
        assert rows[1] == ("/home/current/code/app", "{}", "unchanged")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--old-home")
    parser.add_argument("--new-home")
    parser.add_argument("--backup-dir", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test:
        missing = [name for name in ("database", "old_home", "new_home", "backup_dir") if not getattr(args, name)]
        if missing:
            parser.error("missing required arguments: " + ", ".join(missing))
    return args


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    cwd_count, sandbox_count, backup = canonicalize(
        args.database.expanduser(), args.old_home, args.new_home, args.backup_dir.expanduser()
    )
    print(f"Canonicalized {cwd_count} conversation cwd path(s).")
    print(f"Canonicalized {sandbox_count} saved sandbox policy path(s).")
    print(f"Consistent pre-migration backup: {backup}")


if __name__ == "__main__":
    main()
