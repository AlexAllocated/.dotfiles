#!/usr/bin/env python3
"""Archive regression checks: no Codex installation or network required."""

import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "archive", Path(__file__).resolve().parents[1] / "scripts/codex/archive.py"
)
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def test_history_preservation_and_refresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / "source", root / "archive"
            (source / "sessions").mkdir(parents=True)
            (source / "auth.json").write_text("credential-must-not-be-exported")
            log = source / "sessions/rollout-test.jsonl"
            events = [
                {"type": "session_meta", "payload": {"id": "current", "cwd": "/project"}},
                # Forked logs can contain an older session's metadata next.
                {"type": "session_meta", "payload": {"id": "parent", "cwd": "/old"}},
                {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Question"}]}},
                {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Answer"}]}},
                {"type": "response_item", "payload": {"type": "function_call", "arguments": "raw tool evidence"}},
            ]
            log.write_text("".join(json.dumps(event) + "\n" for event in events))
            database = sqlite3.connect(source / "state_5.sqlite")
            self.addCleanup(database.close)
            database.execute("PRAGMA journal_mode=WAL")
            database.execute("CREATE TABLE threads(id TEXT, title TEXT)")
            database.execute("INSERT INTO threads VALUES ('current', 'Current title')")
            database.commit()
            # Preserve already-damaged historical backups without treating them as valid snapshots.
            (source / "db-backups").mkdir()
            damaged = source / "db-backups/state_5.sqlite"
            damaged.write_bytes(b"damaged legacy database")
            archive.export(source, target)
            self.assertFalse((target / "raw/auth.json").exists())
            self.assertEqual(log.read_bytes(), (target / "raw/sessions/rollout-test.jsonl").read_bytes())
            self.assertEqual(damaged.read_bytes(), (target / "raw/db-backups/state_5.sqlite").read_bytes())
            self.assertIn("Answer", (target / "transcripts/sessions/rollout-test.md").read_text())
            item = json.loads((target / "index.jsonl").read_text())
            self.assertEqual((item["id"], item["title"], item["cwd"]), ("current", "Current title", "/project"))
            with sqlite3.connect(target / "raw/state_5.sqlite") as snapshot:
                self.assertEqual(snapshot.execute("SELECT count(*) FROM threads").fetchone(), (1,))
            with log.open("a") as stream:
                stream.write('{"unfinished":')
            archive.export(source, target)
            self.assertEqual(len(json.loads((target / "manifest.json").read_text())["warnings"]), 2)
            self.assertEqual(log.read_bytes(), (target / "raw/sessions/rollout-test.jsonl").read_bytes())
            for line in (target / "SHA256SUMS").read_text().splitlines():
                expected, path = line.split("  ", 1)
                self.assertEqual(archive.digest(target / path), expected)
            unrelated = root / "unrelated"
            unrelated.mkdir()
            with self.assertRaises(ValueError):
                archive.export(source, unrelated)
            with self.assertRaises(ValueError):
                archive.export(source, source / "nested")
            database.close()


if __name__ == "__main__":
    unittest.main()
