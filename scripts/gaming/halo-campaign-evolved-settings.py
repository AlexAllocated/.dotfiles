#!/usr/bin/env python3
"""Reconcile the performance-sensitive Halo: Campaign Evolved settings."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path


SECTION = "HaloUserSettings"
SETTINGS = OrderedDict(
	[
		("bAsyncCompute", "True"),
		("Upscaler", "DLSS"),
		("UpscalingQuality", "Ultra"),
		("bFrameGeneration", "False"),
		("LowLatencyMode", "VendorSpecific"),
		("ResolutionScale", "1.000000"),
		("MinimumFrameRate", "-1"),
		("bVSync", "False"),
		("MaximumFrameRate", "80"),
		("QualityPreset", "Custom"),
		("TextureQuality", "High"),
		("GeometryQuality", "High"),
		("ReflectionsQuality", "Medium"),
		("GlobalIlluminationQuality", "Low"),
		("LightingQuality", "Low"),
		("EffectsQuality", "Medium"),
		("AtmosphericsQuality", "Medium"),
		("PostprocessingQuality", "Medium"),
	]
)

SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:\r?\n)?$")
SETTING_RE = re.compile(r"^([^=;\s][^=]*)=(.*?)(\r?\n)?$")


def reconcile(path: Path, check: bool) -> int:
	with path.open("r", encoding="utf-8-sig", newline="") as handle:
		lines = handle.readlines()

	current_section: str | None = None
	found: dict[str, str] = {}
	changed = False
	output: list[str] = []

	for line in lines:
		section_match = SECTION_RE.match(line)
		if section_match:
			current_section = section_match.group(1)
			output.append(line)
			continue

		setting_match = SETTING_RE.match(line) if current_section == SECTION else None
		if setting_match is None:
			output.append(line)
			continue

		key = setting_match.group(1).strip()
		if key not in SETTINGS:
			output.append(line)
			continue
		if key in found:
			raise ValueError(f"{path}: duplicate {key} in [{SECTION}]")

		value = setting_match.group(2).strip()
		found[key] = value
		expected = SETTINGS[key]
		line_ending = setting_match.group(3) or ""
		replacement = f"{key}={expected}{line_ending}"
		output.append(replacement)
		changed |= replacement != line

	missing = [key for key in SETTINGS if key not in found]
	if missing:
		raise ValueError(f"{path}: missing expected settings: {', '.join(missing)}")

	mismatches = [
		f"{key}: {found[key]} -> {expected}"
		for key, expected in SETTINGS.items()
		if found[key] != expected
	]
	if check:
		if mismatches:
			print("\n".join(mismatches))
			return 1
		print(f"{path}: optimized settings are active")
		return 0

	if not changed:
		print(f"{path}: already optimized")
		return 0

	backup = path.with_name(f"{path.name}.pre-dotfiles")
	if not backup.exists():
		shutil.copy2(path, backup)
		print(f"{path}: preserved original settings at {backup}")

	mode = stat.S_IMODE(path.stat().st_mode)
	fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
	temporary = Path(temporary_name)
	try:
		with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
			handle.writelines(output)
		os.chmod(temporary, mode)
		os.replace(temporary, path)
	except BaseException:
		temporary.unlink(missing_ok=True)
		raise

	print(f"{path}: applied optimized settings")
	return 0


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument(
		"--check",
		action="store_true",
		help="report drift without changing the settings file",
	)
	parser.add_argument("config", type=Path)
	return parser.parse_args()


def main() -> int:
	args = parse_args()
	try:
		return reconcile(args.config, args.check)
	except (OSError, ValueError) as error:
		print(error, file=sys.stderr)
		return 1


if __name__ == "__main__":
	raise SystemExit(main())
