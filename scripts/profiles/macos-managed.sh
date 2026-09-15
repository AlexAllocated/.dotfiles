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
	if brew list --cask wezterm >/dev/null 2>&1; then
		printf 'Migrating WezTerm from the stable cask to the official nightly cask...\n'
		brew_noninteractive uninstall --cask wezterm
		if ! brew_noninteractive install --cask wezterm@nightly; then
			printf 'The nightly install failed; restoring the stable WezTerm cask...\n' >&2
			brew_noninteractive install --cask wezterm ||
				printf 'WezTerm could not be restored automatically; rerun the profile after Homebrew is reachable.\n' >&2
			return 1
		fi
	fi
	if ! brew list --cask font-bigblue-terminal-nerd-font >/dev/null 2>&1 &&
		[[ -d "$font_dir" ]] &&
		find "$font_dir" -maxdepth 1 -type f -name 'BigBlueTerm*NerdFont*.ttf' -print -quit | grep -q .; then
		printf 'Replacing unmanaged BigBlue Terminal font files with the Homebrew cask...\n'
		brew_noninteractive install --cask --force font-bigblue-terminal-nerd-font
	fi
}

detach_legacy_codex_links() {
	local config_link="$HOME/.codex/config.toml"
	local rules_link="$HOME/.codex/rules/default.rules"
	local legacy_config="$REPO_ROOT/codex/config.toml"
	local legacy_rules="$REPO_ROOT/codex/rules/default.rules"
	local deletion_commit temporary

	if [[ -L "$config_link" && "$(readlink "$config_link")" == "$legacy_config" ]]; then
		temporary="$(mktemp)"
		if [[ -r "$config_link" ]]; then
			cp "$config_link" "$temporary"
		else
			deletion_commit="$(git -C "$REPO_ROOT" log -1 --format=%H --diff-filter=D -- codex/config.toml)"
			[[ -n "$deletion_commit" ]] &&
				git -C "$REPO_ROOT" show "$deletion_commit^:codex/config.toml" >"$temporary"
		fi
		rm "$config_link"
		if [[ -s "$temporary" ]]; then
			mv "$temporary" "$config_link"
			chmod 600 "$config_link"
			printf 'Detached Codex config from the dotfiles repo at %s.\n' "$config_link"
		else
			rm -f "$temporary"
		fi
	fi

	if [[ -L "$rules_link" && "$(readlink "$rules_link")" == "$legacy_rules" ]]; then
		rm "$rules_link"
	fi
}

apply_macos_managed_links() {
	detach_legacy_codex_links
	mkdir -p "$HOME/.config/neovide" "$HOME/.local/bin"
	link_path "$HOME/.zprofile" "$REPO_ROOT/.zprofile"
	link_path "$HOME/.zshrc" "$REPO_ROOT/.zshrc"
	link_path "$HOME/.gitconfig" "$REPO_ROOT/.gitconfig"
	link_path "$HOME/.p10k.zsh" "$REPO_ROOT/.p10k.zsh"
	link_path "$HOME/.wezterm.lua" "$REPO_ROOT/.wezterm.lua"
	link_path "$HOME/rustfmt.toml" "$REPO_ROOT/rustfmt.toml"
	link_path "$HOME/.config/nvim" "$REPO_ROOT/nvim"
	link_path "$HOME/.config/neovide/config.toml" "$REPO_ROOT/neovide/config.toml"
	link_path "$HOME/.config/wezterm" "$REPO_ROOT/wezterm"
	link_path "$HOME/.local/bin/dotctl" "$REPO_ROOT/scripts/dotctl"
	if [[ -L "$HOME/.tool-versions" && "$(readlink "$HOME/.tool-versions")" == "$REPO_ROOT/.tool-versions" ]]; then
		rm "$HOME/.tool-versions"
	fi
}

ensure_macos_lan_mouse_login_item() {
	local error
	if ! error="$(osascript \
		-e 'set itemName to "Lan Mouse"' \
		-e 'set appPath to "/Applications/Lan Mouse.app"' \
		-e 'tell application "System Events"' \
		-e 'if exists login item itemName then' \
		-e 'set existingItem to login item itemName' \
		-e 'if path of existingItem is not appPath then' \
		-e 'delete existingItem' \
		-e 'else' \
		-e 'set hidden of existingItem to true' \
		-e 'end if' \
		-e 'end if' \
		-e 'if not (exists login item itemName) then make login item at end with properties {name:itemName, path:appPath, hidden:true}' \
		-e 'end tell' 2>&1)"; then
		printf 'Could not configure the Lan Mouse login item: %s\n' "$error" >&2
		printf 'Allow the requesting terminal to control System Events, then rerun dotctl apply macos-managed.\n' >&2
		return 1
	fi
	printf 'Lan Mouse will start at login.\n'
}

ensure_macos_lan_mouse() (
	local version="0.11.0"
	local expected_build="20260612.132919"
	local expected_identifier="de.feschber.LanMouse"
	local target="/Applications/Lan Mouse.app"
	local asset checksum url work archive extracted source_app
	local current_identifier current_version current_build actual_checksum install_root backup=""

	case "$(uname -m)" in
	arm64)
		asset="lan-mouse-macos-arm64.zip"
		checksum="5ff9965d05be7f125b1d75b9e7259d874ec98aa086ce40012522bc25406500a9"
		;;
	x86_64)
		asset="lan-mouse-macos-intel.zip"
		checksum="d24c38ccf50061ab710826003c19d10e1243415ffa18f421d4498b2b858c8b64"
		;;
	*)
		printf 'Lan Mouse v%s has no supported macOS build for %s.\n' "$version" "$(uname -m)" >&2
		return 1
		;;
	esac

	if [[ -e "$target" && ! -d "$target" ]]; then
		printf 'Refusing to replace non-application path: %s\n' "$target" >&2
		return 1
	fi
	if [[ -d "$target" ]]; then
		current_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)"
		if [[ "$current_identifier" != "$expected_identifier" ]]; then
			printf 'Refusing to replace %s because its bundle identifier is %s, not %s.\n' \
				"$target" "${current_identifier:-unknown}" "$expected_identifier" >&2
			return 1
		fi
		current_version="$(plutil -extract CFBundleShortVersionString raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)"
		current_build="$(plutil -extract CFBundleVersion raw -o - "$target/Contents/Info.plist" 2>/dev/null || true)"
	else
		current_version=""
		current_build=""
	fi

	if [[ "$current_version" != "$version" || "$current_build" != "$expected_build" ]]; then
		[[ -w /Applications ]] || {
			printf 'Installing Lan Mouse requires write access to /Applications.\n' >&2
			return 1
		}
		work="$(mktemp -d /tmp/dotfiles-lan-mouse.XXXXXX)"
		install_root=""
		cleanup_lan_mouse_install() {
			if [[ -n "$install_root" && "$install_root" == /Applications/.dotfiles-lan-mouse.* ]]; then
				rm -rf "$install_root"
			fi
			if [[ -n "$work" && "$work" == /tmp/dotfiles-lan-mouse.* ]]; then
				rm -rf "$work"
			fi
		}
		trap cleanup_lan_mouse_install EXIT

		archive="$work/$asset"
		extracted="$work/unpacked"
		url="https://github.com/feschber/lan-mouse/releases/download/v${version}/${asset}"
		printf 'Installing Lan Mouse v%s from the official %s release asset...\n' "$version" "$asset"
		curl --fail --location --output "$archive" "$url"
		actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
		if [[ "$actual_checksum" != "$checksum" ]]; then
			printf 'Lan Mouse archive checksum mismatch: expected %s, got %s.\n' "$checksum" "$actual_checksum" >&2
			return 1
		fi

		mkdir -p "$extracted"
		ditto -x -k "$archive" "$extracted"
		source_app="$extracted/Lan Mouse.app"
		[[ -d "$source_app" ]] || {
			printf 'The Lan Mouse archive does not contain Lan Mouse.app.\n' >&2
			return 1
		}
		[[ "$(plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist")" == "$expected_identifier" ]] || {
			printf 'The downloaded Lan Mouse bundle has an unexpected identifier.\n' >&2
			return 1
		}
		[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$source_app/Contents/Info.plist")" == "$version" ]] || {
			printf 'The downloaded Lan Mouse bundle has an unexpected version.\n' >&2
			return 1
		}
		[[ "$(plutil -extract CFBundleVersion raw -o - "$source_app/Contents/Info.plist")" == "$expected_build" ]] || {
			printf 'The downloaded Lan Mouse bundle has an unexpected build.\n' >&2
			return 1
		}
		codesign --verify --deep --strict "$source_app"

		install_root="$(mktemp -d /Applications/.dotfiles-lan-mouse.XXXXXX)"
		ditto "$source_app" "$install_root/Lan Mouse.app"
		codesign --verify --deep --strict "$install_root/Lan Mouse.app"
		if [[ -d "$target" ]]; then
			backup="$install_root/previous.app"
			mv "$target" "$backup"
		fi
		if ! mv "$install_root/Lan Mouse.app" "$target"; then
			if [[ -n "$backup" ]] && ! mv "$backup" "$target"; then
				printf 'The previous Lan Mouse app remains recoverable at %s.\n' "$backup" >&2
				install_root=""
			fi
			return 1
		fi
		printf 'Installed Lan Mouse v%s at %s.\n' "$version" "$target"
		cleanup_lan_mouse_install
		trap - EXIT
	else
		printf 'Lan Mouse v%s is already installed.\n' "$version"
	fi

	xattr -rd com.apple.quarantine "$target"
	codesign --verify --deep --strict "$target"
	ensure_macos_lan_mouse_login_item
	if ! pgrep -x lan-mouse >/dev/null 2>&1; then
		open -a "Lan Mouse"
	fi
)

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

update_macos_wezterm_nightly() {
	brew list --cask wezterm@nightly >/dev/null 2>&1 || return 0
	printf 'Updating WezTerm to the latest official nightly build...\n'
	brew_noninteractive upgrade --cask --greedy-latest wezterm@nightly
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
	install_brewfile "$source_root/platforms/macos-personal/Brewfile"
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
		update_macos_wezterm_nightly
	fi
	load_homebrew_shellenv
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
	ensure_macos_lan_mouse
	link_1password_agent
	prime_neovim
	printf 'macos-managed is ready. Open a new terminal or run: exec zsh -l\n'
}
