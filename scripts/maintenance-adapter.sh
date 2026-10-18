#!/usr/bin/env bash
# Narrow native operations used by the Python controller. Never call run_update
# or apply_with_update here: they combine preparation and live mutation.
set -euo pipefail

ACTION="${1:?adapter action required}"
REPO_ROOT="${2:?explicit candidate checkout required}"
WORK="${3:?owned adapter work directory required}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
SCRIPT_DIR="$REPO_ROOT/scripts"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/commands/update.sh
source "$SCRIPT_DIR/commands/update.sh"

case "$ACTION" in
	legacy-apply)
		profile="${4:?explicit legacy profile required}"
		case "$profile" in
			ubuntu-wsl | linux | macos | darwin-macos) ;;
			*)
				printf 'Profile is not an allowed legacy compatibility target: %s\n' "$profile" >&2
				exit 2
				;;
		esac
		# shellcheck source=scripts/profiles/macos-managed.sh
		source "$SCRIPT_DIR/profiles/macos-managed.sh"
		# shellcheck source=scripts/commands/apply.sh
		source "$SCRIPT_DIR/commands/apply.sh"
		ensure_git_identity
		apply_profile "$profile" "$REPO_ROOT"
		;;
	codex-pin) update_codex_candidate "$REPO_ROOT" "$WORK" ;;
	mac-links)
		[[ "$(uname -s)" == Darwin ]] || exit 2
		# shellcheck source=scripts/profiles/macos-managed.sh
		source "$SCRIPT_DIR/profiles/macos-managed.sh"
		write_profile_marker macos-managed
		mkdir -p "$HOME/.config/neovide" "$HOME/.local/bin"
		# Existing link helpers preserve collisions as backups. Do not invoke
		# detach_legacy_codex_links: Codex user preferences remain machine-local.
		while IFS=' ' read -r destination source; do
			[[ -n "$destination" ]] || continue
			link_path "$HOME/$destination" "$REPO_ROOT/$source"
		done <<'LINKS'
.zprofile .zprofile
.zshrc .zshrc
.gitconfig .gitconfig
.p10k.zsh .p10k.zsh
.wezterm.lua .wezterm.lua
rustfmt.toml rustfmt.toml
.config/nvim nvim
.config/neovide/config.toml neovide/config.toml
.config/wezterm wezterm
.local/bin/dotctl scripts/dotctl
.local/bin/updoot scripts/updoot
LINKS
		write_mise_config
		link_1password_agent
		ensure_macos_lan_mouse
		;;
	editor-prepare | editor-check | editor-apply)
		mkdir -p "$WORK"
		config="$WORK/config"
		mkdir -p "$config"
		if [[ -e "$config/nvim" || -L "$config/nvim" ]]; then
			[[ -L "$config/nvim" && "$(readlink "$config/nvim")" == "$REPO_ROOT/nvim" ]] || {
				printf 'Unexpected editor config in adapter workspace.\n' >&2
				exit 1
			}
		else
			ln -s "$REPO_ROOT/nvim" "$config/nvim"
		fi
		export DOTFILES_ROOT="$REPO_ROOT"
		export DOTFILES_PROFILE="${4:-$(detect_profile)}"
		export DOTFILES_NVIM_CONFIG_ROOT="$REPO_ROOT/nvim"
		lock_suffix=""
		[[ "$DOTFILES_PROFILE" != macos-managed ]] || lock_suffix=".macos-managed"
		export DOTFILES_NVIM_AUTOMATION=1
		export DOTFILES_NVIM_PIN_UPDATE=1 DOTFILES_NVIM_RUNTIME_SYNC=1
		export DOTFILES_NVIM_PLUGIN_UPDATE=0
		export DOTFILES_NVIM_MASON_UPDATE=0
		[[ "$ACTION" != editor-prepare ]] || export DOTFILES_NVIM_MASON_UPDATE=1 DOTFILES_NVIM_PLUGIN_UPDATE=1
		export NVIM_APPNAME=nvim
		export DOTFILES_LAZYVIM_JSON="$REPO_ROOT/nvim/lazyvim.json"
		export DOTFILES_NVIM_LOCKFILE="$REPO_ROOT/nvim/lazy-lock$lock_suffix.json"
		export DOTFILES_NVIM_MASON_LOCKFILE="$REPO_ROOT/nvim/mason-lock$lock_suffix.json"
		export XDG_CONFIG_HOME="$config"
		export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
		if [[ "$ACTION" != editor-apply ]]; then
			export XDG_DATA_HOME="$WORK/data" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache"
			mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
		fi
		case "$ACTION" in
			editor-prepare)
				run_neovim_automation --headless '+set nomore' '+lua require("config.bootstrap").prepare_runtime()'
				;;
			editor-check | editor-apply)
				run_neovim_automation --headless '+set nomore' '+lua require("config.bootstrap").sync_runtime()'
				;;
		esac
		;;
	*)
		printf 'Unsupported maintenance adapter action: %s\n' "$ACTION" >&2
		exit 2
		;;
esac
