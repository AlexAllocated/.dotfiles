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

brew_bundle_supports_option() {
	local option="$1"
	brew bundle install --help 2>/dev/null | grep -q -- "$option"
}

migrate_macos_formula_sources() {
	if brew list --formula --full-name 2>/dev/null | grep -qx 'stripe/stripe-cli/stripe'; then
		printf 'Migrating Stripe CLI from stripe/stripe-cli to homebrew/core...\n'
		brew_noninteractive uninstall --formula stripe/stripe-cli/stripe
	fi
	if brew tap 2>/dev/null | grep -qx 'stripe/stripe-cli'; then
		printf 'Removing the unused stripe/stripe-cli tap...\n'
		brew_noninteractive untap stripe/stripe-cli
	fi
}

migrate_macos_cask_ownership() {
	local font_dir="$HOME/Library/Fonts"
	if ! brew list --cask font-bigblue-terminal-nerd-font >/dev/null 2>&1 &&
		[[ -d "$font_dir" ]] &&
		find "$font_dir" -maxdepth 1 -type f -name 'BigBlueTerm*NerdFont*.ttf' -print -quit | grep -q .; then
		printf 'Replacing unmanaged BigBlue Terminal font files with the Homebrew cask...\n'
		brew_noninteractive install --cask --force font-bigblue-terminal-nerd-font
	fi
}

apply_macos_managed_links() {
	mkdir -p "$HOME/.codex/rules" "$HOME/.config/neovide" "$HOME/.local/bin"
	link_path "$HOME/.zprofile" "$REPO_ROOT/.zprofile"
	link_path "$HOME/.zshrc" "$REPO_ROOT/.zshrc"
	link_path "$HOME/.gitconfig" "$REPO_ROOT/.gitconfig"
	link_path "$HOME/.p10k.zsh" "$REPO_ROOT/.p10k.zsh"
	link_path "$HOME/.wezterm.lua" "$REPO_ROOT/.wezterm.lua"
	link_path "$HOME/rustfmt.toml" "$REPO_ROOT/rustfmt.toml"
	link_path "$HOME/.config/nvim" "$REPO_ROOT/nvim"
	link_path "$HOME/.config/neovide/config.toml" "$REPO_ROOT/neovide/config.toml"
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
	local brewfile="$1"
	local kind package
	for kind in formula cask; do
		brew bundle list --file "$brewfile" --"$kind" |
			while IFS= read -r package; do
				[[ -n "$package" ]] || continue
				if brew outdated --"$kind" "$package" 2>/dev/null | grep -q .; then
					brew_noninteractive upgrade --"$kind" "$package"
				fi
			done
	done
}

install_brewfile() {
	local brewfile="$1"
	local bundle_args=(bundle install --file "$brewfile")
	if brew_bundle_supports_option --jobs; then
		bundle_args+=(--jobs=1)
	fi
	if brew_bundle_supports_option --no-lock; then
		bundle_args+=(--no-lock)
	fi
	brew_noninteractive "${bundle_args[@]}"
}

ensure_macos_desktop_apps() {
	local source_root="${1:-$REPO_ROOT}"
	local brewfile="$source_root/platforms/macos/Brewfile"
	ensure_homebrew
	migrate_macos_cask_ownership
	install_brewfile "$brewfile"
	load_homebrew_shellenv
}

ensure_macos_packages() {
	local update="${1:-0}"
	local brewfile="$REPO_ROOT/platforms/macos-managed/Brewfile"
	local desktop_brewfile="$REPO_ROOT/platforms/macos/Brewfile"
	ensure_homebrew
	migrate_macos_formula_sources
	if [[ "$update" == "1" ]]; then
		brew_noninteractive update
	fi
	migrate_macos_cask_ownership
	install_brewfile "$brewfile"
	install_brewfile "$desktop_brewfile"
	if [[ "$update" == "1" ]]; then
		update_brewfile_packages "$brewfile"
		update_brewfile_packages "$desktop_brewfile"
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

restore_macos_launchd_ssh_agent_socket() {
	local agent_socket launch_socket service_target
	agent_socket="$(onepassword_agent_socket)"
	launch_socket="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
	service_target="gui/$(id -u)"
	[[ -n "$launch_socket" && -L "$launch_socket" ]] || return 0
	[[ "$(readlink "$launch_socket")" == "$agent_socket" ]] || return 0

	if launchctl bootout "$service_target/com.openssh.ssh-agent" >/dev/null 2>&1; then
		rm -f "$launch_socket"
		if ! launchctl bootstrap "$service_target" /System/Library/LaunchAgents/com.openssh.ssh-agent.plist >/dev/null 2>&1; then
			printf 'Could not restart the macOS SSH agent. Log out and back in to recreate %s.\n' "$launch_socket" >&2
			return 1
		fi
		printf 'Restored the macOS launchd SSH agent socket.\n'
		return 0
	fi

	rm -f "$launch_socket"
	printf 'Removed the legacy launchd SSH-agent bridge. Log out and back in to recreate the standard macOS socket.\n'
}

cleanup_legacy_macos_docker_workshop() {
	local state_dir service_target label plist path docker_bin container image_id image_source cleaned=0
	state_dir="$HOME/.local/share/dotfiles"
	service_target="gui/$(id -u)"

	for label in \
		com.alexallocated.dotfiles.hostd \
		com.alexallocated.dotfiles.1password-ssh-auth-sock; do
		plist="$HOME/Library/LaunchAgents/$label.plist"
		if [[ -f "$plist" ]] || launchctl print "$service_target/$label" >/dev/null 2>&1; then
			cleaned=1
		fi
		launchctl bootout "$service_target/$label" >/dev/null 2>&1 || true
		launchctl bootout "$service_target" "$plist" >/dev/null 2>&1 || true
		launchctl remove "$label" >/dev/null 2>&1 || true
		rm -f "$plist"
	done

	restore_macos_launchd_ssh_agent_socket

	for path in \
		"$state_dir/hostd" \
		"$state_dir/hostd-handler" \
		"$state_dir/hostd-server" \
		"$state_dir/hostd.out.log" \
		"$state_dir/hostd.err.log" \
		"$state_dir/1password-ssh-auth-sock" \
		"$state_dir/1password-ssh-auth-sock.out.log" \
		"$state_dir/1password-ssh-auth-sock.err.log"; do
		[[ -e "$path" || -L "$path" ]] || continue
		rm -rf "$path"
		cleaned=1
	done

	if command_exists docker; then
		docker_bin="$(command -v docker)"
	elif [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
		docker_bin=/Applications/Docker.app/Contents/Resources/bin/docker
	else
		docker_bin=""
	fi
	if [[ -n "$docker_bin" ]] && "$docker_bin" info >/dev/null 2>&1; then
		for container in dotfiles-workshop dotfiles-nixos; do
			if "$docker_bin" container inspect "$container" >/dev/null 2>&1; then
				"$docker_bin" container rm -f "$container" >/dev/null
				cleaned=1
			fi
		done
		if "$docker_bin" image inspect dotfiles-workshop:local >/dev/null 2>&1; then
			if "$docker_bin" image rm dotfiles-workshop:local >/dev/null 2>&1; then
				cleaned=1
			fi
		fi
		if [[ "${DOTFILES_PURGE_LEGACY_DOCKER_WORKSHOP:-0}" == "1" ]]; then
			for path in dotfiles-workshop-home dotfiles-nixos-home dotfiles-nix-builder-store; do
				if "$docker_bin" volume inspect "$path" >/dev/null 2>&1; then
					"$docker_bin" volume rm "$path" >/dev/null
					cleaned=1
				fi
			done
			while IFS= read -r image_id; do
				[[ -n "$image_id" ]] || continue
				image_source="$("$docker_bin" image inspect --format \
					'{{ index .Config.Labels "org.opencontainers.image.source" }}' "$image_id" 2>/dev/null || true)"
				[[ "$image_source" == "https://github.com/AlexAllocated/.dotfiles" ]] || continue
				if "$docker_bin" image rm "$image_id" >/dev/null 2>&1; then
					cleaned=1
				fi
			done < <("$docker_bin" image ls --all --quiet --no-trunc | sort -u)
			if "$docker_bin" image inspect nixos/nix:latest >/dev/null 2>&1; then
				if "$docker_bin" image rm nixos/nix:latest >/dev/null 2>&1; then
					cleaned=1
				fi
			fi
		fi
	fi

	if ((cleaned)); then
		printf 'Removed legacy macOS Docker workshop services and runtime state.\n'
	fi
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
	cleanup_legacy_macos_docker_workshop
	apply_macos_managed_links
	write_mise_config
	ensure_macos_packages "$update"
	ensure_bun_codex "$update"
	link_1password_agent
	prime_neovim
	printf 'macos-managed is ready. Open a new terminal or run: exec zsh -l\n'
}
