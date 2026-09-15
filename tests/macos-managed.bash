#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/commands/update.sh
source "$REPO_ROOT/scripts/commands/update.sh"
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

stage_repo() { :; }
command_exists() { return 1; }
update_neovim_candidate() { :; }
validate_update_candidate() { :; }
update_codex_candidate() { printf 'codex release requested\n'; }

detect_profile() { printf 'macos-managed\n'; }
[[ "$(neovim_lock_relative)" == nvim/lazy-lock.macos-managed.json ]]
[[ -z "$(prepare_update_candidate /unused /unused)" ]]
detect_profile() { printf 'macos\n'; }
[[ "$(neovim_lock_relative)" == nvim/lazy-lock.json ]]
[[ "$(prepare_update_candidate /unused /unused)" == 'codex release requested' ]]

printf 'Company and personal macOS package/update paths passed\n'
