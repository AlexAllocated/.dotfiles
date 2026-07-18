#!/usr/bin/env bash
set -euo pipefail

connector="${CHEV_IPAD_CONNECTOR:-}"
restore_output=""

usage() {
	printf '%s\n' 'Usage: ipad-display-off [--connector HDMI-A-1] [--restore-output DP-1]'
}

while (($#)); do
	case "$1" in
		--connector)
			connector="${2:-}"
			shift 2
			;;
		--restore-output)
			restore_output="${2:-}"
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

if [[ -z "$connector" && -f /run/chev-ipad-display/connector ]]; then
	connector="$(</run/chev-ipad-display/connector)"
fi
[[ "$connector" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf '%s\n' 'No safe dummy connector is configured.' >&2
	exit 1
}
[[ -z "$restore_output" || "$restore_output" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'Unsafe restore output name: %s\n' "$restore_output" >&2
	exit 1
}

output_json="$(kscreen-doctor --json)"
jq -e '.outputs | type == "array"' <<<"$output_json" >/dev/null || {
	printf '%s\n' 'KScreen returned an invalid output inventory; refusing to change displays.' >&2
	exit 1
}

if ! jq -e --arg connector "$connector" \
	'.outputs[] | select(.name == $connector and .connected == true)' \
	<<<"$output_json" >/dev/null; then
	printf 'Configured dummy output %s is not connected; refusing to change displays.\n' "$connector" >&2
	exit 1
fi

if ! jq -e --arg connector "$connector" \
	'.outputs[] | select(.name == $connector and .enabled == true)' \
	<<<"$output_json" >/dev/null; then
	printf 'iPad dummy output %s is already disabled.\n' "$connector"
	exit 0
fi

mapfile -t other_enabled < <(
	jq -r --arg connector "$connector" \
		'.outputs[] | select(.connected == true and .enabled == true and .name != $connector) | .name' \
		<<<"$output_json"
)

arguments=()
if [[ -n "$restore_output" ]]; then
	[[ "$restore_output" != "$connector" ]] || {
		printf '%s\n' 'The restore output must differ from the dummy output.' >&2
		exit 1
	}
	jq -e --arg output "$restore_output" \
		'.outputs[] | select(.name == $output and .connected == true)' \
		<<<"$output_json" >/dev/null || {
		printf 'Restore output %s is not connected; refusing to disable the dummy.\n' "$restore_output" >&2
		exit 1
	}
	arguments+=("output.$restore_output.enable")
elif ((${#other_enabled[@]} == 0)); then
	printf '%s\n' 'The dummy is the only enabled output; refusing to leave Plasma with no display.' >&2
	printf '%s\n' 'Connect another display and use --restore-output NAME to enable it atomically.' >&2
	exit 1
fi

arguments+=("output.$connector.disable")
kscreen-doctor "${arguments[@]}"
printf 'Disabled iPad dummy output %s.\n' "$connector"
printf '%s\n' 'Before the next remote session, restart Sunshine locally; its preflight will re-enable the dummy.'
