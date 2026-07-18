#!/usr/bin/env bash
set -euo pipefail

machine_manifest=""
efi_device=""

usage() {
	cat <<'EOF'
Usage: recover-windows-fallback \
  --machine-manifest /private/import/machine-manifest.json \
  --efi-device /dev/disk/by-id/...

Restore only EFI/BOOT/BOOTX64.EFI from the installer-created, manifest-verified
fallback record after an interrupted bootctl operation. No partition is
formatted and EFI/Microsoft/Boot/bootmgfw.efi is never written.
EOF
}

while (($#)); do
	case "$1" in
		--machine-manifest)
			machine_manifest="${2:-}"
			shift 2
			;;
		--efi-device)
			efi_device="${2:-}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

[[ -n "$machine_manifest" && -n "$efi_device" ]] || {
	usage >&2
	exit 2
}
if ((EUID != 0)); then
	exec sudo -- "$(command -v bash)" "$0" \
		--machine-manifest "$machine_manifest" \
		--efi-device "$efi_device"
fi

[[ -f "$machine_manifest" && ! -L "$machine_manifest" ]] || {
	printf 'Unsafe machine manifest: %s\n' "$machine_manifest" >&2
	exit 1
}
machine_manifest="$(realpath "$machine_manifest")"
import_root="$(dirname "$machine_manifest")"
capsule_manifest="$import_root/manifest.json"
[[ "$(basename "$machine_manifest")" == "machine-manifest.json" && -f "$capsule_manifest" && ! -L "$capsule_manifest" ]] || {
	printf '%s\n' 'Machine manifest must be a verified imported capsule payload.' >&2
	exit 1
}
expected_manifest_hash="$(jq -er '.files[] | select(.path == "machine-manifest.json") | .sha256' "$capsule_manifest")"
[[ "$(sha256sum "$machine_manifest" | awk '{print $1}')" == "$expected_manifest_hash" ]] || {
	printf '%s\n' 'Machine manifest does not match its capsule hash.' >&2
	exit 1
}

efi_partuuid="$(jq -er '.partitions.windowsEsp.partuuid' "$machine_manifest")"
boot_partuuid="$(jq -er '.partitions.xbootldr.partuuid' "$machine_manifest")"
root_partuuid="$(jq -er '.partitions.nixRoot.partuuid' "$machine_manifest")"
manifest_efi="$(readlink -f "/dev/disk/by-partuuid/$efi_partuuid")"
boot_device="$(readlink -f "/dev/disk/by-partuuid/$boot_partuuid")"
root_device="$(readlink -f "/dev/disk/by-partuuid/$root_partuuid")"
efi_device="$(readlink -f "$efi_device")"
[[ -b "$manifest_efi" && -b "$boot_device" && -b "$root_device" && -b "$efi_device" ]] || {
	printf '%s\n' 'One or more manifest partitions are not present.' >&2
	exit 1
}
[[ "$(lsblk -ndo MAJ:MIN "$efi_device" | xargs)" == "$(lsblk -ndo MAJ:MIN "$manifest_efi" | xargs)" ]] || {
	printf '%s\n' 'Explicit EFI device is not the manifest ESP.' >&2
	exit 1
}
disk_name="$(lsblk -ndo PKNAME "$efi_device" | xargs)"
target_disk="$(readlink -f "/dev/$disk_name")"

validate-machine-manifest \
	--manifest "$machine_manifest" \
	--disk "$target_disk" \
	--efi-device "$efi_device" \
	--boot-device "$boot_device" \
	--root-device "$root_device"
fsck.fat -n "$efi_device" || {
	printf '%s\n' 'ESP is dirty or inconsistent; repair it in Windows before fallback recovery.' >&2
	exit 1
}

mount_path="$(mktemp -d)"
mounted=0
cleanup() {
	if ((mounted)); then
		umount "$mount_path" >/dev/null 2>&1 || true
	fi
	rmdir "$mount_path" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mount -o ro,nosuid,nodev,noexec "$efi_device" "$mount_path"
mounted=1

microsoft="$mount_path/EFI/Microsoft/Boot/bootmgfw.efi"
backup="$mount_path/EFI/NixOS/windows-fallback-original.efi"
absent="$mount_path/EFI/NixOS/windows-fallback-original.absent"
target="$mount_path/EFI/BOOT/BOOTX64.EFI"
expected_microsoft_hash="$(jq -r '.windowsBoot.microsoftLoaderSha256' "$machine_manifest")"
expected_fallback_present="$(jq -r '.windowsBoot.fallbackPresent' "$machine_manifest")"
expected_fallback_hash="$(jq -r '.windowsBoot.fallbackSha256 // empty' "$machine_manifest")"
[[ -f "$microsoft" && "$(sha256sum "$microsoft" | awk '{print $1}')" == "$expected_microsoft_hash" ]] || {
	printf '%s\n' 'Microsoft Boot Manager does not match the authoritative manifest.' >&2
	exit 1
}
if [[ "$expected_fallback_present" == "true" ]]; then
	[[ -f "$backup" && ! -e "$absent" && "$(sha256sum "$backup" | awk '{print $1}')" == "$expected_fallback_hash" ]] || {
		printf '%s\n' 'Recorded fallback backup is missing, conflicting, or has the wrong hash.' >&2
		exit 1
	}
else
	[[ -f "$absent" && ! -e "$backup" ]] || {
		printf '%s\n' 'Recorded fallback-absent marker is missing or conflicting.' >&2
		exit 1
	}
fi

[[ -t 0 && -t 1 ]] || {
	printf '%s\n' 'Interactive confirmation is required.' >&2
	exit 1
}
printf 'Type RESTORE WINDOWS FALLBACK to modify only EFI/BOOT/BOOTX64.EFI: '
IFS= read -r confirmation
[[ "$confirmation" == "RESTORE WINDOWS FALLBACK" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing changed.' >&2
	exit 1
}

umount "$mount_path"
mounted=0
mount -o rw,nosuid,nodev,noexec "$efi_device" "$mount_path"
mounted=1
if [[ "$expected_fallback_present" == "true" ]]; then
	install -D -m 0644 "$backup" "$target"
else
	rm -f -- "$target"
fi
sync "$target_disk"
umount "$mount_path"
mounted=0

mount -o ro,nosuid,nodev,noexec "$efi_device" "$mount_path"
mounted=1
[[ "$(sha256sum "$microsoft" | awk '{print $1}')" == "$expected_microsoft_hash" ]] || {
	printf '%s\n' 'Microsoft Boot Manager changed unexpectedly.' >&2
	exit 1
}
if [[ "$expected_fallback_present" == "true" ]]; then
	[[ -f "$target" && "$(sha256sum "$target" | awk '{print $1}')" == "$expected_fallback_hash" ]] || {
		printf '%s\n' 'Fallback restore verification failed.' >&2
		exit 1
	}
else
	[[ ! -e "$target" ]] || {
		printf '%s\n' 'Fallback absence verification failed.' >&2
		exit 1
	}
fi

printf '%s\n' 'Windows fallback state restored and verified; Microsoft Boot Manager was unchanged.'
