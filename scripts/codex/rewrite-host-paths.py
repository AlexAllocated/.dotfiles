#!/usr/bin/env python3
"""Rewrite restored Codex conversation paths from a container home to a host home."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser()
	parser.add_argument("--codex-root", required=True, type=Path)
	parser.add_argument("--old-home", default="/home/alex")
	parser.add_argument("--new-home", required=True)
	parser.add_argument("--old-dotfiles", default="/home/alex/.dotfiles")
	parser.add_argument("--new-dotfiles", required=True)
	parser.add_argument("--old-code", default="/home/alex/code")
	parser.add_argument("--new-code", required=True)
	return parser.parse_args()


def build_replacements(args: argparse.Namespace) -> list[tuple[str, str]]:
	replacements = [
		(args.old_dotfiles, args.new_dotfiles),
		(args.old_code, args.new_code),
		(args.old_home, args.new_home),
	]
	seen: set[str] = set()
	unique: list[tuple[str, str]] = []
	for old, new in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
		old = old.rstrip("/")
		new = new.rstrip("/")
		if not old or old == new or old in seen:
			continue
		seen.add(old)
		unique.append((old, new))
	return unique


def rewrite_string(value: str, replacements: list[tuple[str, str]]) -> str:
	for old, new in replacements:
		value = value.replace(old, new)
	return value


def rewrite_json_value(value: Any, replacements: list[tuple[str, str]]) -> Any:
	if isinstance(value, str):
		return rewrite_string(value, replacements)
	if isinstance(value, list):
		return [rewrite_json_value(item, replacements) for item in value]
	if isinstance(value, dict):
		return {key: rewrite_json_value(item, replacements) for key, item in value.items()}
	return value


def contains_old_path(value: str, replacements: list[tuple[str, str]]) -> bool:
	return any(old in value for old, _ in replacements)


def rewrite_jsonl_file(path: Path, replacements: list[tuple[str, str]]) -> tuple[int, int]:
	lines_changed = 0
	bytes_changed = 0

	fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
	try:
		with os.fdopen(fd, "w", encoding="utf-8", newline="") as tmp, path.open(
			"r", encoding="utf-8", errors="surrogateescape", newline=""
		) as source:
			for raw_line in source:
				if not contains_old_path(raw_line, replacements):
					tmp.write(raw_line)
					continue

				line_body = raw_line.rstrip("\r\n")
				line_ending = raw_line[len(line_body) :]
				try:
					original = json.loads(line_body)
					rewritten = rewrite_json_value(original, replacements)
					new_line = json.dumps(rewritten, ensure_ascii=False, separators=(",", ":")) + line_ending
				except Exception:
					new_line = rewrite_string(raw_line, replacements)

				if new_line != raw_line:
					lines_changed += 1
					bytes_changed += len(new_line.encode("utf-8", errors="surrogateescape"))
				tmp.write(new_line)

		if lines_changed:
			shutil.copystat(path, tmp_name)
			os.replace(tmp_name, path)
		else:
			os.unlink(tmp_name)
	except Exception:
		try:
			os.unlink(tmp_name)
		except FileNotFoundError:
			pass
		raise

	return lines_changed, bytes_changed


def quote_identifier(identifier: str) -> str:
	return '"' + identifier.replace('"', '""') + '"'


def rewrite_sqlite_file(path: Path, replacements: list[tuple[str, str]]) -> tuple[int, int]:
	rows_changed = 0
	cells_changed = 0

	connection = sqlite3.connect(str(path))
	try:
		connection.execute("PRAGMA busy_timeout=5000")
		tables = [
			row[0]
			for row in connection.execute(
				"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
			)
		]
		for table in tables:
			columns = [
				row[1]
				for row in connection.execute(f"PRAGMA table_info({quote_identifier(table)})")
				if "TEXT" in (row[2] or "").upper()
			]
			if not columns:
				continue

			table_sql = quote_identifier(table)
			column_sql = ", ".join(quote_identifier(column) for column in columns)
			select_sql = f"SELECT rowid, {column_sql} FROM {table_sql}"
			for row in connection.execute(select_sql):
				rowid = row[0]
				updates: list[tuple[str, str]] = []
				for column, value in zip(columns, row[1:]):
					if not isinstance(value, str) or not contains_old_path(value, replacements):
						continue
					new_value = rewrite_string(value, replacements)
					if new_value != value:
						updates.append((column, new_value))

				if not updates:
					continue

				assignments = ", ".join(f"{quote_identifier(column)} = ?" for column, _ in updates)
				values = [value for _, value in updates]
				connection.execute(f"UPDATE {table_sql} SET {assignments} WHERE rowid = ?", [*values, rowid])
				rows_changed += 1
				cells_changed += len(updates)

		if rows_changed:
			connection.commit()
			connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
		else:
			connection.rollback()
	finally:
		connection.close()

	return rows_changed, cells_changed


def conversation_jsonl_files(codex_root: Path) -> list[Path]:
	files: list[Path] = []
	history = codex_root / "history.jsonl"
	if history.is_file():
		files.append(history)

	sessions = codex_root / "sessions"
	if sessions.is_dir():
		files.extend(sorted(sessions.rglob("*.jsonl")))

	return files


def state_sqlite_files(codex_root: Path) -> list[Path]:
	return [path for path in [codex_root / "state_5.sqlite", codex_root / "sqlite/state_5.sqlite"] if path.is_file()]


def main() -> int:
	args = parse_args()
	codex_root = args.codex_root
	if not codex_root.is_dir():
		raise SystemExit(f"Codex root not found: {codex_root}")

	replacements = build_replacements(args)
	if not replacements:
		print("No Codex path rewrites were needed.")
		return 0

	jsonl_files_changed = 0
	jsonl_lines_changed = 0
	sqlite_files_changed = 0
	sqlite_rows_changed = 0
	sqlite_cells_changed = 0

	for path in conversation_jsonl_files(codex_root):
		lines_changed, _ = rewrite_jsonl_file(path, replacements)
		if lines_changed:
			jsonl_files_changed += 1
			jsonl_lines_changed += lines_changed

	for path in state_sqlite_files(codex_root):
		rows_changed, cells_changed = rewrite_sqlite_file(path, replacements)
		if rows_changed:
			sqlite_files_changed += 1
			sqlite_rows_changed += rows_changed
			sqlite_cells_changed += cells_changed

	if not any([jsonl_files_changed, sqlite_files_changed]):
		print("No container Codex paths found to rewrite.")
		return 0

	print(
		"Rewrote Codex host paths: "
		f"{jsonl_lines_changed} JSONL lines across {jsonl_files_changed} files; "
		f"{sqlite_rows_changed} SQLite rows / {sqlite_cells_changed} cells across {sqlite_files_changed} files."
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
