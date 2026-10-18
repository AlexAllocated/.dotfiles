"""Start a session helper only once its application exists in the same prefix."""

import argparse
import os
from pathlib import Path
import sys
import time
import subprocess
import importlib.util
from datetime import datetime, timezone

# These cannot keep display recovery alive after the last real application.
SESSION_HELPERS = {
    "explorer.exe", "services.exe", "winedevice.exe", "plugplay.exe", "rpcss.exe",
    "svchost.exe", "conhost.exe", "wineboot.exe", "tabtip.exe", "start.exe", "steam.exe",
    "xalia.exe", "wine-display-sync.exe", "agent.exe", "blizzarderror.exe",
}


def process_running(prefix, name, proc_root=Path("/proc")):
    prefix = prefix.resolve()
    names = None if name is None else {n.casefold() for n in ([name] if isinstance(name, str) else name)}
    for process in proc_root.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            # Wine's thread-group leader can exit while the GUI stays alive.
            # Its environ may deny access; read an accessible live thread.
            try:
                argv = (process / "cmdline").read_bytes()
                environment = (process / "environ").read_bytes()
            except OSError:
                argv = environment = b""
            if not argv or not environment:
                for thread in (process / "task").iterdir():
                    try:
                        candidate = (thread / "cmdline").read_bytes()
                        candidate_environment = (thread / "environ").read_bytes()
                        if candidate and candidate_environment:
                            argv, environment = candidate, candidate_environment
                            break
                    except OSError:
                        continue
            # Linux comm is limited to 15 bytes, so compare the full argv[0].
            argv0 = argv.split(b"\0", 1)[0]
            executable = os.fsdecode(argv0).replace("\\", "/").rsplit("/", 1)[-1]
            if names is None:
                if not executable.casefold().endswith(".exe") or executable.casefold() in SESSION_HELPERS:
                    continue
            elif executable.casefold() not in names:
                continue
            value = next((v.split(b"=", 1)[1] for v in environment.split(b"\0")
                          if v.startswith(b"WINEPREFIX=")), None)
            if value and Path(os.fsdecode(value)).resolve() == prefix:
                return True
        except OSError:
            continue
    return False


def supervise(prefix, name, command, run=subprocess.run, sleep=time.sleep,
              display_plan=None, topology_factory=None):
    for attempt in range(4):
        topology = None
        try:
            if topology_factory:
                try:
                    topology = topology_factory(display_plan)
                except BlockingIOError:
                    return 0  # Another supervisor owns both the plan and recovery.
            result = run(command).returncode
        except Exception as error:
            print(f"Wine display recovery attempt failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
            result = 1
        finally:
            if topology:
                try:
                    topology.close()
                except Exception as error:
                    print(f"Wine display publisher cleanup failed: {error}", file=sys.stderr, flush=True)
                    result = 1
        if result == 0 or result == 2:
            return result
        if not process_running(prefix, name):
            return 0
        stamp = datetime.now(timezone.utc).isoformat()
        if attempt == 3:
            print(f"[{stamp}] Wine display helper failed repeatedly; stopping retries", file=sys.stderr)
            return result
        delay = (2, 10, 30)[attempt]
        print(f"[{stamp}] Wine display helper exited {result}; retrying in {delay}s", file=sys.stderr, flush=True)
        sleep(delay)
        if not process_running(prefix, name):
            return 0
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--wait-for", required=True)
    parser.add_argument("--supervise", action="store_true", help="bounded retries while the application remains alive")
    parser.add_argument("--display-plan", type=Path, help="publish real XRandR source IDs while the helper runs")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a helper command is required")
    # This is a bounded startup wait, never an always-on process polling loop.
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        # Once installed, the watcher belongs to the whole prefix. Battle.net
        # can exit while Diablo/Overwatch or another Windows application stays.
        application = None if args.display_plan else args.wait_for
        if process_running(args.prefix, application):
            if args.supervise:
                factory = None
                if args.display_plan:
                    spec = importlib.util.spec_from_file_location("wine_topology", Path(__file__).with_name("wine-display-topology.py"))
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    factory = module.Topology
                    os.environ["WINE_XRANDR_PLAN"] = "Z:" + str(args.display_plan.resolve()).replace("/", "\\")
                return supervise(args.prefix, application, command,
                                 display_plan=args.display_plan, topology_factory=factory)
            os.execvp(command[0], command)
        time.sleep(0.5)
    print(f"No {args.wait_for} in the expected Wine prefix; helper not started", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
