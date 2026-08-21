#!/usr/bin/env bash
set -euo pipefail

repo_url="https://github.com/AlexAllocated/.dotfiles.git"
repo_root="$HOME/.dotfiles"

if [[ ! -x /nix/var/nix/profiles/default/bin/nix ]]; then
	printf 'Determinate Nix is not installed.\n' >&2
	exit 1
fi
# shellcheck disable=SC1091
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

if [[ ! -e "$repo_root" ]]; then
	git clone "$repo_url" "$repo_root"
elif [[ ! -d "$repo_root/.git" ]]; then
	printf 'Refusing to replace non-Git path: %s\n' "$repo_root" >&2
	exit 1
elif [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
	printf 'Refusing to update dirty Ubuntu dotfiles checkout: %s\n' "$repo_root" >&2
	exit 1
else
	git -C "$repo_root" fetch origin main
	git -C "$repo_root" merge --ff-only origin/main
fi

activation="$({
	nix build "path:$repo_root#homeConfigurations.ubuntu-wsl.activationPackage" \
		--no-link --print-out-paths
} | tail -n 1)"
"$activation/activate"
printf 'Ubuntu-WSL Home Manager profile is active.\n'
