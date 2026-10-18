"""Import the pinned Steam Proton snapshot without changing its installation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--source", type=Path,
	                    default=Path.home() / ".local/share/Steam/steamapps/common/Proton - Experimental")
	parser.add_argument("--pin", type=Path,
	                    default=Path(__file__).resolve().parents[2] / "pins/battlenet-proton.json")
	args = parser.parse_args()
	pin = json.loads(args.pin.read_text())
	version = (args.source / "version").read_text().strip()
	if version != pin["upstreamVersion"]:
		parser.error(f"Installed runtime is {version}; the verified pin is {pin['upstreamVersion']}. "
		             "Runtime updates need compatibility testing before changing the pin.")
	if (args.source / "user_settings.py").exists():
		parser.error("Remove user_settings.py from a separate staging copy; personal settings must not enter the snapshot")
	with tempfile.TemporaryDirectory(prefix="battlenet-proton-stage-") as temporary:
		archive = Path(temporary) / pin["archive"]
		with archive.open("wb") as output:
			tar = subprocess.Popen([
				"tar", "-C", str(args.source), "--sort=name", "--mtime=@0",
				"--owner=0", "--group=0", "--numeric-owner", "--mode=u+rwX,go+rX,go-w", "-cf", "-", ".",
			], stdout=subprocess.PIPE)
			try:
				subprocess.run(["gzip", "-n", "-1"], stdin=tar.stdout, stdout=output, check=True)
			finally:
				tar.stdout.close()
				result = tar.wait()
			if result:
				raise RuntimeError("Runtime changed during staging; archive was not imported")
		if (args.source / "version").read_text().strip() != version:
			raise RuntimeError("Steam updated Proton during staging; archive was not imported")
		with archive.open("rb") as source:
			digest = hashlib.file_digest(source, "sha256").hexdigest()
		if digest != pin["sha256"]:
			raise RuntimeError(f"Snapshot does not match the verified pin ({digest}); archive was not imported")
		subprocess.run(["nix-store", "--add-fixed", "sha256", str(archive)], check=True)


if __name__ == "__main__":
	main()
