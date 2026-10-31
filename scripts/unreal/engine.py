"""Install Epic's authenticated Linux ZIP and launch it inside the Nix FHS runtime.

The licensed payload stays writable outside the Nix store, like the existing
Fantasy Grounds bootstrap. The repo owns the installer/runtime, never Epic login.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zipfile


def install(archive: Path, base: Path, expected: str | None, registry_root=None):
    archive = archive.expanduser().resolve(strict=True)
    print(f"Checking {archive.name}...", flush=True)
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if expected and digest != expected:
        raise ValueError("Archive SHA-256 does not match the requested pin")
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        for member in members:
            path = PurePosixPath(member.filename)
            mode = member.external_attr >> 16
            if path.is_absolute() or ".." in path.parts or (mode & 0o170000) == 0o120000:
                raise ValueError(f"Unsafe archive entry: {member.filename}")
        builds = [m for m in members if m.filename.endswith("Engine/Build/Build.version")]
        if len(builds) != 1:
            raise ValueError("Expected one Engine/Build/Build.version in Epic's ZIP")
        build = json.loads(bundle.read(builds[0]))
        version = ".".join(str(build[k]) for k in ("MajorVersion", "MinorVersion", "PatchVersion"))
        if (build["MajorVersion"], build["MinorVersion"]) != (5, 8) or build.get("IsPromotedBuild") == 0:
            raise ValueError("This sandbox requires a stable Unreal 5.8.x Linux build")
        prefix = builds[0].filename.removesuffix("Engine/Build/Build.version")
        names = {m.filename for m in members}
        if prefix + "Engine/Binaries/Linux/UnrealEditor" not in names:
            raise ValueError("ZIP does not contain the native Linux editor")
        if not any(m.filename.endswith("/ModelContextProtocol.uplugin") for m in members):
            raise ValueError("ZIP does not contain Epic's ModelContextProtocol plugin")
        needed = sum(m.file_size for m in members) + 5 * 1024**3
    base.mkdir(parents=True, exist_ok=True)
    destination = base / version
    with (base / ".install.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt_path = destination / ".dotfiles-install.json"
        if destination.exists():
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
            if receipt.get("sha256") != digest:
                raise ValueError(f"Preserving existing installation at {destination}; checksum differs")
        else:
            if shutil.disk_usage(base).free < needed:
                raise ValueError(f"Need {needed / 1024**3:.1f} GiB free to extract this engine")
            staging = Path(tempfile.mkdtemp(prefix=".installing-", dir=base))
            try:
                print(f"Extracting Unreal Engine {version}...", flush=True)
                subprocess.run(["unzip", "-q", str(archive), "-d", str(staging)], check=True)
                root = staging / prefix
                editor = root / "Engine/Binaries/Linux/UnrealEditor"
                editor.chmod(editor.stat().st_mode | 0o111)
                (root / ".dotfiles-install.json").write_text(json.dumps({
                    "version": version, "sha256": digest, "archive": archive.name,
                    "source": "https://www.unrealengine.com/linux",
                }, indent=2) + "\n")
                root.rename(destination)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
        temporary_link = base / ".current-new"
        temporary_link.unlink(missing_ok=True)
        temporary_link.symlink_to(version)
        temporary_link.replace(base / "current")
    if registry_root:
        sys.path.insert(0, str(Path(registry_root) / "scripts/dotfiles"))
        from core import Context
        import storage
        context = Context(registry_root)
        storage.register(context, destination, purpose=f"Epic Unreal Engine {version} Linux installation",
                         category="archive", creator="unreal-engine", revision=digest,
                         references=[str(base / "current"), str(archive)])
        storage.update_registration(context, destination, active=True,
                                    verification="Extracted from SHA-256 verified local archive")
    print(f"Installed Unreal Engine {version}: {destination}\nSHA-256: {digest}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--registry-root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--install", type=Path, metavar="EPIC_LINUX_ZIP")
    parser.add_argument("--sha256", help="Require this archive SHA-256 when installing")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--commandlet", action="store_true", help="Launch UnrealEditor-Cmd")
    args, editor_args = parser.parse_known_args()
    base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "unreal-engine"
    if args.install:
        install(args.install, base, args.sha256, args.registry_root)
        return
    root = base / "current"
    receipt = root / ".dotfiles-install.json"
    if args.status:
        print(receipt.read_text() if receipt.exists() else "Unreal Engine payload is not installed.")
        return
    if not receipt.exists():
        parser.error("Download Epic's Linux 5.8.x ZIP to ~/Downloads, then run unreal-engine --install /path/to/ZIP")
    executable = root / "Engine/Binaries/Linux" / ("UnrealEditor-Cmd" if args.commandlet else "UnrealEditor")
    # Resolve the engine path before entering the FHS namespace. Keep all child
    # programs (shader workers, Python, build tools) inside the same environment.
    environment = os.environ.copy()
    environment["SDL_VIDEODRIVER"] = "x11"
    os.execvpe(args.runtime, [args.runtime, "-c", 'exec "$@"', "unreal-engine", str(executable.resolve()), *editor_args], environment)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
