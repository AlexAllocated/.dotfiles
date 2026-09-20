import os
from pathlib import Path
import signal
import subprocess
import sys
import time


SESSION_KEYS = (
    "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "NIRI_SOCKET",
    "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP",
    "SSH_AUTH_SOCK", "CODEX_HOME", "CODEX_SQLITE_HOME",
)
DISPLAY_KEYS = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "NIRI_SOCKET")


def desktop_environment(base, run=subprocess.run, exists=Path.exists):
    try:
        active = run(
            ["systemctl", "--user", "is-active", "--quiet", "graphical-session.target"],
            timeout=5, check=False,
        )
        if active.returncode != 0:
            return None
        result = run(
            ["systemctl", "--user", "show-environment"],
            timeout=5, check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    env = {key: value for key, value in base.items() if key not in SESSION_KEYS}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in SESSION_KEYS:
            env[key] = value
    display = env.get("DISPLAY", "")
    if not display.startswith(":"):
        return None
    number = display[1:].split(".", 1)[0]
    if not number.isdigit() or not exists(Path(f"/tmp/.X11-unix/X{number}")):
        return None
    return env


def app_running(proc=Path("/proc"), uid=None):
    uid = os.getuid() if uid is None else uid
    for directory in proc.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid != uid:
                continue
            executable = os.readlink(directory / "exe").removesuffix(" (deleted)")
            if not executable.endswith("/lib/chatgpt/ChatGPT"):
                continue
            arguments = (directory / "cmdline").read_bytes().split(b"\0")
            if not any(arg == b"--type" or arg.startswith(b"--type=") for arg in arguments):
                return True
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return False


def stop_child(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def tick(child, session, env, executable, running=app_running, launch=subprocess.Popen):
    identity = tuple(env.get(key) for key in DISPLAY_KEYS) if env else None
    if child is not None:
        if identity != session:
            stop_child(child)
            child = None
        elif child.poll() is not None:
            child = None
    if env is not None and child is None and not running():
        print("Starting ChatGPT in the active graphical session", flush=True)
        child = launch([executable], env=env)
    return child, identity


def main():
    def terminate(_signal, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    child = None
    session = None
    try:
        while True:
            child, session = tick(child, session, desktop_environment(os.environ), sys.argv[1])
            time.sleep(5)
    finally:
        stop_child(child)


if __name__ == "__main__":
    main()
