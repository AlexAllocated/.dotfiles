#!/usr/bin/env python3
"""Keep installed WoW clients in native-resolution borderless fullscreen."""

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from importlib.util import module_from_spec, spec_from_file_location


# Keep the game and compositor in agreement about fullscreen. Forcing a normal
# window while Niri requests fullscreen lets Wine undo the opening rule during
# startup. Use Blizzard's borderless mode at the output's native resolution.
SETTINGS = {
	"GxMaximize": "1",
	"GxFullscreenResolution": "0x0",
	"GxMonitor": "0",
	"RenderScale": "1",
}
OBSOLETE = {"gxwindowedresolution", "gxnewresolution"}
SETTING = re.compile(r'^\s*SET\s+(\S+)\s+"[^"\r\n]*"\s*$')
WOW_NAMES = ("Wow.exe", "Wow-64.exe", "WowB.exe", "WowClassic.exe", "WowClassicB.exe", "WowClassicT.exe")


def reconcile_text(text):
	newline = "\r\n" if "\r\n" in text else "\n"
	managed = {key.lower() for key in SETTINGS} | OBSOLETE
	lines = []
	for line in text.splitlines(keepends=True):
		match = SETTING.fullmatch(line.rstrip("\r\n"))
		if not match or match[1].lower() not in managed:
			lines.append(line)
	if lines and not lines[-1].endswith(("\n", "\r")):
		lines[-1] += newline
	lines.extend(f'SET {key} "{value}"{newline}' for key, value in SETTINGS.items())
	return "".join(lines)


def wow_running(prefix, proc_root=Path("/proc"), session_helper=None):
	spec = spec_from_file_location("wine_session", session_helper or Path(__file__).with_name("wine-session.py"))
	session = module_from_spec(spec)
	spec.loader.exec_module(session)
	return session.process_running(prefix, WOW_NAMES, proc_root)


def reconcile(path, check=False):
	before = path.read_bytes()
	after = reconcile_text(before.decode("utf-8-sig")).encode("utf-8")
	if after == before:
		return True
	if check:
		print(f"{path}: display settings need reconciliation")
		return False
	# Preserve each distinct pre-change version, including changes made later.
	fd, backup = tempfile.mkstemp(prefix="Config.wtf.before-borderless-", dir=path.parent)
	os.close(fd)
	shutil.copy2(path, backup)
	fd, temporary = tempfile.mkstemp(prefix=".Config.wtf.", dir=path.parent)
	try:
		with os.fdopen(fd, "wb") as output:
			output.write(after)
		os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
		os.replace(temporary, path)
	finally:
		Path(temporary).unlink(missing_ok=True)
	print(f"{path}: borderless fullscreen, automatic resolution; backup: {backup}")
	return True


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("root", type=Path, help="World of Warcraft installation directory")
	parser.add_argument("--check", action="store_true")
	parser.add_argument("--prefix", type=Path, required=True, help="Wine prefix whose live games protect these settings")
	parser.add_argument("--session-helper", type=Path, default=Path(__file__).with_name("wine-session.py"))
	args = parser.parse_args()
	if not args.check and wow_running(args.prefix, session_helper=args.session_helper):
		print("WoW is running; leaving its settings untouched until the next launcher start.")
		return 0
	results = [reconcile(path, args.check)
		for path in sorted(args.root.glob("_*/WTF/Config.wtf"))]
	return 0 if all(results) else 1


if __name__ == "__main__":
	raise SystemExit(main())
