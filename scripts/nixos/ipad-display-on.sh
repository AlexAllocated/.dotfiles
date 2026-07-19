#!/usr/bin/env bash
set -euo pipefail

connector="${CHEV_IPAD_CONNECTOR:-}"
sole=0
while (($#)); do
	case "$1" in
		--connector)
			connector="${2:-}"
			shift 2
			;;
		--sole)
			sole=1
			shift
			;;
		-h | --help)
			printf '%s\n' 'Usage: ipad-display-on [--connector HDMI-A-1] [--sole]'
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

if [[ -z "$connector" && -f /run/chev-ipad-display/connector ]]; then
	connector="$(</run/chev-ipad-display/connector)"
fi
[[ "$connector" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf '%s\n' 'No safe dummy connector is configured. Run ipad-display-prepare first.' >&2
	exit 1
}

mode_present=0
for mode_file in /sys/class/drm/card*-"$connector"/modes; do
	[[ -f "$mode_file" ]] || continue
	if grep -Fxq '2736x2048' "$mode_file"; then
		mode_present=1
	fi
done
((mode_present)) || {
	printf '%s\n' '2736x2048 is not present in DRM. Run ipad-display-prepare and complete its rebuild/reboot instruction.' >&2
	exit 1
}

arguments=(
	"output.$connector.enable"
	"output.$connector.mode.2736x2048@60"
	"output.$connector.scale.1.75"
)
if ((sole)); then
	while read -r other; do
		[[ "$other" == "$connector" || ! "$other" =~ ^[A-Za-z0-9._-]+$ ]] || arguments+=("output.$other.disable")
	done < <(kscreen-doctor --json | jq -r '.outputs[] | select(.connected == true and .enabled == true) | .name')
fi

kscreen-doctor "${arguments[@]}"
printf 'Enabled %s at the Windows-matched 2736x2048@60 host timing.\n' "$connector"
printf '%s\n' 'Applied the workstation UI scale of 175%.'
printf '%s\n' 'Request 2732x2048 in Moonlight for the iPad Pro client stream.'
