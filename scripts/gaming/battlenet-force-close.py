"""Force-close the user's Wine Battle.net and WoW processes, including hidden ones."""

import argparse
import fcntl
from dataclasses import dataclass
import os
from pathlib import Path
import re
import signal
import time


APPLICATIONS = re.compile(r"^(battle\.net(?: launcher)?|battlenet\.overlay\.runtime|wow(?:-64|b|classic(?:b|t)?)?)\.exe$", re.I)
HELPERS = {"agent.exe", "blizzarderror.exe"}
SESSION_HELPERS = {
    "explorer.exe", "services.exe", "winedevice.exe", "plugplay.exe", "rpcss.exe",
    "svchost.exe", "conhost.exe", "wineboot.exe", "tabtip.exe", "start.exe", "steam.exe",
    "wineserver", "wineserver64", "xalia.exe", "wine-display-sync.exe",
}


@dataclass(frozen=True)
class Process:
    pid: int
    start_time: str
    name: str
    prefix: Path


def identity(path):
    # comm may contain spaces or parentheses; field 22 follows the final ')'.
    return (path / "stat").read_text().rsplit(")", 1)[1].split()[19]


def inspect_process(path, uid):
    try:
        if path.stat().st_uid != uid:
            return None
        start = identity(path)
        try:
            argv = (path / "cmdline").read_bytes()
            environment = (path / "environ").read_bytes()
        except OSError:
            argv = environment = b""
        if not argv or not environment:
            # Wine can leave the thread-group leader a zombie while its GUI
            # and browser threads remain alive. Their /proc entries retain argv.
            for thread in (path / "task").iterdir():
                try:
                    candidate = (thread / "cmdline").read_bytes()
                    thread_environment = (thread / "environ").read_bytes()
                    if candidate and thread_environment:
                        argv = candidate
                        environment = thread_environment
                        break
                except OSError:
                    continue
        prefix = next((entry[11:] for entry in environment.split(b"\0")
                       if entry.startswith(b"WINEPREFIX=")), None)
        if not argv or not prefix or identity(path) != start:
            return None
        name = os.fsdecode(argv.split(b"\0", 1)[0]).replace("\\", "/").rsplit("/", 1)[-1]
        return Process(int(path.name), start, name, Path(os.fsdecode(prefix)).resolve())
    except (OSError, ValueError, IndexError):
        return None


def all_processes(proc_root=Path("/proc"), uid=None):
    uid = os.getuid() if uid is None else uid
    return [process for path in proc_root.iterdir() if path.name.isdecimal()
            if (process := inspect_process(path, uid)) is not None]


def targets(prefix, proc_root=Path("/proc"), uid=None):
    processes = all_processes(proc_root, uid)
    applications = [process for process in processes if APPLICATIONS.fullmatch(process.name)]
    prefixes = {prefix.resolve()} | {process.prefix for process in applications}
    return applications + [process for process in processes
                           if process.name.casefold() in HELPERS and process.prefix in prefixes]


def idle_session_targets(prefixes, processes):
    selected = []
    for prefix in prefixes:
        session = [p for p in processes if p.prefix == prefix.resolve()]
        # Unknown Windows applications keep their shared server. Only drain
        # shell/service remnants when the requested applications have exited.
        if any(p.name.lower().endswith(".exe") and p.name.casefold() not in SESSION_HELPERS
               for p in session):
            continue
        selected.extend(p for p in session if p.name.casefold() in SESSION_HELPERS)
    return selected


def kill_process(process, proc_root=Path("/proc")):
    # A pidfd pins the process, preventing PID reuse from killing another app.
    try:
        fd = os.pidfd_open(process.pid)
    except ProcessLookupError:
        return False
    try:
        if identity(proc_root / str(process.pid)) != process.start_time:
            return False
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        return True
    except (FileNotFoundError, ProcessLookupError):
        return False
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path,
                        help="Also clean Blizzard helpers left in this configured prefix")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    selected = targets(args.prefix)
    prefixes = {args.prefix.resolve()} | {process.prefix for process in selected}
    for process in selected:
        if args.dry_run:
            print(f"Would kill {process.name} (PID {process.pid})")
        elif kill_process(process):
            print(f"Killed {process.name} (PID {process.pid})", flush=True)
    if not args.dry_run:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            remaining = targets(args.prefix)
            if not remaining:
                break
            for process in remaining:
                kill_process(process)
            time.sleep(.1)
        else:
            parser.exit(1, "Some Battle.net/WoW processes did not exit\n")
        state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "battlenet"
        state.mkdir(parents=True, exist_ok=True)
        with (state / "startup.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Battle.net startup is in progress; leaving Wine session helpers intact", flush=True)
                return
            for process in idle_session_targets(prefixes, all_processes()):
                if kill_process(process):
                    print(f"Cleaned idle Wine session: {process.name} (PID {process.pid})", flush=True)


if __name__ == "__main__":
    main()
