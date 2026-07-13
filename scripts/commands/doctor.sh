#!/usr/bin/env bash

doctor_command() {
	local name="$1"
	if command_exists "$name"; then
		printf '%-14s %s\n' "$name" "$(command -v "$name")"
	else
		printf '%-14s missing\n' "$name"
	fi
}

doctor_windows_app() {
	local name="$1"
	local test_expression="$2"
	if powershell.exe -NoLogo -NoProfile -Command "if ($test_expression) { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
		printf '%-14s installed\n' "$name"
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
	for name in zsh git gh op ssh nvim codex bun node rustc cargo rust-analyzer go dotnet docker; do
		doctor_command "$name"
	done
	if [[ -n "${WSL_DISTRO_NAME:-}" && -x "$(command -v powershell.exe 2>/dev/null)" ]]; then
		doctor_windows_app neovide-win "Test-Path \"\$env:ProgramFiles\Neovide\neovide.exe\""
		doctor_windows_app wezterm-win "Test-Path \"\$env:ProgramFiles\WezTerm\wezterm-gui.exe\""
		doctor_windows_app codex-desktop 'Get-AppxPackage -Name OpenAI.Codex'
	else
		doctor_command neovide
		doctor_command wezterm
	fi
	identity="$(git_identity_path)"
	name="$(git_config_value user.name "$identity")"
	email="$(git_config_value user.email "$identity")"
	if [[ -n "$name" && -n "$email" ]]; then
		printf '%-14s %s <%s>\n' git-identity "$name" "$email"
	else
		printf '%-14s missing (%s)\n' git-identity "$identity"
	fi
	if [[ "$(uname -s)" == "Darwin" ]]; then
		if [[ -d "/Applications/Codex.app" || -d "$HOME/Applications/Codex.app" ]]; then
			printf '%-14s installed\n' codex-desktop
		else
			printf '%-14s missing\n' codex-desktop
		fi
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
