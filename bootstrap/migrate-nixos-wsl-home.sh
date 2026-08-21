#!/usr/bin/env bash
set -euo pipefail

target_distro="${TARGET_DISTRO:-Ubuntu-26.04}"
target_user="${TARGET_USER:-alx}"
target_port="${TARGET_PORT:-2222}"
state_root="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-wsl-migration"
key_path="$state_root/migration_ed25519"
codex_snapshot="$state_root/codex-sqlite"
manifest_path="$state_root/source-paths.txt"

[[ "${WSL_DISTRO_NAME:-}" == "NixOS" ]] || {
	printf 'Run this helper from the source NixOS WSL distro.\n' >&2
	exit 1
}
for command in rsync ssh ssh-keygen sqlite3 wsl.exe; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

mkdir -p "$state_root" "$codex_snapshot"
chmod 0700 "$state_root" "$codex_snapshot"
rm -f "$codex_snapshot"/*.sqlite
for database in "$HOME/.codex/sqlite"/*.sqlite; do
	[[ -f "$database" ]] || continue
	sqlite3 "$database" ".backup '$codex_snapshot/$(basename "$database")'"
done

paths=(
	.aws
	.azure
	.config/direnv
	.config/gh
	.config/git/identity
	.config/git/local
	.config/github-copilot
	.config/go
	.config/lazygit
	.config/op
	.docker
	.dotnet
	.gnupg
	.kube
	.local/share/zoxide
	.local/state/lazygit
	.local/state/nvim
	.nuget
	.ssh
	.zsh_history
	code
	codex-portfolio-audit
)
optional_credentials=(
	.cargo/config
	.cargo/config.toml
	.cargo/credentials
	.cargo/credentials.toml
	.config/gcloud
	.gradle/gradle.properties
	.local/share/keyrings
	.netrc
	.npmrc
	.pypirc
	.terraform.d/credentials.tfrc.json
)
paths+=("${optional_credentials[@]}")

: >"$manifest_path"
for relative in "${paths[@]}"; do
	if [[ -e "$HOME/$relative" || -L "$HOME/$relative" ]]; then
		printf '%s\n' "$relative" >>"$manifest_path"
	fi
done
printf '.codex/sqlite\n' >>"$manifest_path"

rm -f "$key_path" "$key_path.pub"
ssh-keygen -q -t ed25519 -N '' -C dotfiles-wsl-migration -f "$key_path"
public_key="$(<"$key_path.pub")"
wsl.exe --distribution "$target_distro" --user root --exec /bin/bash -lc \
	"install -d -m 0700 -o '$target_user' -g '$target_user' '/home/$target_user/.ssh'; printf '%s\\n' '$public_key' >>'/home/$target_user/.ssh/authorized_keys'; chown '$target_user:$target_user' '/home/$target_user/.ssh/authorized_keys'; chmod 0600 '/home/$target_user/.ssh/authorized_keys'; systemctl restart ssh.service" \
	>/dev/null

target_ip="$(
	wsl.exe --distribution "$target_distro" --user root --exec /bin/hostname -I \
		| tr -d '\r' | awk '{ print $1 }'
)"
[[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	printf 'Could not determine the %s IPv4 address.\n' "$target_distro" >&2
	exit 1
}
ssh_command="ssh -i $key_path -p $target_port -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
$ssh_command "$target_user@$target_ip" 'true'

rsync_args=(
	-aHAX
	--numeric-ids
	--protect-args
	--relative
	--info=progress2
	-e "$ssh_command"
)
while IFS= read -r relative; do
	[[ "$relative" == .codex/sqlite ]] && continue
	rsync "${rsync_args[@]}" "$HOME/./$relative" "$target_user@$target_ip:/home/$target_user/"
done <"$manifest_path"

rsync "${rsync_args[@]}" "$codex_snapshot/" "$target_user@$target_ip:/home/$target_user/.codex/sqlite/"

verification_failed=0
while IFS= read -r relative; do
	[[ "$relative" == .codex/sqlite ]] && continue
	if rsync "${rsync_args[@]}" --checksum --dry-run --itemize-changes \
		"$HOME/./$relative" "$target_user@$target_ip:/home/$target_user/" | grep -q .; then
		printf 'Verification mismatch: %s\n' "$relative" >&2
		verification_failed=1
	fi
done <"$manifest_path"
if rsync "${rsync_args[@]}" --checksum --dry-run --itemize-changes \
	"$codex_snapshot/" "$target_user@$target_ip:/home/$target_user/.codex/sqlite/" | grep -q .; then
	printf 'Verification mismatch: .codex/sqlite\n' >&2
	verification_failed=1
fi

$ssh_command "$target_user@$target_ip" \
	"sed -i '/dotfiles-wsl-migration$/d' '/home/$target_user/.ssh/authorized_keys'; chmod 0700 '/home/$target_user/.ssh'; chmod 0600 '/home/$target_user/.ssh/authorized_keys'"
rm -f "$key_path" "$key_path.pub"

((verification_failed == 0)) || exit 1
printf 'Verified the selected home and authentication state in %s.\n' "$target_distro"
