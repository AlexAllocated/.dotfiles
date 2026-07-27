#!/usr/bin/env python3
"""Create a minimal, internally consistent Codex home for the Tracer handoff."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import sqlite3
import time


THREAD_ID = re.compile(
	r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
	r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def copy_stable_jsonl(source: pathlib.Path, target: pathlib.Path) -> None:
	for _attempt in range(50):
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
				target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
				target.write_bytes(data)
				return
		time.sleep(0.1)
	raise SystemExit(f"could not take a stable complete-line snapshot of {source}")


def main() -> int:
	parser = argparse.ArgumentParser()
	parser.add_argument("--thread-id", required=True)
	parser.add_argument("--source", type=pathlib.Path, required=True)
	parser.add_argument("--destination", type=pathlib.Path, required=True)
	parser.add_argument("--target-home", default="/home/alx")
	args = parser.parse_args()

	if not THREAD_ID.fullmatch(args.thread_id):
		raise SystemExit("thread ID is not a UUID")

	source = args.source.resolve(strict=True)
	destination = args.destination.resolve()
	if destination.exists() and any(destination.iterdir()):
		raise SystemExit(f"destination is not empty: {destination}")
	destination.mkdir(parents=True, mode=0o700, exist_ok=True)

	matches: list[tuple[pathlib.Path, pathlib.Path]] = []
	for database in sorted((source / "sqlite").glob("state_*.sqlite")):
		with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
			try:
				rows = connection.execute(
					"SELECT rollout_path FROM threads WHERE id = ?", (args.thread_id,)
				).fetchall()
			except sqlite3.OperationalError:
				continue
		for (rollout_value,) in rows:
			rollout = pathlib.Path(rollout_value).resolve(strict=True)
			try:
				rollout.relative_to(source)
			except ValueError as error:
				raise SystemExit(f"rollout is outside the source Codex home: {rollout}") from error
			matches.append((database, rollout))

	if len(matches) != 1:
		raise SystemExit(f"expected one thread row, found {len(matches)}")

	database, rollout = matches[0]
	relative_rollout = rollout.relative_to(source)
	if relative_rollout.parts[0] not in {"sessions", "archived_sessions"}:
		raise SystemExit(f"unexpected rollout location: {relative_rollout}")

	output_database = destination / "sqlite" / database.name
	output_database.parent.mkdir(parents=True, mode=0o700)
	with sqlite3.connect(database) as source_connection:
		with sqlite3.connect(output_database) as target_connection:
			source_connection.backup(target_connection)
			target_connection.execute("DELETE FROM threads WHERE id != ?", (args.thread_id,))
			tables = {
				row[0]
				for row in target_connection.execute(
					"SELECT name FROM sqlite_master WHERE type = 'table'"
				)
			}
			if "thread_dynamic_tools" in tables:
				target_connection.execute(
					"DELETE FROM thread_dynamic_tools WHERE thread_id != ?", (args.thread_id,)
				)
			if "thread_spawn_edges" in tables:
				target_connection.execute("DELETE FROM thread_spawn_edges")
			for table in ("remote_control_enrollments", "external_agent_config_imports"):
				if table in tables:
					target_connection.execute(f"DELETE FROM {table}")
			target_rollout = pathlib.Path(args.target_home) / ".codex" / relative_rollout
			target_connection.execute(
				"UPDATE threads SET rollout_path = ?, cwd = ? WHERE id = ?",
				(str(target_rollout), f"{args.target_home}/.dotfiles", args.thread_id),
			)
			target_connection.commit()
			if target_connection.execute("PRAGMA integrity_check").fetchone() != ("ok",):
				raise SystemExit("Codex SQLite backup failed its integrity check")

	auth = source / "auth.json"
	if not auth.is_file() or auth.is_symlink():
		raise SystemExit(f"Codex authentication file is missing or unsafe: {auth}")
	shutil.copy2(auth, destination / "auth.json")
	(destination / "config.toml").write_text(
		"# Tracer rescue configuration. Host-specific Codex settings are intentionally omitted.\n",
		encoding="utf-8",
	)
	copy_stable_jsonl(rollout, destination / relative_rollout)
	(destination / "tracer-thread-id").write_text(args.thread_id.lower() + "\n", encoding="utf-8")

	for path in destination.rglob("*"):
		path.chmod(0o700 if path.is_dir() else 0o600)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
