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

detect_profile() {
	if [[ -f /etc/NIXOS && -n "${WSL_DISTRO_NAME:-}" ]]; then
		printf 'nixos-wsl\n'
	elif [[ "$(uname -s)" == "Darwin" ]]; then
		if ! command_exists nix; then
			printf 'macos-managed\n'
		elif [[ "$(uname -m)" == "arm64" ]]; then
			printf 'macos\n'
		else
			printf 'macos-intel\n'
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
		macos-intel) printf '%s#macos-x86_64\n' "$source_root" ;;
		darwin-macos) printf '%s#macos-arm64\n' "$source_root" ;;
		darwin-macos-intel) printf '%s#macos-x86_64\n' "$source_root" ;;
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
