#!/usr/bin/env bash
set -euo pipefail

schema_version=1
capsule_path=""
workspace_override=""
import_only=0
fresh_import=0
status_only=0
mounted_paths=()
discovered_capsule=""

usage() {
	cat <<'EOF'
Usage: resume-migration [--capsule PATH] [--workspace PATH] [--import-only]
                        [--fresh-import] [--status]

Safely import a version 1 NixOS migration capsule and resume its recorded
Codex thread. PATH may point to NixOS-Handoff or NixOS-Handoff/v1.

By default, an already active private import is reused and the newest valid
persistent checkpoint is applied after a new import. --fresh-import ignores
the active import but still applies a newer persistent checkpoint.

Interactive resumes run in the tmux session named migration on the private
tmux socket also named migration. If that session already exists,
resume-migration attaches to it instead of starting a second Codex writer.

The capsule must contain v1/manifest.json with schemaVersion, threadId,
workspace, and an allowlisted files array of { path, sha256 } records.
EOF
}

while (($#)); do
	case "$1" in
		--capsule)
			[[ $# -ge 2 ]] || {
				printf '%s\n' '--capsule requires a path' >&2
				exit 2
			}
			capsule_path="$2"
			shift 2
			;;
		--workspace)
			[[ $# -ge 2 ]] || {
				printf '%s\n' '--workspace requires a path' >&2
				exit 2
			}
			workspace_override="$2"
			shift 2
			;;
		--import-only)
			import_only=1
			shift
			;;
		--fresh-import)
			fresh_import=1
			shift
			;;
		--status)
			status_only=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

cleanup_mounts() {
	local mount_path
	((${#mounted_paths[@]})) || return 0
	for mount_path in "${mounted_paths[@]}"; do
		sudo umount "$mount_path" >/dev/null 2>&1 || true
		sudo rmdir "$mount_path" >/dev/null 2>&1 || true
	done
}
trap cleanup_mounts EXIT

normalise_capsule_path() {
	local candidate="$1"
	if [[ -f "$candidate/manifest.json" ]]; then
		printf '%s\n' "$candidate"
	elif [[ -f "$candidate/v${schema_version}/manifest.json" ]]; then
		printf '%s\n' "$candidate/v${schema_version}"
	else
		return 1
	fi
}

discover_mounted_capsule() {
	local candidate resolved root
	for root in \
		"/mnt" \
		"/media" \
		"/run/media/${USER:-nixos}" \
		"/run/chev-migration"; do
		[[ -d "$root" ]] || continue
		while IFS= read -r -d '' candidate; do
			resolved="$(normalise_capsule_path "$candidate" || true)"
			if [[ -n "$resolved" ]]; then
				discovered_capsule="$resolved"
				return 0
			fi
		done < <(find "$root" -maxdepth 4 -type d -name NixOS-Handoff -print0 2>/dev/null)
	done
	return 1
}

discover_ntfs_capsule() {
	local device fstype mount_name mount_path candidate resolved
	while read -r device fstype; do
		case "${fstype,,}" in
			ntfs | ntfs3) ;;
			*) continue ;;
		esac
		[[ -b "$device" ]] || continue
		if findmnt --noheadings --output TARGET --source "$device" >/dev/null 2>&1; then
			continue
		fi
		mount_name="$(basename "$device" | tr -c '[:alnum:]_.-' '_')"
		mount_path="/run/chev-migration/$mount_name"
		sudo install -d -m 0700 "$mount_path"
		if ! sudo mount -o ro,nosuid,nodev,noexec "$device" "$mount_path" 2>/dev/null; then
			sudo rmdir "$mount_path" >/dev/null 2>&1 || true
			continue
		fi
		mounted_paths+=("$mount_path")
		candidate="$mount_path/NixOS-Handoff"
		resolved="$(normalise_capsule_path "$candidate" || true)"
		if [[ -n "$resolved" ]]; then
			discovered_capsule="$resolved"
			return 0
		fi
	done < <(lsblk --paths --noheadings --raw --output NAME,FSTYPE)
	return 1
}

if [[ -n "$capsule_path" ]]; then
	capsule_path="$(normalise_capsule_path "$capsule_path")" || {
		printf 'No version %s capsule manifest found below %s\n' "$schema_version" "$capsule_path" >&2
		exit 1
	}
else
	if discover_mounted_capsule; then
		capsule_path="$discovered_capsule"
	elif discover_ntfs_capsule; then
		capsule_path="$discovered_capsule"
	fi
	[[ -n "$capsule_path" ]] || {
		printf '%s\n' 'No NixOS-Handoff capsule found. Mount Windows or pass --capsule PATH.' >&2
		exit 1
	}
fi

manifest="$capsule_path/manifest.json"
[[ -f "$manifest" && ! -L "$manifest" ]] || {
	printf 'Manifest is missing or is a symlink: %s\n' "$manifest" >&2
	exit 1
}

if find "$capsule_path" -type l -print -quit | grep -q .; then
	printf '%s\n' 'Capsule contains a symlink; refusing import.' >&2
	exit 1
fi
if find "$capsule_path" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
	printf '%s\n' 'Capsule contains an unexpected file type; refusing import.' >&2
	exit 1
fi

jq -e --argjson schema "$schema_version" '
	.schemaVersion == $schema
	and (.threadId | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
	and (.workspace | type == "string" and startswith("/") and (contains("\u0000") | not))
	and (.files | type == "array" and length > 0 and length <= 128)
	and ([.files[].path] | length == (unique | length))
	and (all(.files[];
		(.path | type == "string" and length > 0)
		and (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$"))))
' "$manifest" >/dev/null || {
	printf '%s\n' 'Capsule manifest failed schema validation.' >&2
	exit 1
}

allowlisted_path() {
	case "$1" in
		handoff.md | machine-manifest.json | codex/auth.json | codex/config.toml | codex/history.jsonl | \
			codex/sqlite/state_*.sqlite | codex/archived_sessions/rollout-*.jsonl | \
			dotfiles/repository.bundle | \
			sunshine/sunshine_state.json | sunshine/credentials/cacert.pem | sunshine/credentials/cakey.pem)
			return 0
			;;
		codex/sessions/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]/rollout-*.jsonl)
			return 0
			;;
		*) return 1 ;;
	esac
}

checkpoint_candidate_created_at() {
	python3 - "$1" "$thread_id" "$base_manifest_hash" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
thread_id = sys.argv[2]
base_hash = sys.argv[3]

if not manifest_path.is_file() or manifest_path.is_symlink():
	raise SystemExit(1)
root = manifest_path.parent
if root.parent.name != "NixOS-Checkpoints":
	raise SystemExit(1)

try:
	manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
	raise SystemExit(1)

created_at = manifest.get("createdAt")
if not isinstance(created_at, str) or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", created_at):
	raise SystemExit(1)
if root.name != f"checkpoint-{created_at}":
	raise SystemExit(1)
if not (
	manifest.get("schemaVersion") == 1
	and manifest.get("kind") == "chev-migration-checkpoint"
	and manifest.get("threadId") == thread_id
	and manifest.get("baseManifestSha256") == base_hash
):
	raise SystemExit(1)

records = manifest.get("files")
if not isinstance(records, list) or not 1 <= len(records) <= 16:
	raise SystemExit(1)

allowed_fixed = {
	"codex/auth.json",
	"codex/config.toml",
	"codex/history.jsonl",
}
sqlite_pattern = re.compile(r"codex/sqlite/state_[0-9]+[.]sqlite")
rollout_pattern = re.compile(
	r"codex/(?:sessions/[0-9]{4}/[0-9]{2}/[0-9]{2}|archived_sessions)/rollout-[^/]+[.]jsonl"
)
declared = {}
total_size = 0
for record in records:
	if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
		raise SystemExit(1)
	relative = record["path"]
	expected = record["sha256"]
	if not isinstance(relative, str) or not isinstance(expected, str):
		raise SystemExit(1)
	path = pathlib.PurePosixPath(relative)
	if path.is_absolute() or ".." in path.parts or relative in declared:
		raise SystemExit(1)
	if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
		raise SystemExit(1)
	if relative not in allowed_fixed and not sqlite_pattern.fullmatch(relative) and not rollout_pattern.fullmatch(relative):
		raise SystemExit(1)
	source = root / path
	if not source.is_file() or source.is_symlink():
		raise SystemExit(1)
	size = source.stat().st_size
	if size > 2 * 1024**3:
		raise SystemExit(1)
	total_size += size
	if total_size > 4 * 1024**3:
		raise SystemExit(1)
	if hashlib.sha256(source.read_bytes()).hexdigest().lower() != expected.lower():
		raise SystemExit(1)
	declared[relative] = expected

if "codex/auth.json" not in declared or "codex/config.toml" not in declared:
	raise SystemExit(1)
if sum(bool(sqlite_pattern.fullmatch(path)) for path in declared) != 1:
	raise SystemExit(1)
if sum(bool(rollout_pattern.fullmatch(path)) for path in declared) != 1:
	raise SystemExit(1)

actual = set()
for path in root.rglob("*"):
	if path.is_symlink() or not (path.is_file() or path.is_dir()):
		raise SystemExit(1)
	if path.is_file():
		actual.add(path.relative_to(root).as_posix())
if actual != set(declared) | {"checkpoint-manifest.json"}:
	raise SystemExit(1)

print(created_at)
PY
}

declare -A manifest_paths=()
total_size=0
while IFS=$'\t' read -r relative_path expected_hash; do
	[[ "$relative_path" != /* && "$relative_path" != *..* && "$relative_path" != *$'\n'* ]] || {
		printf 'Unsafe capsule path: %s\n' "$relative_path" >&2
		exit 1
	}
	allowlisted_path "$relative_path" || {
		printf 'Capsule path is not allowlisted: %s\n' "$relative_path" >&2
		exit 1
	}
	source_file="$capsule_path/$relative_path"
	[[ -f "$source_file" && ! -L "$source_file" ]] || {
		printf 'Capsule file is missing or invalid: %s\n' "$relative_path" >&2
		exit 1
	}
	actual_hash="$(sha256sum "$source_file" | awk '{print $1}')"
	[[ "${actual_hash,,}" == "${expected_hash,,}" ]] || {
		printf 'Hash mismatch for %s\n' "$relative_path" >&2
		exit 1
	}
	file_size="$(stat --format '%s' "$source_file")"
	((file_size <= 2147483648)) || {
		printf 'Capsule file exceeds the 2 GiB limit: %s\n' "$relative_path" >&2
		exit 1
	}
	total_size=$((total_size + file_size))
	((total_size <= 4294967296)) || {
		printf '%s\n' 'Capsule exceeds the 4 GiB import limit.' >&2
		exit 1
	}
	manifest_paths["$relative_path"]=1
done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "$manifest")

for required_path in \
	handoff.md \
	machine-manifest.json \
	codex/auth.json \
	codex/config.toml \
	dotfiles/repository.bundle \
	sunshine/sunshine_state.json \
	sunshine/credentials/cacert.pem \
	sunshine/credentials/cakey.pem; do
	[[ -n "${manifest_paths[$required_path]:-}" ]] || {
		printf 'Capsule is missing required payload: %s\n' "$required_path" >&2
		exit 1
	}
done

sqlite_count="$(printf '%s\n' "${!manifest_paths[@]}" | grep -Ec '^codex/sqlite/state_[0-9]+\.sqlite$' || true)"
session_count="$(printf '%s\n' "${!manifest_paths[@]}" | grep -Ec '^codex/(sessions/[0-9]{4}/[0-9]{2}/[0-9]{2}|archived_sessions)/rollout-.*\.jsonl$' || true)"
((sqlite_count == 1 && session_count >= 1)) || {
	printf '%s\n' 'Capsule must contain exactly one normalized Codex state database and at least one rollout.' >&2
	exit 1
}

if grep -Eiq '^[[:space:]]*sqlite_home[[:space:]]*=' "$capsule_path/codex/config.toml"; then
	printf '%s\n' 'Capsule config.toml still sets sqlite_home; recreate it with the Windows exporter.' >&2
	exit 1
fi

jq -e '
	.root.uniqueid | type == "string" and length > 0
' "$capsule_path/sunshine/sunshine_state.json" >/dev/null
jq -e '.root.named_devices | type == "array"' "$capsule_path/sunshine/sunshine_state.json" >/dev/null
openssl x509 -in "$capsule_path/sunshine/credentials/cacert.pem" -noout >/dev/null
openssl pkey -in "$capsule_path/sunshine/credentials/cakey.pem" -check -noout >/dev/null
certificate_public_key="$(openssl x509 -in "$capsule_path/sunshine/credentials/cacert.pem" -pubkey -noout | sha256sum | awk '{print $1}')"
private_public_key="$(openssl pkey -in "$capsule_path/sunshine/credentials/cakey.pem" -pubout | sha256sum | awk '{print $1}')"
[[ "$certificate_public_key" == "$private_public_key" ]] || {
	printf '%s\n' 'Sunshine certificate and private key do not match.' >&2
	exit 1
}

while IFS= read -r -d '' source_file; do
	relative_path="${source_file#"$capsule_path"/}"
	[[ "$relative_path" == "manifest.json" || -n "${manifest_paths[$relative_path]:-}" ]] || {
		printf 'Unmanifested file in capsule: %s\n' "$relative_path" >&2
		exit 1
	}
done < <(find "$capsule_path" -type f -print0)

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/chev-migration"
umask 077
mkdir -p "$state_root/imports"
chmod 0700 "$state_root" "$state_root/imports"
thread_id="$(jq -r '.threadId' "$manifest")"
recorded_workspace="$(jq -r '.workspace' "$manifest")"
base_manifest_hash="$(sha256sum "$manifest" | awk '{print $1}')"
active_import_file="$state_root/active-import"
reuse_active=0
tmux_session="migration"
tmux_socket="migration"
tmux_command=(tmux -L "$tmux_socket")
lock_root="$state_root/locks"
mkdir -p "$lock_root"
chmod 0700 "$lock_root"
setup_lock="$lock_root/$thread_id.setup.lock"
exec 8>"$setup_lock"
flock --exclusive 8

if ((fresh_import)) && command -v tmux >/dev/null 2>&1 && "${tmux_command[@]}" has-session -t "=$tmux_session" 2>/dev/null; then
	printf 'Refusing --fresh-import while tmux session %s is active. Attach to it or end it explicitly first.\n' "$tmux_session" >&2
	exit 1
fi

if ((!import_only && !fresh_import && !status_only)) && [[ "${TMUX:-}" != *"/$tmux_socket,"* ]] && command -v tmux >/dev/null 2>&1 && "${tmux_command[@]}" has-session -t "=$tmux_session" 2>/dev/null; then
	live_thread_record="$("${tmux_command[@]}" show-environment -t "=$tmux_session" MIGRATION_THREAD_ID 2>/dev/null || true)"
	live_import_record="$("${tmux_command[@]}" show-environment -t "=$tmux_session" MIGRATION_IMPORT_ROOT 2>/dev/null || true)"
	live_thread="${live_thread_record#*=}"
	live_import="${live_import_record#*=}"
	if [[ "$live_thread" != "$thread_id" || -z "$live_import" ]]; then
		printf 'Existing tmux session %s lacks matching migration identity; refusing a second writer.\n' "$tmux_session" >&2
		exit 1
	fi
	live_import="$(realpath -e -- "$live_import" 2>/dev/null || true)"
	case "$live_import" in
		"$state_root"/imports/v"$schema_version".*) ;;
		*) live_import="" ;;
	esac
	if [[ -z "$live_import" || -L "$live_import" || ! -f "$live_import/manifest.json" || -L "$live_import/manifest.json" ]]; then
		printf 'Existing tmux session %s points to an unsafe migration import.\n' "$tmux_session" >&2
		exit 1
	fi
	live_manifest_hash="$(sha256sum "$live_import/manifest.json" | awk '{print $1}')"
	if [[ "$live_manifest_hash" != "$base_manifest_hash" ]]; then
		printf 'Existing tmux session %s does not match the verified baseline capsule.\n' "$tmux_session" >&2
		exit 1
	fi
	active_import_temporary="$state_root/.active-import.$$"
	printf '%s\n' "$live_import" >"$active_import_temporary"
	chmod 0600 "$active_import_temporary"
	mv "$active_import_temporary" "$active_import_file"
	printf 'Attaching to authoritative tmux session: %s\n' "$tmux_session"
	cleanup_mounts
	trap - EXIT
	flock --unlock 8
	exec 8>&-
	exec env -u TMUX "${tmux_command[@]}" attach-session -t "=$tmux_session"
fi

if ((!fresh_import)) && [[ -f "$active_import_file" && ! -L "$active_import_file" ]]; then
	active_import_owner="$(stat --format='%u' "$active_import_file")"
	active_import_mode="$(stat --format='%a' "$active_import_file")"
	[[ "$active_import_owner" == "$(id -u)" && "$active_import_mode" == "600" ]] || {
		printf 'Active-import pointer has unsafe ownership or mode: %s\n' "$active_import_file" >&2
		exit 1
	}
	candidate="$(cat "$active_import_file")"
	case "$candidate" in
		"$state_root"/imports/*) ;;
		*) candidate="" ;;
	esac
	if [[ -n "$candidate" ]]; then
		candidate="$(realpath -e -- "$candidate" 2>/dev/null || true)"
	fi
	case "$candidate" in
		"$state_root"/imports/v"$schema_version".*) ;;
		*) candidate="" ;;
	esac
	if [[ -n "$candidate" && ! -L "$candidate" && -d "$candidate/codex/sqlite" && -f "$candidate/manifest.json" && ! -L "$candidate/manifest.json" ]]; then
		candidate_owner="$(stat --format='%u' "$candidate")"
		candidate_mode="$(stat --format='%a' "$candidate")"
		candidate_thread="$(jq -r '.threadId // empty' "$candidate/manifest.json" 2>/dev/null || true)"
		candidate_manifest_hash="$(sha256sum "$candidate/manifest.json" | awk '{print $1}')"
		if [[ "$candidate_owner" == "$(id -u)" && "$candidate_mode" == "700" && "$candidate_thread" == "$thread_id" && "$candidate_manifest_hash" == "$base_manifest_hash" ]]; then
			import_root="$candidate"
			reuse_active=1
		fi
	fi
fi

if ((reuse_active)); then
	printf 'Reusing active private import: %s\n' "$import_root"
elif ((status_only)); then
	printf '%s\n' 'No reusable active import is recorded in this live environment.'
	printf 'Baseline capsule: %s\nThread: %s\n' "$capsule_path" "$thread_id"
	find /mnt /media "/run/media/${USER:-nixos}" /run/chev-migration \
		-maxdepth 4 -type f -name checkpoint-manifest.json -print 2>/dev/null | sort || true
	exit 1
else
	import_root="$(mktemp -d "$state_root/imports/v${schema_version}.XXXXXXXX")"
	chmod 0700 "$import_root"
	install -m 0600 "$manifest" "$import_root/manifest.json"

	while IFS=$'\t' read -r relative_path expected_hash; do
		source_file="$capsule_path/$relative_path"
		destination_file="$import_root/$relative_path"
		install -d -m 0700 "$(dirname "$destination_file")"
		install -m 0600 "$source_file" "$destination_file"
		actual_hash="$(sha256sum "$destination_file" | awk '{print $1}')"
		[[ "${actual_hash,,}" == "${expected_hash,,}" ]] || {
			printf 'Post-copy hash mismatch for %s\n' "$relative_path" >&2
			exit 1
		}
	done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "$manifest")

	checkpoint_manifest=""
	checkpoint_created_at=""
	while IFS= read -r candidate_manifest; do
		if candidate_created_at="$(checkpoint_candidate_created_at "$candidate_manifest" 2>/dev/null)"; then
			if [[ -z "$checkpoint_created_at" || "$candidate_created_at" > "$checkpoint_created_at" ]]; then
				checkpoint_manifest="$candidate_manifest"
				checkpoint_created_at="$candidate_created_at"
			elif [[ "$candidate_created_at" == "$checkpoint_created_at" ]]; then
				selected_hash="$(sha256sum "$checkpoint_manifest" | awk '{print $1}')"
				candidate_hash="$(sha256sum "$candidate_manifest" | awk '{print $1}')"
				[[ "$candidate_hash" == "$selected_hash" ]] || {
					printf 'Ambiguous checkpoints share timestamp %s with different manifests.\n' "$candidate_created_at" >&2
					exit 1
				}
			fi
		fi
	done < <(find /mnt /media "/run/media/${USER:-nixos}" /run/chev-migration \
		-maxdepth 4 -type f -name checkpoint-manifest.json -print 2>/dev/null)

	if [[ -n "$checkpoint_manifest" ]]; then
		checkpoint_root="$(dirname "$checkpoint_manifest")"
		if find "$checkpoint_root" -type l -print -quit | grep -q .; then
			printf 'Persistent checkpoint contains a symlink: %s\n' "$checkpoint_root" >&2
			exit 1
		fi
		declare -A checkpoint_paths=()
		checkpoint_total_size=0
		find "$import_root/codex/sqlite" -maxdepth 1 -type f -name 'state_*.sqlite' -delete
		find "$import_root/codex/sessions" "$import_root/codex/archived_sessions" \
			-type f -name 'rollout-*.jsonl' -delete 2>/dev/null || true
		while IFS=$'\t' read -r relative_path expected_hash; do
			[[ "$relative_path" != /* && "$relative_path" != *..* && "$relative_path" != *$'\n'* ]] || {
				printf 'Unsafe checkpoint path: %s\n' "$relative_path" >&2
				exit 1
			}
			allowlisted_path "$relative_path" || {
				printf 'Checkpoint path is not allowlisted: %s\n' "$relative_path" >&2
				exit 1
			}
			[[ "$relative_path" == codex/* ]] || {
				printf 'Checkpoint contains a non-Codex payload: %s\n' "$relative_path" >&2
				exit 1
			}
			source_file="$checkpoint_root/$relative_path"
			[[ -f "$source_file" && ! -L "$source_file" ]] || exit 1
			file_size="$(stat --format='%s' "$source_file")"
			((file_size <= 2147483648)) || {
				printf 'Checkpoint file exceeds the 2 GiB limit: %s\n' "$relative_path" >&2
				exit 1
			}
			checkpoint_total_size=$((checkpoint_total_size + file_size))
			((checkpoint_total_size <= 4294967296)) || {
				printf '%s\n' 'Checkpoint exceeds the 4 GiB import limit.' >&2
				exit 1
			}
			actual_hash="$(sha256sum "$source_file" | awk '{print $1}')"
			[[ "${actual_hash,,}" == "${expected_hash,,}" ]] || {
				printf 'Checkpoint hash mismatch for %s\n' "$relative_path" >&2
				exit 1
			}
			checkpoint_paths["$relative_path"]=1
			destination_file="$import_root/$relative_path"
			install -d -m 0700 "$(dirname "$destination_file")"
			install -m 0600 "$source_file" "$destination_file"
			actual_hash="$(sha256sum "$destination_file" | awk '{print $1}')"
			[[ "${actual_hash,,}" == "${expected_hash,,}" ]] || {
				printf 'Post-copy checkpoint hash mismatch for %s\n' "$relative_path" >&2
				exit 1
			}
		done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "$checkpoint_manifest")
		while IFS= read -r -d '' source_file; do
			relative_path="${source_file#"$checkpoint_root"/}"
			[[ "$relative_path" == checkpoint-manifest.json || -n "${checkpoint_paths[$relative_path]:-}" ]] || {
				printf 'Unmanifested file in checkpoint: %s\n' "$relative_path" >&2
				exit 1
			}
		done < <(find "$checkpoint_root" -type f -print0)
		printf 'Applied persistent checkpoint: %s\n' "$checkpoint_root"
	fi
fi

mapfile -d '' -t state_databases < <(find "$import_root/codex/sqlite" -maxdepth 1 -type f -name 'state_*.sqlite' -print0)
((${#state_databases[@]} == 1)) || {
	printf 'Expected exactly one active state database; found %s.\n' "${#state_databases[@]}" >&2
	exit 1
}
state_database="${state_databases[0]}"
matched_session="$(
	python3 - "$state_database" "$thread_id" "$import_root/codex" "$status_only" <<'PY'
import pathlib
import sqlite3
import sys

database = pathlib.Path(sys.argv[1]).resolve(strict=True)
thread_id = sys.argv[2]
codex_home = pathlib.Path(sys.argv[3]).resolve(strict=True)
status_only = bool(int(sys.argv[4]))

database_uri = f"file:{database}?mode={'ro' if status_only else 'rw'}"
connection = sqlite3.connect(database_uri, uri=True)
try:
	rows = connection.execute(
		"SELECT rollout_path FROM threads WHERE id = ?", (thread_id,)
	).fetchall()
	if len(rows) != 1:
		raise SystemExit(f"expected one state row for {thread_id}, found {len(rows)}")
	stored_path = pathlib.Path(rows[0][0])
	candidates = []
	try:
		candidates.append(stored_path.resolve(strict=True))
	except FileNotFoundError:
		pass
	parts = stored_path.parts
	for anchor in ("sessions", "archived_sessions"):
		if anchor in parts:
			index = parts.index(anchor)
			candidate = codex_home.joinpath(*parts[index:])
			try:
				candidates.append(candidate.resolve(strict=True))
			except FileNotFoundError:
				pass
			break
	rollout = next(
		(path for path in candidates if path.is_relative_to(codex_home)), None
	)
	if rollout is None or not rollout.is_file() or rollout.is_symlink():
		raise SystemExit("recorded rollout is missing or outside the active CODEX_HOME")
	with rollout.open(encoding="utf-8") as stream:
		try:
			metadata = __import__("json").loads(stream.readline())
		except (ValueError, OSError):
			raise SystemExit("recorded rollout has invalid session metadata")
	if metadata.get("type") != "session_meta" or metadata.get("payload", {}).get("id") != thread_id:
		raise SystemExit("recorded rollout session metadata does not match the requested thread ID")
	rollout_path = str(rollout)
	if not status_only and rows[0][0] != rollout_path:
		connection.execute(
			"UPDATE threads SET rollout_path = ? WHERE id = ?",
			(rollout_path, thread_id),
		)
		connection.commit()
	result = connection.execute("PRAGMA integrity_check").fetchone()
	if result != ("ok",):
		raise SystemExit(f"SQLite integrity check failed: {result!r}")
	print(rollout_path)
finally:
	connection.close()
PY
)"

if ((!status_only)); then
	active_import_temporary="$state_root/.active-import.$$"
	printf '%s\n' "$import_root" >"$active_import_temporary"
	chmod 0600 "$active_import_temporary"
	mv "$active_import_temporary" "$active_import_file"
fi

if [[ ! -d "$HOME/.dotfiles" && -d "${CHEV_DOTFILES_SOURCE:-}" ]]; then
	temporary_dotfiles="$(mktemp -d "$HOME/.dotfiles.importing.XXXXXXXX")"
	rsync -a --chmod=Du+w,Fu+w "$CHEV_DOTFILES_SOURCE/" "$temporary_dotfiles/"
	mv "$temporary_dotfiles" "$HOME/.dotfiles"
	printf 'Prepared the embedded dotfiles source at %s\n' "$HOME/.dotfiles"
fi

workspace="$workspace_override"
if [[ -z "$workspace" && -d "$recorded_workspace" ]]; then
	workspace="$recorded_workspace"
elif [[ -z "$workspace" && -d "/mnt$recorded_workspace" ]]; then
	workspace="/mnt$recorded_workspace"
elif [[ -z "$workspace" && -d "$HOME/.dotfiles" ]]; then
	workspace="$HOME/.dotfiles"
elif [[ -z "$workspace" ]]; then
	workspace="$HOME"
fi

[[ -d "$workspace" ]] || {
	printf 'Workspace does not exist: %s\n' "$workspace" >&2
	exit 1
}

printf 'Imported capsule %s into %s\n' "$capsule_path" "$import_root"
printf 'Thread: %s\nWorkspace: %s\n' "$thread_id" "$workspace"
printf 'Rollout: %s\n' "$matched_session"
if ((status_only)); then
	printf '%s\n' 'Status: active import is valid and resumable.'
	exit 0
fi
if ((import_only)); then
	exit 0
fi

[[ -d "$import_root/codex" ]] || {
	printf '%s\n' 'Capsule did not contain a codex directory.' >&2
	exit 1
}

export CODEX_HOME="$import_root/codex"
export CODEX_SQLITE_HOME="$import_root/codex/sqlite"
cleanup_mounts
trap - EXIT

writer_lock="$lock_root/$thread_id.lock"

live_writer=""
for process_path in /proc/[0-9]*; do
	process_id="${process_path##*/}"
	[[ "$process_id" != "$$" && -r "$process_path/cmdline" ]] || continue
	process_command="$(tr '\0' ' ' <"/proc/$process_id/cmdline" 2>/dev/null || true)"
	process_executable="${process_command%% *}"
	case "${process_executable##*/}" in
		codex | .codex-wrapped) ;;
		*) continue ;;
	esac
	if [[ "$process_command" == *"$thread_id"* ]]; then
		live_writer="$process_id"
		break
	fi
done

if [[ -n "$live_writer" ]]; then
	printf 'Codex writer for thread %s is already running as PID %s; refusing a second writer.\n' "$thread_id" "$live_writer" >&2
	if command -v tmux >/dev/null 2>&1 && "${tmux_command[@]}" has-session -t "=$tmux_session" 2>/dev/null; then
		printf 'Attach with: tmux -L %s attach-session -t %s\n' "$tmux_socket" "$tmux_session" >&2
	fi
	exit 1
fi

if command -v tmux >/dev/null 2>&1; then
	if [[ -z "${TMUX:-}" ]]; then
		if "${tmux_command[@]}" has-session -t "=$tmux_session" 2>/dev/null; then
			printf 'A tmux session named %s appeared during setup; refusing an unverified attach. Retry resume-migration.\n' "$tmux_session" >&2
			exit 1
		fi
		printf 'Starting durable tmux session: %s\n' "$tmux_session"
		"${tmux_command[@]}" start-server
		"${tmux_command[@]}" set-option -g mouse off
		"${tmux_command[@]}" set-option -g alternate-screen off
		"${tmux_command[@]}" set-option -g history-limit 100000
		"${tmux_command[@]}" new-session -d \
			-s "$tmux_session" \
			-c "$workspace" \
			-e "MIGRATION_THREAD_ID=$thread_id" \
			-e "MIGRATION_IMPORT_ROOT=$import_root" \
			flock --exclusive --nonblock "$writer_lock" \
			env \
			CODEX_HOME="$CODEX_HOME" \
			CODEX_SQLITE_HOME="$CODEX_SQLITE_HOME" \
			codex resume \
			--sandbox danger-full-access \
			--ask-for-approval never \
			--cd "$workspace" \
			"$thread_id"
		started_thread="$("${tmux_command[@]}" show-environment -t "=$tmux_session" MIGRATION_THREAD_ID 2>/dev/null || true)"
		started_import="$("${tmux_command[@]}" show-environment -t "=$tmux_session" MIGRATION_IMPORT_ROOT 2>/dev/null || true)"
		if [[ "$started_thread" != "MIGRATION_THREAD_ID=$thread_id" || "$started_import" != "MIGRATION_IMPORT_ROOT=$import_root" ]]; then
			printf 'New tmux session failed migration identity verification.\n' >&2
			exit 1
		fi
		flock --unlock 8
		exec 8>&-
		exec "${tmux_command[@]}" attach-session -t "=$tmux_session"
	fi
	if [[ "${TMUX:-}" == *"/$tmux_socket,"* ]]; then
		current_tmux_session="$("${tmux_command[@]}" display-message -p '#S' 2>/dev/null || true)"
		if [[ "$current_tmux_session" != "$tmux_session" ]] && "${tmux_command[@]}" has-session -t "=$tmux_session" 2>/dev/null; then
			printf 'Switching to existing tmux session: %s\n' "$tmux_session"
			"${tmux_command[@]}" switch-client -t "=$tmux_session"
			exit 0
		fi
	fi
fi

exec 9>"$writer_lock"
if ! flock --exclusive --nonblock 9; then
	printf 'Codex writer lock is already held for thread %s.\n' "$thread_id" >&2
	exit 1
fi
flock --unlock 8
exec 8>&-
exec codex resume \
	--sandbox danger-full-access \
	--ask-for-approval never \
	--cd "$workspace" \
	"$thread_id"
