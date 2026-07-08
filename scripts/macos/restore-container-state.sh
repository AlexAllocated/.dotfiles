#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$script_dir/dotctl" restore-container-state "${1:-dotfiles-workshop}"
