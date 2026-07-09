#!/usr/bin/env python3
"""Rewrite restored Codex conversation paths from a container home to a host home."""

from __future__ import annotations

import argparse
import json
import os
import shutil
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


def conversation_jsonl_files(codex_root: Path) -> list[Path]:
	files: list[Path] = []
	history = codex_root / "history.jsonl"
	if history.is_file():
		files.append(history)

	sessions = codex_root / "sessions"
	if sessions.is_dir():
		files.extend(sorted(sessions.rglob("*.jsonl")))

	return files


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

	for path in conversation_jsonl_files(codex_root):
		lines_changed, _ = rewrite_jsonl_file(path, replacements)
		if lines_changed:
			jsonl_files_changed += 1
			jsonl_lines_changed += lines_changed

	if not jsonl_files_changed:
		print("No container Codex paths found to rewrite.")
		return 0

	print(
		"Rewrote Codex host paths: "
		f"{jsonl_lines_changed} JSONL lines across {jsonl_files_changed} files."
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
