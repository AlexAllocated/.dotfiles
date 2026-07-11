#!/usr/bin/env bash

set -euo pipefail

path=${1:?file path is required}
line=${2:-0}
column=${3:-1}

export PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH"
cd -- "$(dirname -- "$path")"

if [[ $line =~ ^[1-9][0-9]*$ ]]; then
	exec nvim "+call cursor($line, $column)" -- "$path"
fi

exec nvim -- "$path"
