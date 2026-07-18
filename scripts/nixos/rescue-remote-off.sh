#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: rescue-remote-off

Stop the temporary unauthenticated ttyd rescue terminal and remove its runtime
address file.
EOF
}

if (($#)); then
	case "$1" in
		-h | --help)
			(($# == 1)) || {
				printf '%s\n' '--help accepts no additional arguments.' >&2
				exit 2
			}
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
fi

if ((EUID != 0)); then
	exec sudo -- "$(command -v bash)" "$0" "$@"
fi

systemctl stop chev-ttyd-rescue.service >/dev/null 2>&1 || true
rm -f /run/chev-rescue/address
rmdir /run/chev-rescue >/dev/null 2>&1 || true
printf '%s\n' 'Unauthenticated remote rescue terminal disabled.'
