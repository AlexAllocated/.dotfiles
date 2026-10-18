import argparse
import errno
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def wine_server_running(prefix, proc_root=Path("/proc")):
    prefix = prefix.resolve()
    for process in proc_root.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            if (process / "comm").read_text().strip() not in ("wineserver", "wineserver64"):
                continue
            environment = (process / "environ").read_bytes().split(b"\0")
            server_prefix = next((entry[len(b"WINEPREFIX="):] for entry in environment
                                  if entry.startswith(b"WINEPREFIX=")), None)
            if server_prefix is None:
                server_prefix = os.fsencode(Path.home() / ".wine")
            # UMU can use pfx/pfx -> .; compare canonical paths, not spelling.
            if Path(os.fsdecode(server_prefix)).resolve() == prefix:
                return True
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ESRCH):
                # Uncertain process ownership/access must not enable a live
                # global DPI change. main() reports the error and skips it.
                raise
    return False


def display_dpi(outputs, workspaces):
    active = {
        name: output["logical"]
        for name, output in outputs.items()
        if output.get("current_mode") is not None and output.get("logical")
    }
    focused = next((w.get("output") for w in workspaces if w.get("is_focused")), None)
    if focused in active:
        logical = active[focused]
    elif len(active) == 1:
        logical = next(iter(active.values()))
    else:
        raise ValueError("Cannot determine the display to use for Wine scaling")
    scale = logical.get("scale")
    if isinstance(scale, bool) or not isinstance(scale, (int, float)) or not math.isfinite(scale) or not 0.5 <= scale <= 4:
        raise ValueError("Unsupported display scale")
    return round(96 * scale)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Choose Wine DPI for a new prefix session")
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument(
        "--dpi", type=int, choices=range(48, 385), metavar="48..384",
        help="use a fixed baseline for a prefix shared across differently scaled displays",
    )
    args = parser.parse_args(argv)
    try:
        if wine_server_running(args.prefix):
            print("Keeping existing Wine DPI: this prefix already has a running Wine session", file=sys.stderr)
            return 1
        if args.dpi is not None:
            print(args.dpi)
            return 0
        data = [
            json.loads(subprocess.run(
                ["niri", "msg", "--json", query],
                check=True, capture_output=True, text=True, timeout=3,
            ).stdout)
            for query in ("outputs", "workspaces")
        ]
        print(display_dpi(*data))
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        print(f"Keeping existing Wine DPI: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
