#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: recovery-migration {resume|checkpoint} [arguments...]

Run a persisted migration recovery tool from the rescue partition. The live
NixOS image supplies Codex; Nix obtains only the small command-line runtime
needed by the checked-in tool. Invoke this script through bash because the
rescue FAT filesystem is intentionally mounted noexec.
EOF
}

[[ $# -ge 1 ]] || {
	usage >&2
	exit 2
}

command="$1"
shift
case "$command" in
	resume) script_name="resume-migration.sh" ;;
	checkpoint) script_name="checkpoint-migration.sh" ;;
	*)
		usage >&2
		exit 2
		;;
esac

script_directory="$(cd "$(dirname "$0")" && pwd)"
script_path="$script_directory/$script_name"
[[ -f "$script_path" && ! -L "$script_path" ]] || {
	printf 'Recovery tool is missing or unsafe: %s\n' "$script_path" >&2
	exit 1
}

exec /run/current-system/sw/bin/nix \
	--extra-experimental-features 'nix-command flakes' \
	shell \
	nixpkgs#coreutils \
	nixpkgs#findutils \
	nixpkgs#gawk \
	nixpkgs#gnugrep \
	nixpkgs#jq \
	nixpkgs#openssl \
	nixpkgs#python3 \
	nixpkgs#rsync \
	nixpkgs#tmux \
	nixpkgs#util-linux \
	-c /run/current-system/sw/bin/bash "$script_path" "$@"
