#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: reboot-windows

Find the unique Windows Boot Manager entry, require the typed confirmation
WINDOWS, set it for the next boot only, and reboot.
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

boot_method=""
windows_entry=""
mapfile -t systemd_entries < <(bootctl list --json=short 2>/dev/null | jq -r '
	.[] | select((.title // "") | test("^Windows Boot Manager$"; "i")) | .id
' 2>/dev/null || true)
if ((${#systemd_entries[@]} == 1)); then
	boot_method="systemd-boot"
	windows_entry="${systemd_entries[0]}"
elif ((${#systemd_entries[@]} > 1)); then
	printf '%s\n' 'More than one Windows Boot Manager entry is present in systemd-boot; refusing.' >&2
	exit 1
else
	mapfile -t firmware_entries < <(efibootmgr 2>/dev/null | sed -nE \
		's/^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+Windows Boot Manager([[:space:]].*)?$/\1/p')
	if ((${#firmware_entries[@]} == 1)); then
		boot_method="firmware"
		windows_entry="${firmware_entries[0]}"
	elif ((${#firmware_entries[@]} > 1)); then
		printf '%s\n' 'More than one firmware Windows Boot Manager entry exists; refusing.' >&2
		exit 1
	else
		printf '%s\n' 'No unique Windows Boot Manager entry was found in systemd-boot or UEFI firmware.' >&2
		exit 1
	fi
fi

[[ -t 0 && -t 1 ]] || {
	printf '%s\n' 'Interactive confirmation is required; refusing to reboot.' >&2
	exit 1
}
printf 'Type WINDOWS to reboot into Windows Boot Manager: '
IFS= read -r confirmation
[[ "$confirmation" == "WINDOWS" ]] || {
	printf '%s\n' 'Confirmation did not match; reboot cancelled.' >&2
	exit 1
}

printf 'Setting one-shot %s entry to %s and rebooting.\n' "$boot_method" "$windows_entry"
if [[ "$boot_method" == "systemd-boot" ]]; then
	sudo bootctl set-oneshot "$windows_entry"
else
	sudo efibootmgr --bootnext "$windows_entry"
fi
sudo systemctl reboot
