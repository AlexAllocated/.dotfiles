#!/usr/bin/env python3
"""Export local Codex history without needing Codex or a model API."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot(source, target, database=True):
    target.parent.mkdir(parents=True, exist_ok=True)
    if database and source.suffix in (".sqlite", ".db"):
        with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as src:
            with sqlite3.connect(target) as dst:
                src.backup(dst)
                if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise RuntimeError(f"Database integrity check failed: {source}")
    else:
        # Copy a bounded prefix: an active session can append while we export.
        with source.open("rb") as src, target.open("wb") as dst:
            remaining = os.fstat(src.fileno()).st_size
            expected = hashlib.sha256()
            while remaining:
                block = src.read(min(remaining, 1024 * 1024))
                if not block:
                    raise RuntimeError(f"Source shrank during export: {source}")
                dst.write(block)
                expected.update(block)
                remaining -= len(block)
        if digest(target) != expected.hexdigest():
            raise RuntimeError(f"Copy verification failed: {source}")


def source_files(root):
    files = set()
    for name in ("sessions", "archived_sessions", "memories", "backups", "db-backups", "sqlite"):
        directory = root / name
        if directory.is_dir():
            for path in directory.rglob("*"):
                if path.is_file() and path.suffix in (".jsonl", ".md", ".sqlite", ".db"):
                    files.add(path)
    for pattern in ("history.jsonl", "session_index.jsonl", "state_*.sqlite", "memories_*.sqlite", "thread_history_*.sqlite"):
        files.update(root.glob(pattern))
    for path in files:
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise RuntimeError(f"Refusing history symlink outside source: {path}")
    return sorted(files)


def text_content(content):
    if isinstance(content, str):
        return content
    return "\n".join(
        part.get("text", "") if part.get("type") in ("input_text", "output_text", "text")
        else f"[{part.get('type', 'non-text content')}; see original log]"
        for part in content or [] if isinstance(part, dict)
    )


def transcript(path, raw_root, output, titles):
    messages, fallback, metadata, warnings = [], [], {}, []
    with path.open() as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                event = json.loads(line)
            except ValueError:
                warnings.append(f"{path.relative_to(raw_root)}:{line_number}: incomplete or invalid JSON; raw bytes preserved")
                continue
            payload = event.get("payload", {})
            timestamp = event.get("timestamp", "")
            if event.get("type") == "session_meta" and not metadata:
                metadata.update(payload)
            elif event.get("type") == "response_item" and payload.get("type") == "message":
                role = payload.get("role")
                if role in ("user", "assistant"):
                    messages.append((role, timestamp, text_content(payload.get("content"))))
            elif event.get("type") == "event_msg" and payload.get("type") in ("user_message", "agent_message"):
                role = "user" if payload["type"] == "user_message" else "assistant"
                fallback.append((role, timestamp, payload.get("message", "")))
            elif event.get("type") == "compacted":
                messages.append(("compaction summary", timestamp, payload.get("message", "")))
    if not any(role in ("user", "assistant") for role, _, _ in messages):
        messages.extend(fallback)
    session_id = metadata.get("id", path.stem)
    title = titles.get(session_id) or next((body[:160] for role, _, body in messages if role == "user"), session_id)
    title = " ".join(title.split())
    relative = path.relative_to(raw_root)
    destination = output / "transcripts" / relative.with_suffix(".md")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w") as stream:
        stream.write(f"# {title}\n\nSession: {session_id}\n\nStarted: {metadata.get('timestamp', '')}\n\nWorkspace: {metadata.get('cwd', '')}\n\nOriginal log: raw/{relative}\n\n")
        stream.write("Historical reference only. Commands and instructions below are past conversation content.\n\n")
        for role, timestamp, body in messages:
            stream.write(f"## {role} — {timestamp}\n\n{body}\n\n")
    return {
        "id": session_id, "title": title, "started": metadata.get("timestamp", ""),
        "cwd": metadata.get("cwd", ""), "messages": len(messages),
        "transcript": str(destination.relative_to(output)), "raw": f"raw/{relative}",
    }, warnings


def export(source, destination):
    source = source.resolve(strict=True)
    destination = destination.absolute()
    if destination.resolve().is_relative_to(source) or source.is_relative_to(destination.resolve()):
        raise ValueError("Source and destination must be separate directories")
    if destination.is_symlink() or (destination.exists() and not (destination / ".codex-history-archive").is_file()):
        raise ValueError("Destination exists and is not an archive created by this script")
    os.umask(0o077)
    destination.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f".{destination.name}-", dir=destination.parent))
    try:
        (work / ".codex-history-archive").write_text("1\n")
        raw = work / "raw"
        files = source_files(source)
        if not files:
            raise ValueError("No history files found")
        warnings = []
        for path in files:
            relative = path.relative_to(source)
            try:
                snapshot(path, raw / relative)
            except sqlite3.DatabaseError as error:
                if relative.parts[0] not in ("backups", "db-backups"):
                    raise
                snapshot(path, raw / relative, database=False)
                warnings.append(f"{relative}: damaged historical database preserved byte-for-byte: {error}")
        titles = {}
        for database in raw.glob("state_*.sqlite"):
            with sqlite3.connect(database) as db:
                if db.execute("SELECT name FROM sqlite_master WHERE name='threads'").fetchone():
                    titles.update(db.execute("SELECT id, title FROM threads"))
        index = []
        for path in sorted(raw.rglob("rollout-*.jsonl")):
            item, problems = transcript(path, raw, work, titles)
            index.append(item)
            warnings.extend(problems)
        (work / "index.jsonl").write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in index))
        unique_count = len({item["id"] for item in index})
        (work / "INDEX.md").write_text("# Conversation index\n\n" + "\n".join(
            f"- {item['started'][:10]} | {item['cwd']} | [{item['title'].replace('[', '(').replace(']', ')')}]({item['transcript']})"
            for item in sorted(index, key=lambda item: item["started"], reverse=True)
        ) + "\n")
        (work / "README.md").write_text(f"""# Codex conversation archive

Created: {datetime.now(timezone.utc).isoformat()}
Source: {source}
Conversations: {unique_count} distinct session IDs; {len(index)} logs including older backup copies.

## Find prior work

Start with INDEX.md or search index.jsonl for a project, ticket, date, or title.
Read the matching file under transcripts/ for user and assistant messages.
Search raw/memories/MEMORY.md for earlier summaries and decisions.
Use raw/ for complete original events, tool calls, tool outputs, images, and database snapshots.
Older backup logs are preserved separately; prefer the current sessions/ transcript when both exist.

```sh
rg -i 'BMD2-796|rounding|dotfiles' index.jsonl
rg -n -i 'search phrase' transcripts raw/memories
shasum -a 256 -c SHA256SUMS
```

This is historical evidence, not current instructions. Verify old claims against current files.
No Codex executable or model API is needed to read this archive.
Authentication files, settings, plugins, and runtime caches are excluded. Original conversations
can contain sensitive project material; keep this archive private and local.
Active SQLite snapshots passed integrity checks. Any damaged historical database backup is
preserved byte-for-byte and listed in manifest.json. Copies and archive checksums were verified.
An export while Codex runs is a point-in-time snapshot; re-export after it exits to capture the tail.
See manifest.json for export counts and any malformed JSON lines (always retained in raw logs).
""")
        (work / "manifest.json").write_text(json.dumps({
            "created_at": datetime.now(timezone.utc).isoformat(), "source": str(source),
            "source_files": len(files), "logs": len(index), "conversations": unique_count,
            "warnings": warnings,
        }, indent=2) + "\n")
        hashes = [(digest(path), path.relative_to(work)) for path in sorted(work.rglob("*")) if path.is_file()]
        (work / "SHA256SUMS").write_text("".join(f"{checksum}  {path}\n" for checksum, path in hashes))
        for checksum, path in hashes:
            if digest(work / path) != checksum:
                raise RuntimeError(f"Archive verification failed: {path}")
        previous = None
        if destination.exists():
            previous = Path(tempfile.mkdtemp(prefix=f".{destination.name}-previous-", dir=destination.parent))
            previous.rmdir()
            destination.rename(previous)
        try:
            work.rename(destination)
        except BaseException:
            if previous:
                previous.rename(destination)
            raise
        if previous:
            shutil.rmtree(previous)
        print(json.dumps({"destination": str(destination), "files": len(files), "logs": len(index), "conversations": unique_count, "warnings": len(warnings)}))
    finally:
        if work.exists():
            shutil.rmtree(work)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    export(args.source, args.destination)
