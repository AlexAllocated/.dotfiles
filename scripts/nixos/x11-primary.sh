#!/usr/bin/env bash

restore_x11_primary() {
	local output="$1" attempt query
	[[ -n "${DISPLAY:-}" ]] || return 0
	for ((attempt = 0; attempt < 20; attempt++)); do
		# Read Xwayland's cached resources; --query can poll physical hardware.
		if query=$(timeout 1 xrandr --current 2>/dev/null); then
			query=$'\n'"$query"
			if [[ "$query" == *$'\n'"$output connected primary "* ]]; then
				return 0
			fi
			if [[ "$query" == *$'\n'"$output connected "* ]] &&
				timeout 1 xrandr --output "$output" --primary >/dev/null 2>&1; then
				return 0
			fi
		fi
		sleep 0.1
	done
	printf 'Could not restore X11 primary output %s\n' "$output" >&2
	return 1
}
