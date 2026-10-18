"""Reconcile Battle.net's browser renderer without changing game rendering."""

import argparse
import json
import os
from pathlib import Path
import stat
import tempfile

from importlib.util import module_from_spec, spec_from_file_location


def reconcile(path):
	before = path.read_bytes() if path.exists() else None
	settings = json.loads(before) if before is not None else {}
	if not isinstance(settings, dict) or not isinstance(settings.get("Client", {}), dict):
		raise ValueError("Battle.net settings are not a JSON object; leaving them untouched")
	client = settings.setdefault("Client", {})
	if client.get("HardwareAcceleration") == "false":
		return False
	client["HardwareAcceleration"] = "false"
	after = (json.dumps(settings, indent=4, ensure_ascii=False) + "\n").encode("utf-8")
	path.parent.mkdir(parents=True, exist_ok=True)
	if before is not None:
		fd, backup = tempfile.mkstemp(prefix="Battle.net.config.before-browser-renderer-", dir=path.parent)
		with os.fdopen(fd, "wb") as output:
			output.write(before)
	fd, temporary = tempfile.mkstemp(prefix=".Battle.net.config.", dir=path.parent)
	try:
		with os.fdopen(fd, "wb") as output:
			output.write(after)
		# These settings can include account data. Never create a readable copy.
		mode = stat.S_IMODE(path.stat().st_mode) & 0o600 if before is not None else 0o600
		os.chmod(temporary, mode)
		os.replace(temporary, path)
	finally:
		Path(temporary).unlink(missing_ok=True)
	return True


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--prefix", type=Path, required=True)
	parser.add_argument("--session-helper", type=Path, default=Path(__file__).with_name("wine-session.py"))
	args = parser.parse_args()
	spec = spec_from_file_location("wine_session", args.session_helper)
	session = module_from_spec(spec)
	spec.loader.exec_module(session)
	if session.process_running(args.prefix, "Battle.net.exe"):
		print("Battle.net is running; browser settings will be reconciled on a cold launch.")
		return
	path = args.prefix / "drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"
	if reconcile(path):
		print("Battle.net browser hardware acceleration disabled; game settings retained.")


if __name__ == "__main__":
	main()
