#!/usr/bin/env bash
set -euo pipefail

source_import=""
destination_root="/mnt/nixos-iso/NixOS-Checkpoints"
minimum_free_bytes=$((128 * 1024 * 1024))

usage() {
	cat <<'EOF'
Usage: checkpoint-migration [--source-import PATH] [--destination-root PATH]

Publish a compact, hash-verified checkpoint of the active migration Codex
thread. The immutable NixOS-Handoff capsule is never modified. Each checkpoint
is staged beside its final directory and then published with one rename.

When --source-import is omitted, the current live active-import pointer is
used. Publication retains at least 128 MiB of free space.
EOF
}

while (($#)); do
	case "$1" in
		--source-import)
			[[ $# -ge 2 ]] || {
				printf '%s\n' '--source-import requires a path.' >&2
				exit 2
			}
			source_import="$2"
			shift 2
			;;
		--destination-root)
			[[ $# -ge 2 ]] || {
				printf '%s\n' '--destination-root requires a path.' >&2
				exit 2
			}
			destination_root="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

checkpoint_home="$HOME"
if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
	checkpoint_home="$(awk -F: -v user="$SUDO_USER" '$1 == user { print $6; exit }' /etc/passwd)"
fi

if [[ -z "$source_import" ]]; then
	state_root="${XDG_STATE_HOME:-$checkpoint_home/.local/state}/chev-migration"
	active_import_file="$state_root/active-import"
	[[ -f "$active_import_file" && ! -L "$active_import_file" ]] || {
		printf '%s\n' 'No safe active-import pointer exists; pass --source-import explicitly.' >&2
		exit 2
	}
	source_import="$(cat "$active_import_file")"
fi

source_import="$(realpath -e -- "$source_import" 2>/dev/null || true)"
[[ -n "$source_import" && ! -L "$source_import" && -f "$source_import/manifest.json" && ! -L "$source_import/manifest.json" ]] || {
	printf '%s\n' '--source-import must name a verified migration import.' >&2
	exit 2
}
[[ -d "$source_import/codex" && -d "$source_import/codex/sqlite" ]] || {
	printf '%s\n' 'The source import does not contain a Codex store.' >&2
	exit 1
}

if ((EUID != 0)) && { [[ ! -d "$destination_root" ]] || [[ ! -w "$destination_root" ]]; }; then
	bash_path="$(command -v bash)"
	exec sudo env \
		"PATH=$PATH" \
		"CHEV_DOTFILES_SOURCE=${CHEV_DOTFILES_SOURCE:-}" \
		"$bash_path" "$0" \
		--source-import "$source_import" \
		--destination-root "$destination_root"
fi

thread_id="$(jq -r '.threadId' "$source_import/manifest.json")"
workspace="$(jq -r '.workspace' "$source_import/manifest.json")"
base_manifest_hash="$(sha256sum "$source_import/manifest.json" | awk '{print $1}')"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_path="$destination_root/checkpoint-$timestamp"
staging_path="$destination_root/.checkpoint-$timestamp.staging.$$"

umask 077
mkdir -p "$destination_root"
exec 9>"$destination_root/.checkpoint.lock"
flock --exclusive --nonblock 9 || {
	printf '%s\n' 'Another checkpoint publisher is already active.' >&2
	exit 1
}
[[ ! -e "$final_path" && ! -e "$staging_path" ]] || {
	printf '%s\n' 'Checkpoint destination already exists; retry in one second.' >&2
	exit 1
}
mkdir "$staging_path"
cleanup() {
	if [[ -d "$staging_path" ]]; then
		find "$staging_path" -depth -type f -delete 2>/dev/null || true
		find "$staging_path" -depth -type d -empty -delete 2>/dev/null || true
	fi
}
trap cleanup EXIT

exporter_path=""
for candidate in \
	"${CHEV_DOTFILES_SOURCE:-}/scripts/nixos/export-codex-handoff.py" \
	"$checkpoint_home/.dotfiles/scripts/nixos/export-codex-handoff.py" \
	"$(cd "$(dirname "$0")" && pwd)/export-codex-handoff.py" \
	"$(cd "$(dirname "$0")/../.." && pwd)/scripts/nixos/export-codex-handoff.py"; do
	if [[ -f "$candidate" && ! -L "$candidate" ]]; then
		exporter_path="$candidate"
		break
	fi
done
[[ -n "$exporter_path" ]] || {
	printf '%s\n' 'Cannot locate export-codex-handoff.py next to the recovery tools or dotfiles source.' >&2
	exit 1
}

python3 "$exporter_path" \
	--thread-id "$thread_id" \
	--codex-home "$source_import/codex" \
	--sqlite-home "$source_import/codex/sqlite" \
	--destination "$staging_path" \
	--allow-live-thread "$thread_id"

available_bytes="$(df --block-size=1 --output=avail "$destination_root" | awk 'NR == 2 { print $1 }')"
if [[ -z "$available_bytes" || "$available_bytes" -lt "$minimum_free_bytes" ]]; then
	printf 'Refusing checkpoint publication: only %s bytes would remain; at least %s are required.\n' \
		"${available_bytes:-unknown}" "$minimum_free_bytes" >&2
	exit 1
fi

python3 - "$staging_path" "$thread_id" "$workspace" "$base_manifest_hash" "$timestamp" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
records = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    relative = path.relative_to(root).as_posix()
    records.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
manifest = {
    "schemaVersion": 1,
    "kind": "chev-migration-checkpoint",
    "threadId": sys.argv[2].lower(),
    "workspace": sys.argv[3],
    "baseManifestSha256": sys.argv[4],
    "createdAt": sys.argv[5],
    "files": records,
}
(root / "checkpoint-manifest.json").write_text(
    json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
)
PY

sync -f "$staging_path/checkpoint-manifest.json"
mv -T "$staging_path" "$final_path"
sync -f "$final_path/checkpoint-manifest.json"
trap - EXIT

python3 - "$final_path" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = root / "checkpoint-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
declared = {record["path"]: record["sha256"] for record in manifest["files"]}
actual = {
    path.relative_to(root).as_posix()
    for path in root.rglob("*")
    if path.is_file() and path != manifest_path
}
if actual != set(declared):
    raise SystemExit("published checkpoint file set does not match its manifest")
for relative, expected in declared.items():
    path = root / relative
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"published checkpoint hash mismatch: {relative}")
print("Verified every published checkpoint hash.")
PY

printf 'Published migration checkpoint: %s\n' "$final_path"
printf 'Thread: %s\nBase manifest: %s\n' "$thread_id" "$base_manifest_hash"
