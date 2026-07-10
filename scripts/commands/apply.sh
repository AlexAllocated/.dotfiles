#!/usr/bin/env bash

apply_profile() {
	local profile="$1"
	local source_root="${2:-$REPO_ROOT}"
	local flake_ref
	case "$profile" in
		macos-managed)
			apply_macos_managed 0
			;;
		nixos-wsl)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command sudo
			require_command nixos-rebuild
			sudo nixos-rebuild boot --flake "$flake_ref"
			printf 'NixOS-WSL generation installed. Restart with: wsl.exe -t NixOS\n'
			;;
		darwin-macos | darwin-macos-intel)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command darwin-rebuild
			darwin-rebuild switch --flake "$flake_ref"
			;;
		linux | macos | macos-intel)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command home-manager
			home-manager switch -b hm-backup --flake "$flake_ref"
			;;
		*)
			printf 'Unknown profile: %s\n' "$profile" >&2
			return 2
			;;
	esac
}

apply_with_update() {
	local profile="$1"
	if [[ "$profile" == "macos-managed" ]]; then
		DOTFILES_SKIP_NVIM_PRIME=1 apply_macos_managed 1
		run_update "$profile"
		record_neovim_stamp
	else
		local work candidate
		work="$(mktemp -d)"
		candidate="$work/repo"
		trap 'rm -rf "$work"' EXIT
		prepare_update_candidate "$candidate" "$work"
		printf 'Applying %s from the validated staging checkout...\n' "$profile"
		apply_profile "$profile" "$candidate"
		accept_candidate_locks "$candidate"
		sync_live_neovim_runtime
		trap - EXIT
		rm -rf "$work"
		printf 'Updated pins passed validation and were applied to %s.\n' "$profile"
	fi
	commit_and_push_updates
	print_repo_status
}
