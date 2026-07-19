#!/usr/bin/env bash
set -euo pipefail

requested_connector="${CHEV_IPAD_CONNECTOR:-}"
apply_now=0

usage() {
	cat <<'EOF'
Usage: ipad-display-prepare [--connector HDMI-A-1] [--apply-now]

Find the connected FUN/EK1080 dummy adapter, never the LG monitor, and print
the persistent NixOS EDID-override configuration. --apply-now also attempts a
temporary debugfs override until the next reboot.
EOF
}

while (($#)); do
	case "$1" in
		--connector)
			requested_connector="${2:-}"
			shift 2
			;;
		--apply-now)
			apply_now=1
			shift
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

[[ -z "$requested_connector" || "$requested_connector" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'Unsafe DRM connector name: %s\n' "$requested_connector" >&2
	exit 1
}

firmware="${CHEV_IPAD_EDID:?NixOS wrapper did not provide CHEV_IPAD_EDID}"
[[ -f "$firmware" ]] || {
	printf 'Generated iPad EDID firmware is missing: %s\n' "$firmware" >&2
	exit 1
}

declare -a candidates=()
declare -A candidate_paths=()
for status_file in /sys/class/drm/card*-*/status; do
	[[ -f "$status_file" && "$(<"$status_file")" == "connected" ]] || continue
	sysfs_connector="${status_file%/status}"
	edid="$sysfs_connector/edid"
	# sysfs reports EDID attributes with a nominal size of zero even when a
	# read returns the complete binary payload, so `-s` rejects valid displays.
	[[ -r "$edid" ]] || continue
	decoded="$(edid-decode "$edid" 2>/dev/null || true)"
	[[ -n "$decoded" ]] || continue
	if grep -Eiq 'Manufacturer:[[:space:]]*GSM|GSM774B' <<<"$decoded"; then
		continue
	fi
	if grep -Eiq 'Manufacturer:[[:space:]]*FUN|EK1080T4KHR|FUN7F52' <<<"$decoded"; then
		connector="$(basename "$sysfs_connector" | sed -E 's/^card[0-9]+-//')"
		candidates+=("$connector")
		candidate_paths["$connector"]="$sysfs_connector"
	fi
done

if [[ -n "$requested_connector" ]]; then
	[[ -n "${candidate_paths[$requested_connector]:-}" ]] || {
		printf 'Connector %s is not the connected FUN/EK1080 dummy adapter; refusing override.\n' "$requested_connector" >&2
		exit 1
	}
	connector="$requested_connector"
else
	((${#candidates[@]} == 1)) || {
		printf 'Expected exactly one connected FUN/EK1080 dummy adapter; found %s.\n' "${#candidates[@]}" >&2
		exit 1
	}
	connector="${candidates[0]}"
fi

printf 'Verified dummy adapter connector: %s (FUN/EK1080; LG excluded)\n' "$connector"
printf '\nPersistent configuration (hosts/chev-desktop/hardware-generated.nix):\n'
printf '  dotfiles.desktop.ipadDisplay.connector = "%s";\n' "$connector"
printf '\nThen run: dotctl apply\nReboot once so drm.edid_firmware is active.\n'

if ((apply_now == 0)); then
	exit 0
fi
if ((EUID != 0)); then
	exec sudo -- "$(command -v env)" \
		"CHEV_IPAD_EDID=$firmware" \
		"CHEV_IPAD_CONNECTOR=${CHEV_IPAD_CONNECTOR:-}" \
		"$(command -v bash)" "$0" --connector "$connector" --apply-now
fi

debug_connector=""
for candidate in /sys/kernel/debug/dri/*/"$connector"; do
	[[ -d "$candidate" ]] || continue
	[[ -w "$candidate/edid_override" ]] || continue
	candidate="$(realpath -e -- "$candidate")"
	if [[ "$candidate" == "$debug_connector" ]]; then
		continue
	fi
	[[ -z "$debug_connector" ]] || {
		printf 'More than one debugfs connector matched %s; refusing runtime override.\n' "$connector" >&2
		exit 1
	}
	debug_connector="$candidate"
done
[[ -n "$debug_connector" ]] || {
	printf '%s\n' 'This kernel does not expose a writable per-connector EDID override; use the persistent config and reboot.' >&2
	exit 1
}

cat "$firmware" >"$debug_connector/edid_override"
if [[ -w "$debug_connector/trigger_hotplug" ]]; then
	printf '1\n' >"$debug_connector/trigger_hotplug"
elif [[ -w "${candidate_paths[$connector]}/status" ]]; then
	# Current DRM exposes the standard writable connector status attribute
	# instead. Writing `detect` re-runs fill_modes, which consumes the debugfs
	# EDID override without requiring a reboot.
	printf 'detect\n' >"${candidate_paths[$connector]}/status"
	card_device="${candidate_paths[$connector]%-$connector}"
	[[ -d "$card_device" ]] || {
		printf 'Could not resolve the DRM card for %s.\n' "$connector" >&2
		exit 1
	}
	# KWin listens for a DRM-card change event before refreshing its mode
	# inventory. The connector modes are already updated at this point.
	udevadm trigger --action=change "$card_device"
	udevadm settle --timeout=5
else
	printf 'reset' >"$debug_connector/edid_override"
	printf '%s\n' 'The EDID override was writable, but no live reprobe interface is available.' >&2
	exit 1
fi
sleep 1
mode_file="${candidate_paths[$connector]}/modes"
grep -Fxq '2732x2048' "$mode_file" || {
	printf '%s\n' 'Hotplug completed but 2732x2048 is not advertised; use the persistent config and reboot.' >&2
	exit 1
}
install -d -m 0755 /run/chev-ipad-display
printf '%s\n' "$connector" >/run/chev-ipad-display/connector
chmod 0644 /run/chev-ipad-display/connector
printf '%s\n' 'Temporary 2732x2048 EDID override is active. Run ipad-display-on as alex.'
