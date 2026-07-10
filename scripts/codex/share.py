#!/usr/bin/env python3
"""Safely migrate Codex conversations into a Windows/WSL shared home."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tomllib
from typing import Any


DB_NAMES = ("state_5.sqlite", "goals_1.sqlite", "memories_1.sqlite")
SHARED_DIRECTORIES = (
    "sessions",
    "archived_sessions",
    "memories",
    "rules",
    "shell_snapshots",
    "generated_images",
)
SHARED_FILES = ("history.jsonl",)
ROOT_DB_NAMES = ("state_5.sqlite", "goals_1.sqlite", "memories_1.sqlite", "logs_2.sqlite")
def detect_windows_home() -> Path:
    configured = os.environ.get("WINHOME") or os.environ.get("CODEX_WINDOWS_HOME")
    if configured:
        return Path(configured)
    powershell = shutil.which("powershell.exe")
    wslpath = shutil.which("wslpath")
    if powershell and wslpath:
        result = subprocess.run(
            [powershell, "-NoLogo", "-NoProfile", "-Command", "$env:USERPROFILE"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0 and result.stdout.strip():
            translated = subprocess.run(
                [wslpath, "-u", result.stdout.strip().replace("\r", "")],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            if translated.returncode == 0 and translated.stdout.strip():
                return Path(translated.stdout.strip())
    return Path("/mnt/c/Users") / os.environ.get("WINDOWS_USERNAME", Path.home().name)


DEFAULT_SOURCE_HOME = Path.home() / ".codex"
DEFAULT_WINDOWS_HOME = detect_windows_home() / ".codex"
DEFAULT_SQLITE_HOME = DEFAULT_SOURCE_HOME / "sqlite"
DEFAULT_STATE_DIR = Path.home() / ".local/state/dotfiles/codex-share"


def utc_stamp() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")


def format_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
        size /= 1024
    raise AssertionError("unreachable")


def tree_size(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except FileNotFoundError:
                pass
    return total


def windows_tree_size(path: Path) -> int:
    """Measure a DrvFS tree natively; walking it through 9P is much slower."""
    powershell = shutil.which("powershell.exe")
    wslpath = shutil.which("wslpath")
    if powershell and wslpath and path.is_relative_to("/mnt"):
        try:
            windows_path = run([wslpath, "-w", str(path)], capture=True).stdout.strip()
            escaped = windows_path.replace("'", "''")
            script = (
                f"(Get-ChildItem -LiteralPath '{escaped}' -File -Recurse -Force "
                "-ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum"
            )
            output = run(
                [powershell, "-NoLogo", "-NoProfile", "-Command", script], capture=True
            ).stdout.strip()
            return int(output or "0")
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return tree_size(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def copy_tree(source: Path, target: Path, *, exclude_git: bool = False) -> None:
    target.mkdir(parents=True, exist_ok=True)
    rsync = shutil.which("rsync")
    if rsync:
        command = [rsync, "-a", "--delete"]
        if exclude_git:
            command.extend(("--exclude", ".git/"))
        if sys.stdout.isatty():
            command.append("--info=progress2")
        command.extend((f"{source}/", f"{target}/"))
        run(command)
        return

    if target.exists():
        shutil.rmtree(target)
    ignore = shutil.ignore_patterns(".git") if exclude_git else None
    shutil.copytree(source, target, symlinks=True, ignore=ignore)


def replace_with_source(source: Path, target: Path, *, exclude_git: bool = False) -> None:
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.exists():
        shutil.rmtree(target)
    if source.is_dir():
        copy_tree(source, target, exclude_git=exclude_git)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def sqlite_check(path: Path, *, full: bool = False) -> tuple[bool, str]:
    if not path.is_file():
        return False, "missing"
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        pragma = "integrity_check" if full else "quick_check"
        rows = [row[0] for row in connection.execute(f"PRAGMA {pragma}")]
        connection.close()
    except sqlite3.Error as exc:
        return False, str(exc)
    result = ", ".join(rows)
    return rows == ["ok"], result


def thread_summary(state_db: Path, expected_home: Path | None = None) -> dict[str, Any]:
    summary: dict[str, Any] = {"threads": 0, "missing_rollouts": [], "foreign_paths": []}
    connection = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    rows = connection.execute("SELECT id, rollout_path FROM threads ORDER BY id").fetchall()
    connection.close()
    summary["threads"] = len(rows)
    prefix = f"{expected_home}/" if expected_home else None
    for thread_id, raw_path in rows:
        path = Path(raw_path)
        if prefix and not raw_path.startswith(prefix):
            summary["foreign_paths"].append({"id": thread_id, "path": raw_path})
        if not path.is_file():
            summary["missing_rollouts"].append({"id": thread_id, "path": raw_path})
    return summary


def linux_codex_processes() -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            pid = int(entry.name)
            comm = (entry / "comm").read_text().strip()
            raw = (entry / "cmdline").read_bytes().split(b"\0")
            args = [value.decode(errors="replace") for value in raw if value]
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        lower_comm = comm.lower()
        joined = " ".join(args).lower()
        is_codex = (
            lower_comm == "codex"
            or lower_comm.startswith("codex-")
            or lower_comm.startswith("chatgpt")
            or ("@openai/codex" in joined and args and Path(args[0]).name in {"node", "bun"})
        )
        if is_codex:
            matches.append({"side": "WSL", "pid": pid, "name": comm, "command": " ".join(args)})
    return sorted(matches, key=lambda item: int(item["pid"]))


def windows_codex_processes() -> list[dict[str, Any]]:
    powershell = shutil.which("powershell.exe")
    if not powershell:
        raise RuntimeError("powershell.exe is unavailable")
    script = r"""
$items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(ChatGPT|Codex)(\.exe)?$' -and $_.CommandLine -notmatch ' --type='
} | ForEach-Object {
    [pscustomobject]@{pid=$_.ProcessId; name=$_.Name; command=$_.CommandLine}
})
ConvertTo-Json -Compress -InputObject $items
"""
    try:
        result = run([powershell, "-NoLogo", "-NoProfile", "-Command", script], capture=True)
        payload = json.loads(result.stdout.strip() or "[]")
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Windows process query failed: {exc}") from exc
    if isinstance(payload, dict):
        payload = [payload]
    return [
        {
            "side": "Windows",
            "pid": item.get("pid"),
            "name": item.get("name", "unknown"),
            "command": item.get("command") or "",
        }
        for item in payload
    ]


def active_clients() -> list[dict[str, Any]]:
    return linux_codex_processes() + windows_codex_processes()


def source_conversation_bytes(source_home: Path) -> int:
    total = sum(tree_size(source_home / name) for name in SHARED_DIRECTORIES)
    total += sum(tree_size(source_home / name) for name in SHARED_FILES)
    return total


def preflight(args: argparse.Namespace, *, verbose: bool = True) -> tuple[list[str], dict[str, Any]]:
    source_home = args.source_home
    windows_home = args.windows_home
    sqlite_home = args.sqlite_home
    blockers: list[str] = []
    details: dict[str, Any] = {}

    if not source_home.is_dir():
        blockers.append(f"WSL source home does not exist: {source_home}")
    if not windows_home.is_dir():
        blockers.append(f"Windows Codex home does not exist: {windows_home}")
    if source_home == windows_home:
        blockers.append("WSL source and Windows home resolve to the same path")
    if sqlite_home != source_home / "sqlite":
        blockers.append(f"SQLite home must be {source_home / 'sqlite'} for the guarded cutover")

    source_state = source_home / "state_5.sqlite"
    if not source_state.is_file() and (sqlite_home / "state_5.sqlite").is_file():
        blockers.append("The shared layout already appears to be active")
    for name in DB_NAMES:
        path = source_home / name
        ok, result = sqlite_check(path)
        details[f"source_{name}"] = result
        if not ok:
            blockers.append(f"Source {name} failed SQLite quick_check: {result}")

    if source_state.is_file():
        try:
            summary = thread_summary(source_state, source_home)
            details.update(summary)
            if summary["foreign_paths"]:
                blockers.append(
                    f"{len(summary['foreign_paths'])} indexed rollout paths are outside {source_home}"
                )
            if summary["missing_rollouts"]:
                blockers.append(f"{len(summary['missing_rollouts'])} indexed rollout files are missing")
        except sqlite3.Error as exc:
            blockers.append(f"Could not inspect source thread index: {exc}")

    if not (windows_home / "config.toml").is_file():
        blockers.append(f"Windows settings file is missing: {windows_home / 'config.toml'}")
    else:
        try:
            tomllib.loads((windows_home / "config.toml").read_text())
        except (OSError, tomllib.TOMLDecodeError) as exc:
            blockers.append(f"Windows settings file is invalid TOML: {exc}")

    process_error = None
    try:
        clients = [] if args.skip_process_check else active_clients()
    except RuntimeError as exc:
        clients = []
        process_error = str(exc)
        blockers.append(f"Could not verify that the Windows GUI is closed: {exc}")
    details["active_clients"] = clients
    details["process_error"] = process_error
    if clients:
        blockers.append(f"{len(clients)} ChatGPT/Codex process(es) are still active")

    if source_home.exists() and windows_home.exists():
        source_bytes = source_conversation_bytes(source_home)
        windows_bytes = windows_tree_size(windows_home)
        required_windows = source_bytes + windows_bytes + max(256 * 1024 * 1024, (source_bytes + windows_bytes) // 20)
        windows_free = shutil.disk_usage(windows_home.parent).free
        wsl_free = shutil.disk_usage(source_home.parent).free
        db_bytes = sum(tree_size(source_home / name) for name in DB_NAMES)
        required_wsl = max(256 * 1024 * 1024, db_bytes * 3)
        details.update(
            {
                "conversation_bytes": source_bytes,
                "windows_home_bytes": windows_bytes,
                "windows_free": windows_free,
                "windows_required": required_windows,
                "wsl_free": wsl_free,
                "wsl_required": required_wsl,
            }
        )
        if windows_free < required_windows:
            blockers.append(
                f"Windows needs about {format_bytes(required_windows)}, but only {format_bytes(windows_free)} is free"
            )
        if wsl_free < required_wsl:
            blockers.append(
                f"WSL needs about {format_bytes(required_wsl)}, but only {format_bytes(wsl_free)} is free"
            )

    if verbose:
        print(f"WSL conversation source: {source_home}")
        print(f"Shared Windows home:    {windows_home}")
        print(f"Shared SQLite home:     {sqlite_home}")
        if "threads" in details:
            print(f"Indexed WSL threads:    {details['threads']}")
        if "conversation_bytes" in details:
            print(f"Conversation payloads:  {format_bytes(details['conversation_bytes'])}")
            print(
                "Free space:             "
                f"Windows {format_bytes(details['windows_free'])}; WSL {format_bytes(details['wsl_free'])}"
            )
        if clients:
            print("Active clients:")
            for client in clients:
                print(f"  {client['side']} PID {client['pid']}: {client['name']} {client['command']}")
        if blockers:
            print("Preflight blockers:")
            for blocker in blockers:
                print(f"  - {blocker}")
        else:
            print("Preflight passed; the stores are quiescent and ready for migration.")
    return blockers, details


def toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def merge_windows_config(config_path: Path, source_config_path: Path, sqlite_home: Path) -> dict[str, int]:
    text = config_path.read_text()
    tomllib.loads(text)
    source_parsed = tomllib.loads(source_config_path.read_text()) if source_config_path.is_file() else {}

    root_pattern = re.compile(r"(?m)^sqlite_home\s*=.*$")
    assignment = f"sqlite_home = {toml_quote(str(sqlite_home))}"
    if root_pattern.search(text):
        text = root_pattern.sub(assignment, text, count=1)
    else:
        table = re.search(r"(?m)^\[", text)
        offset = table.start() if table else len(text)
        before = text[:offset].rstrip()
        after = text[offset:].lstrip()
        text = f"{before}\n{assignment}\n"
        if after:
            text += f"{after}"

    parsed = tomllib.loads(text)
    windows_projects = dict(parsed.get("projects", {}))
    source_projects = dict(source_parsed.get("projects", {}))
    translated: dict[str, Any] = {}
    linux_home = str(sqlite_home.parent.parent)
    for path, values in windows_projects.items():
        translated[re.sub(r"^/home/[^/]+", linux_home, path)] = values
    for path, values in source_projects.items():
        translated[path] = values

    added = 0
    for path, values in translated.items():
        if path in windows_projects:
            continue
        text = text.rstrip() + f"\n\n[projects.{toml_quote(path)}]\n"
        for key, value in values.items():
            if isinstance(value, str):
                text += f"{key} = {toml_quote(value)}\n"
            elif isinstance(value, bool):
                text += f"{key} = {'true' if value else 'false'}\n"
            elif isinstance(value, int):
                text += f"{key} = {value}\n"
            else:
                raise ValueError(f"Unsupported project setting {key!r} for {path!r}")
        windows_projects[path] = values
        added += 1

    tomllib.loads(text)
    config_path.write_text(text)
    return {"projects_added": added}


def rewrite_workspace_roots(path: Path, source_home: Path) -> int:
    if not path.is_file():
        return 0
    payload = json.loads(path.read_text())
    changed = 0
    keys = ("electron-saved-workspace-roots", "project-order", "active-workspace-roots")
    prefix = re.compile(r"^\\\\(?:wsl\$|wsl\.localhost)\\[^\\]+\\home\\[^\\]+", re.I)
    distro = os.environ.get("WSL_DISTRO_NAME", "NixOS")
    linux_home = str(source_home.parent).replace("/", "\\")
    replacement = rf"\\wsl.localhost\{distro}{linux_home}"
    for key in keys:
        values = payload.get(key)
        if not isinstance(values, list):
            continue
        rewritten: list[Any] = []
        for value in values:
            new_value = prefix.sub(lambda _: replacement, value) if isinstance(value, str) else value
            if new_value != value:
                changed += 1
            if new_value not in rewritten:
                rewritten.append(new_value)
        payload[key] = rewritten
    path.write_text(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")
    return changed


def clone_databases(source_home: Path, stage: Path, windows_home: Path) -> dict[str, Any]:
    stage.mkdir(parents=True)
    results: dict[str, Any] = {}
    for name in DB_NAMES:
        source = source_home / name
        target = stage / name
        source_connection = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
        target_connection = sqlite3.connect(target)
        source_connection.backup(target_connection)
        source_connection.close()
        target_connection.execute("PRAGMA journal_mode=DELETE")

        if name == "state_5.sqlite":
            source_prefix = f"{source_home}/"
            target_prefix = f"{windows_home}/"
            rows = target_connection.execute("SELECT id, rollout_path FROM threads").fetchall()
            foreign = [path for _, path in rows if not path.startswith(source_prefix)]
            if foreign:
                raise RuntimeError(f"Refusing to rewrite {len(foreign)} rollout paths outside {source_home}")
            target_connection.execute(
                "UPDATE threads SET rollout_path = ? || substr(rollout_path, ?)",
                (target_prefix, len(source_prefix) + 1),
            )
            results["threads"] = len(rows)
        elif name == "memories_1.sqlite":
            cursor = target_connection.execute(
                """
                UPDATE jobs
                   SET status = 'pending', worker_id = NULL, ownership_token = NULL,
                       started_at = NULL, lease_until = NULL
                 WHERE status = 'running'
                """
            )
            results["memory_leases_reset"] = cursor.rowcount

        target_connection.commit()
        target_connection.execute("REINDEX")
        target_connection.execute("VACUUM")
        integrity = [row[0] for row in target_connection.execute("PRAGMA integrity_check")]
        foreign_keys = list(target_connection.execute("PRAGMA foreign_key_check"))
        target_connection.close()
        if integrity != ["ok"]:
            raise RuntimeError(f"{name} integrity_check failed: {integrity}")
        if foreign_keys:
            raise RuntimeError(f"{name} foreign_key_check failed: {foreign_keys[:5]}")
        results[f"{name}_sha256"] = sha256(target)
    return results


def remove_stale_databases(home: Path) -> None:
    for name in ROOT_DB_NAMES:
        for suffix in ("", "-shm", "-wal"):
            path = home / f"{name}{suffix}"
            if path.exists() or path.is_symlink():
                path.unlink()
    stale_sqlite = home / "sqlite"
    if stale_sqlite.exists():
        shutil.rmtree(stale_sqlite)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def commit_stages(
    source_home: Path,
    windows_home: Path,
    sqlite_home: Path,
    windows_stage: Path,
    sqlite_stage: Path,
    stamp: str,
) -> tuple[Path, Path]:
    windows_archive = windows_home.with_name(f"{windows_home.name}-windows-before-share-{stamp}")
    wsl_archive = source_home.with_name(f"{source_home.name}-wsl-source-{stamp}")
    if windows_archive.exists() or wsl_archive.exists():
        raise RuntimeError("A timestamped rollback target already exists")

    windows_home.rename(windows_archive)
    try:
        windows_stage.rename(windows_home)
    except BaseException:
        windows_archive.rename(windows_home)
        raise

    try:
        source_home.rename(wsl_archive)
        source_home.mkdir(mode=0o700)
        sqlite_stage.rename(sqlite_home)
    except BaseException:
        if sqlite_home.exists() and not sqlite_stage.exists():
            sqlite_home.rename(sqlite_stage)
        if source_home.exists():
            shutil.rmtree(source_home)
        if wsl_archive.exists():
            wsl_archive.rename(source_home)
        if windows_home.exists():
            windows_home.rename(windows_stage)
        windows_archive.rename(windows_home)
        raise
    return wsl_archive, windows_archive


def migrate(args: argparse.Namespace) -> int:
    blockers, details = preflight(args)
    if blockers:
        print("Migration did not start; nothing was changed.", file=sys.stderr)
        return 2

    if not args.yes:
        answer = input("Type MIGRATE to create the shared store and preserve both rollback archives: ")
        if answer != "MIGRATE":
            print("Migration cancelled; nothing was changed.")
            return 2

    stamp = utc_stamp()
    source_home = args.source_home
    windows_home = args.windows_home
    sqlite_home = args.sqlite_home
    windows_stage = windows_home.with_name(f"{windows_home.name}-shared-stage-{stamp}")
    sqlite_stage = source_home.with_name(f"{source_home.name}-sqlite-stage-{stamp}")
    manifest: dict[str, Any] = {
        "version": 1,
        "created_at": dt.datetime.now(dt.UTC).isoformat(),
        "source_home": str(source_home),
        "windows_home": str(windows_home),
        "sqlite_home": str(sqlite_home),
        "source_threads": details.get("threads"),
        "source_conversation_bytes": details.get("conversation_bytes"),
    }

    print(f"Staging Windows settings and runtime state in {windows_stage} ...")
    copy_tree(windows_home, windows_stage)
    remove_stale_databases(windows_stage)

    for name in SHARED_DIRECTORIES:
        source = source_home / name
        if source.exists():
            print(f"Importing WSL {name} ...")
            replace_with_source(source, windows_stage / name, exclude_git=name == "memories")
    for name in SHARED_FILES:
        source = source_home / name
        if source.exists():
            print(f"Importing WSL {name} ...")
            replace_with_source(source, windows_stage / name)

    config_result = merge_windows_config(
        windows_stage / "config.toml", source_home / "config.toml", sqlite_home
    )
    manifest.update(config_result)
    workspace_rewrites = 0
    for name in (".codex-global-state.json", ".codex-global-state.json.bak"):
        workspace_rewrites += rewrite_workspace_roots(windows_stage / name, source_home)
    manifest["workspace_roots_rewritten"] = workspace_rewrites

    print(f"Cloning and validating authoritative WSL databases in {sqlite_stage} ...")
    database_results = clone_databases(source_home, sqlite_stage, windows_home)
    manifest.update(database_results)

    # The staged home has a sibling name, while its index intentionally records
    # final paths. Verify by mapping final paths back into the staging directory.
    missing: list[str] = []
    connection = sqlite3.connect(f"file:{sqlite_stage / 'state_5.sqlite'}?mode=ro", uri=True)
    for (rollout_path,) in connection.execute("SELECT rollout_path FROM threads"):
        relative = Path(rollout_path).relative_to(windows_home)
        if not (windows_stage / relative).is_file():
            missing.append(rollout_path)
    connection.close()
    if missing:
        raise RuntimeError(f"Staged shared home is missing {len(missing)} indexed rollouts")
    manifest["staged_rollouts_verified"] = database_results["threads"]
    write_json(windows_stage / "migration-manifest.json", manifest)

    print("Committing the staged stores with rollback-safe renames ...")
    wsl_archive, windows_archive = commit_stages(
        source_home, windows_home, sqlite_home, windows_stage, sqlite_stage, stamp
    )
    manifest["wsl_rollback_archive"] = str(wsl_archive)
    manifest["windows_rollback_archive"] = str(windows_archive)
    manifest["completed_at"] = dt.datetime.now(dt.UTC).isoformat()
    write_json(windows_home / "migration-manifest.json", manifest)
    write_json(source_home / "migration-manifest.json", manifest)
    write_json(args.state_dir / "active.json", manifest)

    final_summary = thread_summary(sqlite_home / "state_5.sqlite", windows_home)
    if final_summary["missing_rollouts"] or final_summary["foreign_paths"]:
        raise RuntimeError("Post-commit rollout verification failed; use the rollback paths in the manifest")
    for name in DB_NAMES:
        ok, result = sqlite_check(sqlite_home / name, full=True)
        if not ok:
            raise RuntimeError(f"Post-commit {name} integrity check failed: {result}")

    print(f"Shared store committed with {final_summary['threads']} indexed conversations.")
    print(f"WSL rollback archive:     {wsl_archive}")
    print(f"Windows rollback archive: {windows_archive}")

    if args.skip_nix_apply:
        print("Skipped the NixOS boot-generation update as requested.")
    else:
        dotctl = Path(__file__).resolve().parents[1] / "dotctl"
        print("Installing the NixOS-WSL boot generation with the shared-store environment ...")
        result = subprocess.run([str(dotctl), "apply", "nixos-wsl"], check=False)
        if result.returncode != 0:
            print(
                "The data migration succeeded, but the NixOS generation failed to install. "
                "Run: dotctl apply nixos-wsl",
                file=sys.stderr,
            )
            return result.returncode

    print("Cutover is complete. Restart NixOS WSL before opening either client:")
    print("  wsl.exe -t NixOS")
    print("After restart, use one active writer at a time and run: dotctl codex-share doctor")
    return 0


def doctor(args: argparse.Namespace) -> int:
    source_home = args.source_home
    windows_home = args.windows_home
    sqlite_home = args.sqlite_home
    expected_home = Path(os.environ.get("CODEX_HOME", str(windows_home)))
    expected_sqlite = Path(os.environ.get("CODEX_SQLITE_HOME", str(sqlite_home)))
    print(f"Configured CODEX_HOME:        {expected_home}")
    print(f"Configured CODEX_SQLITE_HOME: {expected_sqlite}")
    print(f"Intended Windows home:        {windows_home}")
    print(f"Intended ext4 SQLite home:    {sqlite_home}")

    problems: list[str] = []
    config_path = windows_home / "config.toml"
    if config_path.is_file():
        try:
            config = tomllib.loads(config_path.read_text())
            print(f"Windows settings sqlite_home: {config.get('sqlite_home', 'not set')}")
        except tomllib.TOMLDecodeError as exc:
            problems.append(f"Windows config is invalid TOML: {exc}")
    else:
        problems.append(f"Windows config is missing: {config_path}")

    state_db = sqlite_home / "state_5.sqlite"
    if state_db.is_file():
        for name in DB_NAMES:
            ok, result = sqlite_check(sqlite_home / name)
            print(f"{name:24} {result}")
            if not ok:
                problems.append(f"{name}: {result}")
        try:
            summary = thread_summary(state_db, windows_home)
            print(f"Indexed shared threads:       {summary['threads']}")
            print(f"Missing rollout files:        {len(summary['missing_rollouts'])}")
            print(f"Rollouts outside shared home: {len(summary['foreign_paths'])}")
            if summary["missing_rollouts"]:
                problems.append(f"{len(summary['missing_rollouts'])} indexed rollout files are missing")
            if summary["foreign_paths"]:
                problems.append(f"{len(summary['foreign_paths'])} rollout paths point outside the shared home")
        except sqlite3.Error as exc:
            problems.append(f"Could not inspect shared state: {exc}")
    elif (source_home / "state_5.sqlite").is_file():
        print("Layout status:                not migrated; authoritative DB is still in the WSL home root")
    else:
        problems.append("No authoritative state_5.sqlite was found")

    try:
        clients = active_clients()
    except RuntimeError as exc:
        clients = []
        problems.append(f"Could not inspect Windows client processes: {exc}")
    print(f"Active ChatGPT/Codex clients: {len(clients)}")
    for client in clients:
        print(f"  {client['side']} PID {client['pid']}: {client['name']} {client['command']}")
    if len(clients) > 1:
        print("Writer warning: more than one client is active; finish work in one before using the other.")

    archives = sorted(source_home.parent.glob(f"{source_home.name}-wsl-source-*"))
    archives += sorted(windows_home.parent.glob(f"{windows_home.name}-windows-before-share-*"))
    if archives:
        print("Rollback archives:")
        for archive in archives:
            print(f"  {archive}")

    if problems:
        print("Problems:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("Shared-store checks passed.")
    return 0


def add_path_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--source-home",
        type=Path,
        default=Path(os.environ.get("CODEX_SHARE_SOURCE_HOME", DEFAULT_SOURCE_HOME)),
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--windows-home",
        type=Path,
        default=Path(os.environ.get("CODEX_SHARE_WINDOWS_HOME", DEFAULT_WINDOWS_HOME)),
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--sqlite-home",
        type=Path,
        default=Path(os.environ.get("CODEX_SHARE_SQLITE_HOME", DEFAULT_SQLITE_HOME)),
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path(os.environ.get("CODEX_SHARE_STATE_DIR", DEFAULT_STATE_DIR)),
        help=argparse.SUPPRESS,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Diagnose or migrate the Windows/WSL shared Codex conversation store."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor_parser = subparsers.add_parser("doctor", help="Check the active shared-store layout")
    add_path_arguments(doctor_parser)

    preflight_parser = subparsers.add_parser(
        "preflight", help="Validate source data, free space, and the no-active-client gate"
    )
    add_path_arguments(preflight_parser)
    preflight_parser.add_argument("--skip-process-check", action="store_true", help=argparse.SUPPRESS)

    migrate_parser = subparsers.add_parser(
        "migrate", help="Create the shared store while preserving complete rollback archives"
    )
    add_path_arguments(migrate_parser)
    migrate_parser.add_argument("--yes", action="store_true", help="Skip the MIGRATE confirmation prompt")
    migrate_parser.add_argument("--skip-process-check", action="store_true", help=argparse.SUPPRESS)
    migrate_parser.add_argument("--skip-nix-apply", action="store_true", help=argparse.SUPPRESS)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    for attribute in ("source_home", "windows_home", "sqlite_home", "state_dir"):
        setattr(args, attribute, getattr(args, attribute).expanduser().resolve())
    if args.command == "doctor":
        return doctor(args)
    if args.command == "preflight":
        blockers, _ = preflight(args)
        return 1 if blockers else 0
    if args.command == "migrate":
        return migrate(args)
    raise AssertionError("unreachable")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted; inspect any *-shared-stage-* directories before retrying.", file=sys.stderr)
        raise SystemExit(130)
