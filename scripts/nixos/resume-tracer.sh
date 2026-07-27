#!/usr/bin/env bash
set -euo pipefail

thread_file="$HOME/.codex/tracer-thread-id"
workspace="$HOME/.dotfiles"

[[ -f "$thread_file" && ! -L "$thread_file" ]] || {
	printf 'Tracer conversation marker is missing: %s\n' "$thread_file" >&2
	exit 1
}
thread_id="$(<"$thread_file")"
[[ "$thread_id" =~ ^[0-9a-fA-F-]{36}$ ]] || {
	printf '%s\n' 'Tracer conversation marker is invalid.' >&2
	exit 1
}
[[ -d "$workspace/.git" ]] || {
	printf 'Tracer dotfiles checkout is missing: %s\n' "$workspace" >&2
	exit 1
}

if [[ -n "${TMUX:-}" ]]; then
	cd "$workspace"
	exec codex resume "$thread_id"
fi

exec tmux new-session -A -s tracer-migration -c "$workspace" "codex resume '$thread_id'"
