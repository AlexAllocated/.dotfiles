#!/usr/bin/env bash

load_homebrew_shellenv() {
	if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
	elif [[ -x /usr/local/bin/brew ]]; then
		eval "$(/usr/local/bin/brew shellenv)"
	elif command_exists brew; then
		eval "$(brew shellenv)"
	else
		return 1
	fi
}

ensure_homebrew() {
	load_homebrew_shellenv && return 0
	printf 'Homebrew is not installed; installing it noninteractively...\n'
	NONINTERACTIVE=1 /bin/bash -c "$(curl --fail -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	load_homebrew_shellenv
}

brew_noninteractive() {
	HOMEBREW_NO_ASK=1 HOMEBREW_NO_ENV_HINTS=1 brew "$@"
}

brew_bundle_supports_no_lock() {
	brew bundle install --help 2>/dev/null | grep -q -- '--no-lock'
}

apply_macos_managed_links() {
	mkdir -p "$HOME/.codex/rules" "$HOME/.config" "$HOME/.local/bin"
	link_path "$HOME/.zprofile" "$REPO_ROOT/.zprofile"
	link_path "$HOME/.zshrc" "$REPO_ROOT/.zshrc"
	link_path "$HOME/.gitconfig" "$REPO_ROOT/.gitconfig"
	link_path "$HOME/.p10k.zsh" "$REPO_ROOT/.p10k.zsh"
	link_path "$HOME/.wezterm.lua" "$REPO_ROOT/.wezterm.lua"
	link_path "$HOME/rustfmt.toml" "$REPO_ROOT/rustfmt.toml"
	link_path "$HOME/.config/nvim" "$REPO_ROOT/nvim"
	link_path "$HOME/.config/wezterm" "$REPO_ROOT/wezterm"
	link_path "$HOME/.codex/config.toml" "$REPO_ROOT/codex/config.toml"
	link_path "$HOME/.codex/rules/default.rules" "$REPO_ROOT/codex/rules/default.rules"
	link_path "$HOME/.local/bin/dotctl" "$REPO_ROOT/scripts/dotctl"
	if [[ -L "$HOME/.tool-versions" && "$(readlink "$HOME/.tool-versions")" == "$REPO_ROOT/.tool-versions" ]]; then
		rm "$HOME/.tool-versions"
	fi
}

write_mise_config() {
	local target="$HOME/.config/mise/config.toml"
	mkdir -p "$(dirname "$target")"
	if [[ ! -e "$target" ]]; then
		printf '[settings]\npython.compile = false\n' >"$target"
	fi
}

update_brewfile_packages() {
	local kind package
	for kind in formula cask; do
		brew bundle list --file "$REPO_ROOT/platforms/macos-managed/Brewfile" --"$kind" |
			while IFS= read -r package; do
				[[ -n "$package" ]] || continue
				if brew outdated --"$kind" "$package" 2>/dev/null | grep -q .; then
					brew_noninteractive upgrade --"$kind" "$package"
				fi
			done
	done
}

ensure_macos_packages() {
	local update="${1:-0}"
	local brewfile="$REPO_ROOT/platforms/macos-managed/Brewfile"
	local bundle_args=(bundle install --file "$brewfile")
	ensure_homebrew
	if [[ "$update" == "1" ]]; then
		brew_noninteractive update
	fi
	if brew_bundle_supports_no_lock; then
		bundle_args+=(--no-lock)
	fi
	brew_noninteractive "${bundle_args[@]}"
	if [[ "$update" == "1" ]]; then
		update_brewfile_packages
	fi
	load_homebrew_shellenv
}

ensure_bun_codex() {
	local update="${1:-0}"
	local bun_bin global_bin
	bun_bin="$(command -v bun)"
	global_bin="$("$bun_bin" pm bin -g 2>/dev/null || printf '%s/.bun/bin\n' "$HOME")"
	if [[ "$update" == "1" || ! -x "$global_bin/codex" ]]; then
		printf 'Installing @openai/codex@latest with Bun...\n'
		"$bun_bin" add --global @openai/codex@latest
	fi
	mkdir -p "$HOME/.local/bin"
	ln -sfn "$global_bin/codex" "$HOME/.local/bin/codex"
	"$global_bin/codex" --version >/dev/null
}

onepassword_agent_socket() {
	printf '%s/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\n' "$HOME"
}

link_1password_agent() {
	local source target
	source="$(onepassword_agent_socket)"
	target="$HOME/.1password/agent.sock"
	mkdir -p "$(dirname "$target")"
	if [[ -e "$target" && ! -L "$target" ]]; then
		backup_path "$target"
	fi
	ln -sfn "$source" "$target"
}

neovim_config_stamp() {
	find "$REPO_ROOT/nvim" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

record_neovim_stamp() {
	local stamp_file="$HOME/.local/share/dotfiles/nvim-bootstrap.sha256"
	mkdir -p "$(dirname "$stamp_file")"
	neovim_config_stamp >"$stamp_file"
}

prime_neovim() {
	local stamp_file="$HOME/.local/share/dotfiles/nvim-bootstrap.sha256"
	local log_file="$HOME/.cache/dotfiles/nvim-bootstrap.log"
	local stamp
	[[ "${DOTFILES_SKIP_NVIM_PRIME:-0}" != "1" ]] || return 0
	command_exists nvim || return 0
	mkdir -p "$(dirname "$stamp_file")" "$(dirname "$log_file")"
	stamp="$(neovim_config_stamp)"
	if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$stamp" ]]; then
		return 0
	fi
	printf 'Priming Neovim plugins and parsers...\n'
	if DOTFILES_NVIM_AUTOMATION=1 nvim --headless "+set nomore" "+Lazy! restore" "+MasonUpdate" "+TSUpdateSync" "+lua require(\"config.bootstrap\").wait_for_mason()" +qa >"$log_file" 2>&1; then
		record_neovim_stamp
		return 0
	fi
	tail -n 80 "$log_file" >&2 || true
	return 1
}

apply_macos_managed() {
	local update="${1:-0}"
	[[ "$(uname -s)" == "Darwin" ]] || {
		printf 'macos-managed can only be applied on macOS.\n' >&2
		return 1
	}
	ensure_git_identity
	write_profile_marker macos-managed
	apply_macos_managed_links
	write_mise_config
	ensure_macos_packages "$update"
	ensure_bun_codex "$update"
	link_1password_agent
	prime_neovim
	printf 'macos-managed is ready. Open a new terminal or run: exec zsh -l\n'
}
