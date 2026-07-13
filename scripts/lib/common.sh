#!/usr/bin/env bash

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

require_command() {
	if ! command_exists "$1"; then
		printf 'Required command not found: %s\n' "$1" >&2
		return 1
	fi
}

apply_windows_packages() {
	local source_root="${1:-$REPO_ROOT}"
	local script manifest neovide_config script_windows manifest_windows roaming_windows roaming_linux neovide_target
	[[ -n "${WSL_DISTRO_NAME:-}" ]] || return 0
	require_command powershell.exe
	require_command wslpath
	script="$source_root/scripts/windows/apply-packages.ps1"
	manifest="$source_root/platforms/windows/winget.json"
	neovide_config="$source_root/neovide/config.toml"
	[[ -f "$script" ]] || {
		printf 'Windows package reconciler not found: %s\n' "$script" >&2
		return 1
	}
	[[ -f "$manifest" ]] || {
		printf 'WinGet manifest not found: %s\n' "$manifest" >&2
		return 1
	}
	[[ -f "$neovide_config" ]] || {
		printf 'Neovide config not found: %s\n' "$neovide_config" >&2
		return 1
	}
	script_windows="$(wslpath -w "$script")"
	manifest_windows="$(wslpath -w "$manifest")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script_windows" \
		-ManifestPath "$manifest_windows"

	# Bypass packaged-app filesystem virtualization by writing through DrvFs.
	roaming_windows="$(powershell.exe -NoLogo -NoProfile -Command \
		'[Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)' | tr -d '\r')"
	[[ -n "$roaming_windows" ]] || {
		printf 'Could not determine the Windows Roaming AppData directory.\n' >&2
		return 1
	}
	roaming_linux="$(wslpath -u "$roaming_windows")"
	neovide_target="$roaming_linux/neovide/config.toml"
	mkdir -p "$(dirname "$neovide_target")"
	if [[ ! -f "$neovide_target" ]] || ! cmp -s "$neovide_config" "$neovide_target"; then
		cp "$neovide_config" "$neovide_target"
		printf 'Updated Neovide config at %s.\n' "$roaming_windows\\neovide\\config.toml"
	else
		printf 'Neovide config is current.\n'
	fi
}

trap_remove_on_exit() {
	local path="$1"
	local cleanup
	printf -v cleanup 'rm -rf -- %q' "$path"
	# Expand now so function-local paths remain available when EXIT fires.
	# shellcheck disable=SC2064
	trap "$cleanup" EXIT
}

detect_profile() {
	if [[ -f /etc/NIXOS && -n "${WSL_DISTRO_NAME:-}" ]]; then
		printf 'nixos-wsl\n'
	elif [[ "$(uname -s)" == "Darwin" ]]; then
		if [[ "$(uname -m)" != "arm64" ]]; then
			printf 'Unsupported platform: only Apple Silicon macOS is supported.\n' >&2
			return 2
		elif ! command_exists nix; then
			printf 'macos-managed\n'
		else
			printf 'macos\n'
		fi
	else
		printf 'linux\n'
	fi
}

flake_ref_for_profile() {
	local profile="$1"
	local source_root="${2:-$REPO_ROOT}"
	case "$profile" in
		nixos-wsl) printf '%s#wsl\n' "$source_root" ;;
		linux) printf '%s#linux\n' "$source_root" ;;
		macos) printf '%s#macos-arm64\n' "$source_root" ;;
		darwin-macos) printf '%s#macos-arm64\n' "$source_root" ;;
		*)
			printf 'Profile does not have a Nix flake output: %s\n' "$profile" >&2
			return 2
			;;
	esac
}

backup_path() {
	local path="$1"
	local backup_dir="$HOME/.backup_dotfiles"
	local stamp
	stamp="$(date +%Y%m%d%H%M%S)"
	mkdir -p "$backup_dir"
	mv "$path" "$backup_dir/$(basename "$path").$stamp"
	printf 'Backed up %s to %s\n' "$path" "$backup_dir/$(basename "$path").$stamp"
}

link_path() {
	local target="$1"
	local source="$2"
	if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
		return 0
	fi
	if [[ -e "$target" || -L "$target" ]]; then
		backup_path "$target"
	fi
	mkdir -p "$(dirname "$target")"
	ln -s "$source" "$target"
	printf 'Linked %s -> %s\n' "$target" "$source"
}

write_profile_marker() {
	mkdir -p "$HOME/.local/share/dotfiles"
	printf '%s\n' "$1" >"$HOME/.local/share/dotfiles/profile"
}

git_identity_path() {
	printf '%s/.config/git/identity\n' "$HOME"
}

git_config_value() {
	local key="$1"
	local file="${2:-}"
	command_exists git || return 0
	if [[ -n "$file" ]]; then
		git config --file "$file" --get "$key" 2>/dev/null || true
	else
		git config --global --get "$key" 2>/dev/null || true
	fi
}

write_git_identity() {
	local name="$1"
	local email="$2"
	local identity
	identity="$(git_identity_path)"
	mkdir -p "$(dirname "$identity")"
	{
		printf '[user]\n'
		printf '\tname = %s\n' "$name"
		printf '\temail = %s\n' "$email"
	} >"$identity"
	chmod 600 "$identity"
	printf 'Wrote Git identity to %s\n' "$identity"
}

default_identity_name() {
	local name
	name="$(git_config_value user.name)"
	if [[ -z "$name" ]] && command_exists id; then
		name="$(id -F 2>/dev/null || true)"
	fi
	[[ -n "$name" ]] || name="$(id -un)"
	printf '%s\n' "$name"
}

ensure_git_identity() {
	local identity existing_name existing_email name email default_name default_email
	identity="$(git_identity_path)"
	existing_name="$(git_config_value user.name "$identity")"
	existing_email="$(git_config_value user.email "$identity")"
	if [[ -n "$existing_name" && -n "$existing_email" ]]; then
		return 0
	fi
	default_name="${DOTFILES_GIT_NAME:-$(default_identity_name)}"
	default_email="${DOTFILES_GIT_EMAIL:-$(git_config_value user.email)}"
	if [[ -n "${DOTFILES_GIT_NAME:-}" && -n "${DOTFILES_GIT_EMAIL:-}" ]]; then
		write_git_identity "$DOTFILES_GIT_NAME" "$DOTFILES_GIT_EMAIL"
		return 0
	fi
	if [[ ! -t 0 || ! -t 1 ]]; then
		printf 'Git identity is not configured at %s.\n' "$identity" >&2
		printf 'Run interactively or set DOTFILES_GIT_NAME and DOTFILES_GIT_EMAIL.\n' >&2
		return 1
	fi
	printf 'Git author name [%s]: ' "$default_name"
	IFS= read -r name
	[[ -n "$name" ]] || name="$default_name"
	while [[ -z "${email:-}" ]]; do
		if [[ -n "$default_email" ]]; then
			printf 'Git author email [%s]: ' "$default_email"
		else
			printf 'Git author email: '
		fi
		IFS= read -r email
		[[ -n "$email" ]] || email="$default_email"
	done
	write_git_identity "$name" "$email"
}

print_repo_status() {
	if command_exists git && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf 'Repository changes after update/apply:\n'
		git -C "$REPO_ROOT" status --short
	fi
}
