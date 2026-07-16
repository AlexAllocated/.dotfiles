#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
import tomllib
from collections import OrderedDict
from pathlib import Path

SECTION_RE = re.compile(r"^\s*(\[[^\n]+\])\s*(?:#.*)?$")
ASSIGNMENT_RE = re.compile(
    r'''^\s*((?:"(?:\\.|[^"\\])*")|(?:'[^']*')|(?:[A-Za-z0-9_-]+))\s*='''
)


class TomlDocument:
    def __init__(self, text: str = "") -> None:
        self.sections: OrderedDict[str | None, list[str]] = OrderedDict([(None, [])])
        current: str | None = None
        for line in text.splitlines():
            match = SECTION_RE.match(line)
            if match:
                current = match.group(1)
                if current in self.sections:
                    raise ValueError(f"Duplicate TOML section: {current}")
                self.sections[current] = []
            else:
                self.sections[current].append(line)

    def merge(self, managed: "TomlDocument") -> None:
        for section, managed_lines in managed.sections.items():
            assignments = section_assignments(managed_lines, section)
            if not assignments:
                continue
            if section not in self.sections:
                self.sections[section] = []
            merge_assignments(self.sections[section], assignments)

    def render(self) -> str:
        output: list[str] = []
        for section, lines in self.sections.items():
            if section is not None:
                while output and output[-1] == "":
                    output.pop()
                if output:
                    output.append("")
                output.append(section)
            output.extend(lines)
        return "\n".join(output).rstrip() + "\n"


def section_assignments(lines: list[str], section: str | None) -> OrderedDict[str, str]:
    assignments: OrderedDict[str, str] = OrderedDict()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ASSIGNMENT_RE.match(line)
        if not match:
            label = section or "root"
            raise ValueError(f"Managed TOML must use one-line assignments in {label}: {line}")
        assignments[match.group(1)] = line.strip()
    return assignments


def merge_assignments(target: list[str], managed: OrderedDict[str, str]) -> None:
    positions: dict[str, int] = {}
    for index, line in enumerate(target):
        match = ASSIGNMENT_RE.match(line)
        if match:
            positions[match.group(1)] = index

    missing: list[str] = []
    for key, assignment in managed.items():
        if key in positions:
            target[positions[key]] = assignment
        else:
            missing.append(assignment)
    if missing:
        while target and target[-1] == "":
            target.pop()
        target.extend(missing)


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def toml_array(values: list[str]) -> str:
    return "[" + ", ".join(toml_string(value) for value in values) + "]"


def generated_fragment(args: argparse.Namespace) -> str:
    powershell_args = ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
    lines = [
        f"sqlite_home = {toml_string(str(Path(args.linux_home) / '.codex' / 'sqlite'))}",
        "",
        "[desktop.open-in-target-preferences]",
        'global = "custom:neovide-wsl"',
        "",
        "[desktop.custom_file_handlers.neovim-wsl]",
        'label = "Neovim (WSL)"',
        f"icon = {toml_string(args.neovim_icon)}",
        f"command = {toml_string(args.powershell)}",
        f"args = {toml_array(powershell_args + [args.neovim_script])}",
        'input = "json_argument"',
        "supports_ssh = false",
        "",
        "[desktop.custom_file_handlers.neovide-wsl]",
        'label = "Neovide (WSL)"',
        f"icon = {toml_string(args.neovide_icon)}",
        f"command = {toml_string(args.powershell)}",
        f"args = {toml_array(powershell_args + [args.neovide_script])}",
        'input = "json_argument"',
        "supports_ssh = false",
    ]
    return "\n".join(lines) + "\n"


def configure(args: argparse.Namespace) -> bool:
    config_path = Path(args.config)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    existing = config_path.read_text() if config_path.is_file() else ""
    if existing:
        tomllib.loads(existing)

    document = TomlDocument(existing)
    managed_text = Path(args.desktop_config).read_text()
    tomllib.loads(managed_text)
    document.merge(TomlDocument(managed_text))
    fragment = generated_fragment(args)
    tomllib.loads(fragment)
    document.merge(TomlDocument(fragment))

    updated = document.render()
    tomllib.loads(updated)
    if updated == existing:
        print("Codex desktop configuration is current.")
        return False
    if args.dry_run:
        print(updated, end="")
        return True

    if config_path.exists():
        shutil.copy2(config_path, config_path.with_suffix(".toml.dotfiles.bak"))
    with tempfile.NamedTemporaryFile(
        mode="w", dir=config_path.parent, prefix="config.toml.", delete=False
    ) as handle:
        handle.write(updated)
        temporary = Path(handle.name)
    os.replace(temporary, config_path)
    print(f"Updated Codex desktop configuration at {config_path}.")
    return True


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        desktop = root / "desktop.toml"
        config = root / "config.toml"
        desktop.write_text('[desktop]\nintegratedTerminalShell = "wsl"\n')
        config.write_text(
            'model = "local"\n'
            "\n"
            '[plugins."linear@openai-curated"]\n'
            "enabled = true\n"
            "\n"
            "[mcp_servers.linear]\n"
            'url = "https://mcp.linear.app/mcp"\n'
        )
        args = argparse.Namespace(
            config=str(config),
            desktop_config=str(desktop),
            linux_home="/home/tester",
            neovim_script=r"C:\NvimWSL\open.ps1",
            neovim_icon=r"C:\NvimWSL\NvimWSL.exe",
            neovide_script=r"C:\NeovideWSL\open.ps1",
            neovide_icon=r"C:\Program Files\Neovide\neovide.exe",
            powershell=r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            dry_run=False,
        )
        assert configure(args)
        parsed = tomllib.loads(config.read_text())
        assert parsed["model"] == "local"
        assert parsed["plugins"]["linear@openai-curated"]["enabled"] is True
        assert parsed["mcp_servers"]["linear"]["url"] == "https://mcp.linear.app/mcp"
        assert parsed["sqlite_home"] == "/home/tester/.codex/sqlite"
        assert parsed["desktop"]["open-in-target-preferences"]["global"] == "custom:neovide-wsl"
        assert "neovim-wsl" in parsed["desktop"]["custom_file_handlers"]
        assert "neovide-wsl" in parsed["desktop"]["custom_file_handlers"]
        assert not configure(args)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reconcile required Codex desktop platform integration."
    )
    parser.add_argument("--config")
    parser.add_argument("--desktop-config")
    parser.add_argument("--linux-home")
    parser.add_argument("--neovim-script")
    parser.add_argument("--neovim-icon")
    parser.add_argument("--neovide-script")
    parser.add_argument("--neovide-icon")
    parser.add_argument("--powershell")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test:
        required = [
            "config",
            "desktop_config",
            "linux_home",
            "neovim_script",
            "neovim_icon",
            "neovide_script",
            "neovide_icon",
            "powershell",
        ]
        missing = [name for name in required if not getattr(args, name)]
        if missing:
            parser.error("missing required arguments: " + ", ".join(missing))
    return args


if __name__ == "__main__":
    parsed_args = parse_args()
    if parsed_args.self_test:
        self_test()
    else:
        configure(parsed_args)
