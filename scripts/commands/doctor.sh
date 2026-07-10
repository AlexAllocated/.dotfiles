#!/usr/bin/env bash

doctor_command() {
	local name="$1"
	if command_exists "$name"; then
		printf '%-14s %s\n' "$name" "$(command -v "$name")"
	else
		printf '%-14s missing\n' "$name"
	fi
}

run_doctor() {
	local profile identity name email
	profile="$(detect_profile)"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		load_homebrew_shellenv >/dev/null 2>&1 || true
	fi
	printf 'dotfiles repo: %s\n' "$REPO_ROOT"
	printf 'detected profile: %s\n' "$profile"
	printf 'uname: %s\n' "$(uname -a)"
	if command_exists nix; then
		printf 'nix: %s\n' "$(nix --version)"
	else
		printf 'nix: not found\n'
	fi
	for name in zsh git gh op ssh nvim bun node rustc cargo rust-analyzer go dotnet wezterm docker; do
		doctor_command "$name"
	done
	identity="$(git_identity_path)"
	name="$(git_config_value user.name "$identity")"
	email="$(git_config_value user.email "$identity")"
	if [[ -n "$name" && -n "$email" ]]; then
		printf '%-14s %s <%s>\n' git-identity "$name" "$email"
	else
		printf '%-14s missing (%s)\n' git-identity "$identity"
	fi
	if [[ "$(uname -s)" == "Darwin" ]]; then
		if [[ -S "$(onepassword_agent_socket)" ]]; then
			printf '%-14s %s\n' 1password-ssh "$(onepassword_agent_socket)"
		else
			printf '%-14s unavailable\n' 1password-ssh
		fi
	fi
	if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
		printf 'WSL_DISTRO_NAME=%s\n' "$WSL_DISTRO_NAME"
		if command_exists systemctl; then
			if systemctl --user is-system-running >/dev/null 2>&1; then
				printf '%-14s healthy\n' systemd-user
			else
				printf '%-14s unhealthy\n' systemd-user
			fi
		fi
		if command_exists powershell.exe; then
			printf '%-14s reachable\n' windows-interop
		else
			printf '%-14s unavailable\n' windows-interop
		fi
	fi
}
