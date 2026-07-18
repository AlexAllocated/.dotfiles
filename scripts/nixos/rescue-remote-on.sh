#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: rescue-remote-on

Temporarily expose the unauthenticated ttyd rescue terminal on one private-LAN
IPv4 address. Disable it with rescue-remote-off immediately after use.
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

runtime_dir=/run/chev-rescue
address_file="$runtime_dir/address"
address=""

while read -r candidate; do
	case "$candidate" in
		10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*)
			address="$candidate"
			break
			;;
	esac
done < <(ip -4 -o address show scope global | awk '{ sub("/.*", "", $4); print $4 }')

[[ -n "$address" ]] || {
	printf '%s\n' 'No private IPv4 LAN address is active; refusing to expose unauthenticated ttyd.' >&2
	exit 1
}

install -d -m 0700 -o nixos -g users "$runtime_dir"
printf '%s\n' "$address" >"$address_file"
chown nixos:users "$address_file"
chmod 0600 "$address_file"
systemctl restart chev-ttyd-rescue.service

printf '%s\n' 'WARNING: temporary rescue terminal has no authentication or encryption.'
printf '%s\n' 'Use it only on a trusted private LAN and disable it immediately afterward.'
printf 'URL: http://%s:7681\n' "$address"
printf '%s\n' 'Run rescue-remote-off immediately when finished.'
