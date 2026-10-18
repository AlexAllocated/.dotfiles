#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/profiles/macos-managed.sh
source "$REPO_ROOT/scripts/profiles/macos-managed.sh"

ensure_homebrew() { :; }
migrate_macos_formula_sources() { :; }
migrate_macos_cask_ownership() { :; }
load_homebrew_shellenv() { :; }
install_brewfile() { printf '%s\n' "$1"; }
managed="$(ensure_macos_packages 0)"
[[ "$managed" == "$REPO_ROOT/platforms/macos-managed/Brewfile"$'\n'"$REPO_ROOT/platforms/macos/Brewfile" ]]
personal="$(ensure_macos_desktop_apps)"
[[ "$personal" == "$REPO_ROOT/platforms/macos/Brewfile"$'\n'"$REPO_ROOT/platforms/macos-personal/Brewfile" ]]

filtered="$(
	DOTFILES_REPO_ROOT="$REPO_ROOT" lua - <<'LUA'
package.path = os.getenv("DOTFILES_REPO_ROOT") .. "/nvim/lua/?.lua;" .. package.path
local kept = require("config.extras").filter({
	"lazyvim.plugins.extras.ai.copilot",
	"lazyvim.plugins.extras.ai.sidekick",
	"lazyvim.plugins.extras.lang.json",
	"lazyvim.plugins.extras.lang.nix",
	"lazyvim.plugins.extras.lang.rust",
})
print(table.concat(kept, " "))
LUA
)"
[[ "$filtered" == 'lazyvim.plugins.extras.lang.json lazyvim.plugins.extras.lang.rust' ]]
DOTFILES_REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(os.environ['DOTFILES_REPO_ROOT'])
sys.path.insert(0, str(root / 'scripts/dotfiles'))
import adapters
assert adapters.editor_locks('macos-managed') == ('nvim/lazy-lock.macos-managed.json', 'nvim/mason-lock.macos-managed.json')
assert 'nil' not in json.loads((root / adapters.editor_locks('macos-managed')[1]).read_text())['packages']
managed = (root / 'platforms/macos-managed/Brewfile').read_text()
shared = (root / 'platforms/macos/Brewfile').read_text()
assert 'claude-code' in managed and 'codex' not in managed + shared
assert 'codex-app' in (root / 'platforms/macos-personal/Brewfile').read_text()
assert 'wezterm@nightly' in shared
assert adapters.lan_mouse_pin(root)['version'] == '0.11.0'
PY
printf 'Company and personal macOS package/editor boundaries passed\n'
