#!/usr/bin/env bash

verify_native_nixos_activation() {
	local running_system boot_system profile_link generation expected_entry default_entry
	running_system="$(readlink -f /run/current-system)"
	boot_system="$(readlink -f /nix/var/nix/profiles/system)"
	[[ -n "$running_system" && "$running_system" == "$boot_system" ]] || {
		printf 'The running NixOS system does not match the persistent boot profile.\n' >&2
		printf 'Running: %s\nBoot profile: %s\n' "$running_system" "$boot_system" >&2
		return 1
	}

	profile_link="$(readlink /nix/var/nix/profiles/system)"
	profile_link="${profile_link##*/}"
	case "$profile_link" in
		system-*-link)
			generation="${profile_link#system-}"
			generation="${generation%-link}"
			;;
		*)
			printf 'Could not identify the persistent NixOS generation from %s.\n' "$profile_link" >&2
			return 1
			;;
	esac
	[[ "$generation" =~ ^[0-9]+$ ]] || {
		printf 'Invalid persistent NixOS generation: %s\n' "$generation" >&2
		return 1
	}

	expected_entry="nixos-generation-$generation.conf"
	default_entry="$(sudo awk '$1 == "default" { print $2; exit }' /efi/loader/loader.conf)"
	[[ "$default_entry" == "$expected_entry" ]] || {
		printf 'systemd-boot does not default to the newly activated generation.\n' >&2
		printf 'Expected: %s\nConfigured: %s\n' "$expected_entry" "${default_entry:-missing}" >&2
		return 1
	}
	printf 'Verified generation %s is running and is the persistent systemd-boot default.\n' "$generation"
}

apply_profile() {
	local profile="$1"
	local source_root="${2:-$REPO_ROOT}"
	local flake_ref
	case "$profile" in
		chev-desktop | tracer)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command sudo
			require_command nixos-rebuild
			sudo nixos-rebuild switch --flake "$flake_ref"
			verify_native_nixos_activation
			;;
		macos-managed)
			apply_macos_managed 0
			;;
		ubuntu-wsl)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command nix
			if command_exists home-manager; then
				home-manager switch -b hm-backup --flake "$flake_ref"
			else
				local activation
				activation="$(nix build "path:$source_root#homeConfigurations.ubuntu-wsl.activationPackage" --no-link --print-out-paths)"
				"$activation/activate"
			fi
			apply_windows_packages "$source_root"
			apply_windows_integration "$REPO_ROOT"
			printf 'Ubuntu-WSL Home Manager generation activated live.\n'
			;;
		darwin-macos)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command darwin-rebuild
			darwin-rebuild switch --flake "$flake_ref"
			;;
		linux)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command home-manager
			home-manager switch -b hm-backup --flake "$flake_ref"
			;;
		macos)
			flake_ref="$(flake_ref_for_profile "$profile" "$source_root")"
			require_command home-manager
			home-manager switch -b hm-backup --flake "$flake_ref"
			ensure_macos_desktop_apps "$source_root"
			;;
		*)
			printf 'Unknown profile: %s\n' "$profile" >&2
			return 2
			;;
	esac
}

revalidate_and_reapply_profile() {
	local profile="$1"
	local work candidate
	printf 'Late upstream changes were integrated; validating and reapplying the merged checkout...\n'
	if [[ "$profile" == "macos-managed" ]]; then
		apply_macos_managed 0
		return
	fi
	work="$(mktemp -d)"
	candidate="$work/repo"
	trap_remove_on_exit "$work"
	stage_repo "$candidate"
	validate_update_candidate "$candidate"
	apply_profile "$profile" "$candidate"
	sync_live_neovim_runtime
	trap - EXIT
	rm -rf "$work"
}

apply_with_update() {
	local profile="$1"
	local apply_status=0 rebased=0 sync_status=0
	sync_before_update
	if [[ "$profile" == "macos-managed" ]]; then
		DOTFILES_SKIP_NVIM_PRIME=1 apply_macos_managed 1
		run_update "$profile"
		record_neovim_stamp
	else
		local work candidate
		work="$(mktemp -d)"
		candidate="$work/repo"
		trap_remove_on_exit "$work"
		prepare_update_candidate "$candidate" "$work"
		printf 'Applying %s from the validated staging checkout...\n' "$profile"
		apply_profile "$profile" "$candidate" || apply_status=$?
		# The candidate pins have already passed the full flake evaluation. Keep
		# the editor runtime reconciled even when a later host-integration step
		# fails, so opening Neovim does not perform the deferred work itself.
		if ((apply_status == 0)); then
			accept_candidate_locks "$candidate"
		else
			# Do not accept a flake lock whose build or application failed. The
			# independently validated Neovim lock is safe to reconcile on its own.
			accept_candidate_neovim_lock "$candidate"
		fi
		sync_live_neovim_runtime || sync_status=$?
		trap - EXIT
		rm -rf "$work"
		if ((apply_status != 0)); then
			printf 'Profile application failed with status %d after validated Neovim pins were reconciled.\n' "$apply_status" >&2
			return "$apply_status"
		fi
		if ((sync_status != 0)); then
			return "$sync_status"
		fi
		printf 'Updated pins passed validation and were applied to %s.\n' "$profile"
	fi
	commit_updates
	fetch_and_rebase_upstream rebased
	if [[ "$rebased" == "1" ]]; then
		revalidate_and_reapply_profile "$profile"
	fi
	cleanup_nix_after_updoot "$profile"
	push_updates
	print_repo_status
}
