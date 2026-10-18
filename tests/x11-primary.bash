#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/nixos/x11-primary.sh
source "$repo_root/scripts/nixos/x11-primary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export DISPLAY=:fixture
query_status=0
: >"$fixture/queries"
: >"$fixture/writes"

timeout() {
	[[ "$1" == 1 ]]
	shift
	"$@"
}

sleep() { :; }

xrandr() {
	case "$1" in
		--current)
			printf 'query\n' >>"$fixture/queries"
			cat "$fixture/outputs"
			return "$query_status"
			;;
		--output)
			[[ "$3" == --primary && $# == 3 ]]
			printf '%s\n' "$2" >>"$fixture/writes"
			printf 'Screen 0\n%s connected primary 3440x1440+0+0\nMoonlight connected 2732x2048+3440+0\n' \
				"$2" >"$fixture/outputs"
			;;
		*) return 99 ;;
	esac
}

# No write when the existing primary is correct, including repeated checks.
printf 'Screen 0\nDP-1 connected primary 3440x1440+0+0\n' >"$fixture/outputs"
restore_x11_primary DP-1
restore_x11_primary DP-1
[[ ! -s "$fixture/writes" ]]

# Niri can be "on" before and after a fast cycle while X11 loses the primary.
printf 'Screen 0\nMoonlight connected primary 2732x2048+3440+0\nDP-1 connected 3440x1440+0+0\n' >"$fixture/outputs"
restore_x11_primary DP-1
restore_x11_primary DP-1
[[ "$(<"$fixture/writes")" == DP-1 ]]

# The caller resolves the connector each time, rather than retaining DP-1.
printf 'Moonlight connected primary 2732x2048+3440+0\nDP-5 connected 3440x1440+0+0\n' >"$fixture/outputs"
restore_x11_primary DP-5
[[ "$(tail -n 1 "$fixture/writes")" == DP-5 ]]

# Missing outputs and failed cached queries are bounded, and never issue writes.
for query_status in 0 1; do
	: >"$fixture/queries"
	: >"$fixture/writes"
	if restore_x11_primary absent 2>"$fixture/error"; then
		exit 1
	fi
	(($(wc -l <"$fixture/queries") == 20))
	[[ ! -s "$fixture/writes" ]]
done

: >"$fixture/queries"
unset DISPLAY
restore_x11_primary DP-1
[[ ! -s "$fixture/queries" ]]
printf 'PASS: cached X11 primary recovery, connector changes, and bounded failure\n'
