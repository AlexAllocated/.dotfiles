#!/usr/bin/env bash
set -euo pipefail

schema_version=1
capsule_path=""
workspace_override=""
import_only=0
mounted_paths=()
discovered_capsule=""

usage() {
	cat <<'EOF'
Usage: resume-migration [--capsule PATH] [--workspace PATH] [--import-only]

Safely import a version 1 NixOS migration capsule and resume its recorded
Codex thread. PATH may point to NixOS-Handoff or NixOS-Handoff/v1.

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

thread_id="$(jq -r '.threadId' "$manifest")"
recorded_workspace="$(jq -r '.workspace' "$manifest")"

session_match=0
matched_session=""
while IFS= read -r -d '' session_file; do
	if grep -F -q -- "$thread_id" "$session_file"; then
		session_match=$((session_match + 1))
		matched_session="$session_file"
	fi
done < <(find "$import_root/codex" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
((session_match == 1)) || {
	printf 'Expected exactly one imported rollout for thread %s; found %s.\n' "$thread_id" "$session_match" >&2
	exit 1
}

state_database="$(find "$import_root/codex/sqlite" -maxdepth 1 -type f -name 'state_*.sqlite' -print -quit)"
python3 - "$state_database" "$thread_id" "$matched_session" <<'PY'
import pathlib
import sqlite3
import sys

database = pathlib.Path(sys.argv[1]).resolve(strict=True)
thread_id = sys.argv[2]
rollout_path = str(pathlib.Path(sys.argv[3]).resolve(strict=True))

connection = sqlite3.connect(database)
try:
	rows = connection.execute("SELECT id FROM threads WHERE id = ?", (thread_id,)).fetchall()
	if len(rows) != 1:
		raise SystemExit(f"expected one state row for {thread_id}, found {len(rows)}")
	connection.execute(
		"UPDATE threads SET rollout_path = ? WHERE id = ?",
		(rollout_path, thread_id),
	)
	connection.commit()
	result = connection.execute("PRAGMA integrity_check").fetchone()
	if result != ("ok",):
		raise SystemExit(f"SQLite integrity check failed: {result!r}")
	stored = connection.execute(
		"SELECT rollout_path FROM threads WHERE id = ?", (thread_id,)
	).fetchone()
	if stored != (rollout_path,):
		raise SystemExit("failed to normalize imported rollout_path")
finally:
	connection.close()
PY

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
exec codex resume \
	--sandbox danger-full-access \
	--ask-for-approval never \
	--cd "$workspace" \
	"$thread_id" \
	"The verified NixOS migration capsule has been imported. Continue the recorded migration from its handoff state."
