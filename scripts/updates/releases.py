#!/usr/bin/env python3
"""Resolve stable release pins in an isolated dotctl candidate."""

import argparse
import json
import os
import re
import subprocess
import tomllib
from urllib.parse import urlsplit, urlunsplit
from pathlib import Path

DESKTOP_BASE = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/"
RELEASE_REPOS = ("mangowm/mango", "noctalia-dev/noctalia-shell", "nab138/iloader")


def fetch(url):
    return subprocess.check_output(
        [
            "curl",
            "-fsSL",
            "--retry",
            "2",
            "--connect-timeout",
            "10",
            "--max-time",
            "60",
            url,
        ],
        text=True,
    )


def refs(repo, kind, pattern):
    output = subprocess.check_output(
        ["git", "ls-remote", "--refs", kind, f"https://github.com/{repo}.git", pattern],
        text=True,
        timeout=120,
    )
    return [line.split()[1].split("/", 2)[2] for line in output.splitlines()]


def version(value):
    match = re.fullmatch(r"v?(\d+(?:\.\d+)+)(?:-([0-9A-Za-z.-]+))?", value)
    if not match:
        raise ValueError(f"Unexpected release version: {value!r}")
    return tuple(map(int, match[1].split("."))), match[2] is None


def replace_ref(source, repo, ref):
    suffix = r"(nixos-\d{2}\.\d{2})" if repo == "NixOS/nixpkgs" else r'([^"\s]+)'
    pattern = r"github:" + re.escape(repo) + "/" + suffix
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError(
            f"Expected one versioned input for {repo}, found {len(matches)}"
        )
    old = matches[0]
    # A stale release feed must never silently downgrade a newer local pin.
    old_version = re.sub(r"^(nixos-|release-|nix-darwin-)", "", old)
    new_version = re.sub(r"^(nixos-|release-|nix-darwin-)", "", ref)
    if version(new_version) < version(old_version):
        raise ValueError(f"Refusing to downgrade {repo}: {old} -> {ref}")
    print(f"Release pin {repo}: {old} -> {ref}", flush=True)
    return re.sub(pattern, lambda _: f"github:{repo}/{ref}", source)


def update_flake(source):
    releases = refs("NixOS/nixpkgs", "--tags", "[0-9][0-9].[0-9][0-9]")
    stable = max((r for r in releases if re.fullmatch(r"\d{2}\.\d{2}", r)), key=version)
    for repo, prefix in (
        ("NixOS/nixpkgs", "nixos-"),
        ("nix-community/home-manager", "release-"),
        ("nix-darwin/nix-darwin", "nix-darwin-"),
    ):
        ref = prefix + stable
        if refs(repo, "--heads", ref) != [ref]:
            raise ValueError(f"Latest stable release {stable} is missing {repo}/{ref}")
        source = replace_ref(source, repo, ref)
    for repo in RELEASE_REPOS:
        release = json.loads(
            fetch(f"https://api.github.com/repos/{repo}/releases/latest")
        )
        tag = release["tag_name"]
        if release["draft"] or release["prerelease"] or not version(tag)[1]:
            raise ValueError(f"Expected a stable published release for {repo}: {tag}")
        source = replace_ref(source, repo, tag)
    return source


def desktop_packages(text, arch):
    packages = {}
    for stanza in text.strip().split("\n\n"):
        fields = dict(
            line.split(": ", 1)
            for line in stanza.splitlines()
            if ": " in line and not line.startswith(" ")
        )
        if fields.get("Package") != "chatgpt" or fields.get("Architecture") != arch:
            continue
        release = fields["Version"]
        if not version(release)[1]:
            raise ValueError(f"Unexpected desktop prerelease: {release}")
        filename = fields["Filename"]
        if filename != f"pool/main/c/chatgpt/chatgpt_{release}_{arch}.deb":
            raise ValueError(f"Unexpected desktop asset: {filename}")
        digest = fields["SHA256"]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid desktop SHA256")
        packages[release] = {"url": DESKTOP_BASE + filename, "sha256": digest}
    if not packages:
        raise ValueError(f"No ChatGPT desktop packages for {arch}")
    return packages


def update_desktop(current):
    assets = {}
    versions = set()
    for system, arch in (("x86_64-linux", "amd64"), ("aarch64-linux", "arm64")):
        packages = desktop_packages(
            fetch(DESKTOP_BASE + f"dists/stable/main/binary-{arch}/Packages"), arch
        )
        latest = max(packages, key=version)
        versions.add(latest)
        assets[system] = packages[latest]
    if len(versions) != 1:
        raise ValueError(
            "Desktop release is not yet consistent across amd64 and arm64; retry later"
        )
    latest = versions.pop()
    if version(latest) < version(current["version"]):
        raise ValueError("Refusing to downgrade ChatGPT desktop")
    print(f"ChatGPT desktop: {current['version']} -> {latest}", flush=True)
    return {"version": latest, "assets": assets}


def update_iloader_cargo(candidate):
    source = subprocess.check_output(
        [
            "nix",
            "eval",
            "--impure",
            "--raw",
            "--expr",
            '(builtins.getFlake (builtins.getEnv "DOTFILES_UPDATE_CANDIDATE")).inputs.iloader.outPath',
        ],
        text=True,
        env={
            **os.environ,
            "DOTFILES_UPDATE_CANDIDATE": "path:" + str(candidate.resolve()),
        },
    )
    lock = tomllib.loads((Path(source) / "src-tauri/Cargo.lock").read_text())
    hashes = {}
    fetched = {}
    for package in lock["package"]:
        source = package.get("source", "")
        if not source.startswith("git+"):
            continue
        parsed = urlsplit(source[4:])
        if parsed.scheme != "https" or not re.fullmatch(
            r"[0-9a-f]{40}", parsed.fragment
        ):
            raise ValueError(f"Expected a locked HTTPS Git dependency: {source}")
        url = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
        target = f"git+{url}?rev={parsed.fragment}&allRefs=1&submodules=1"
        if target not in fetched:
            metadata = json.loads(
                subprocess.check_output(
                    ["nix", "flake", "prefetch", target, "--json"],
                    text=True,
                )
            )
            fetched[target] = metadata["hash"]
        hashes[f"{package['name']}-{package['version']}"] = fetched[target]
    output = candidate / "pins/iloader-cargo.json"
    output.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
    print(f"Refreshed {len(hashes)} iloader Git dependency checksums", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--skip-flake", action="store_true")
    parser.add_argument("--iloader-cargo", action="store_true")
    args = parser.parse_args()
    if args.iloader_cargo:
        update_iloader_cargo(args.candidate)
        return
    flake = args.candidate / "flake.nix"
    desktop = args.candidate / "pins/chatgpt-desktop.json"
    # Resolve everything before writing either candidate file.
    source = flake.read_text()
    if not args.skip_flake:
        source = update_flake(source)
    pin = update_desktop(json.loads(desktop.read_text()))
    flake.write_text(source)
    desktop.write_text(json.dumps(pin, indent=2) + "\n")


if __name__ == "__main__":
    main()
