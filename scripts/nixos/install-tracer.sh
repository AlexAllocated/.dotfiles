#!/usr/bin/env bash
set -euo pipefail

disk=""
expected_serial=""
target_root="/mnt"

usage() {
	cat <<'EOF'
Usage: sudo install-tracer --disk /dev/nvme... --expected-serial SERIAL
                           [--target-root /mnt]

Installs encrypted NixOS only into the largest unallocated region on a
validated 4 TB-class disk that already contains Windows Boot Manager. Existing
Windows partitions are preserved. The command creates a 2 GiB XBOOTLDR and a
LUKS2/Btrfs NixOS partition, then installs the tracer flake.

Windows must be installed first into approximately 500 GiB while the secondary
Intel SSD is physically disconnected. Secure Boot and BitLocker must still be
disabled for this first installation.
EOF
}

while (($#)); do
	case "$1" in
		--disk)
			disk="${2:-}"
			shift 2
			;;
		--expected-serial)
			expected_serial="${2:-}"
			shift 2
			;;
		--target-root)
			target_root="${2:-}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

[[ -n "$disk" && -n "$expected_serial" ]] || {
	printf '%s\n' '--disk and --expected-serial are required.' >&2
	exit 2
}
if ((EUID != 0)); then
	exec sudo --preserve-env=TRACER_DOTFILES_SOURCE -- "$0" \
		--disk "$disk" --expected-serial "$expected_serial" --target-root "$target_root"
fi
if [[ "${TRACER_INSTALL_PRIVATE_MOUNTS:-0}" != 1 ]]; then
	export TRACER_INSTALL_PRIVATE_MOUNTS=1
	exec unshare --mount --propagation private -- "$BASH" "$0" \
		--disk "$disk" --expected-serial "$expected_serial" --target-root "$target_root"
fi

disk="$(readlink -f -- "$disk")"
target_root="$(realpath -m -- "$target_root")"
[[ "$target_root" == /mnt || "$target_root" == /mnt/* ]] || {
	printf 'Target root must be /mnt or below it: %s\n' "$target_root" >&2
	exit 1
}
[[ -b "$disk" && "$(lsblk -dnro TYPE "$disk" | xargs)" == disk ]] || {
	printf 'Target is not a whole block device: %s\n' "$disk" >&2
	exit 1
}
actual_serial="$(lsblk -dnro SERIAL "$disk" | xargs)"
actual_model="$(lsblk -dnro MODEL "$disk" | xargs)"
actual_size="$(lsblk -bdnro SIZE "$disk" | xargs)"
actual_transport="$(lsblk -dnro TRAN "$disk" | xargs)"
[[ "$actual_serial" == "$expected_serial" ]] || {
	printf 'Serial mismatch: expected %s, found %s.\n' "$expected_serial" "$actual_serial" >&2
	exit 1
}
[[ "$actual_transport" == nvme && "$actual_size" -ge 3500000000000 ]] || {
	printf '%s\n' 'Tracer target must be a 4 TB-class NVMe disk.' >&2
	exit 1
}
root_source="$(findmnt -nro SOURCE /)"
root_source="${root_source%%\[*}"
root_parent=""
if [[ -b "$root_source" ]]; then
	root_parent="$(lsblk -no PKNAME "$root_source" | head -n 1 | xargs)"
fi
[[ -z "$root_parent" || "$disk" != "/dev/$root_parent" ]] || {
	printf '%s\n' 'Refusing to install over the running root disk.' >&2
	exit 1
}
if lsblk -nrpo MOUNTPOINTS "$disk" | grep -q '[^[:space:]]'; then
	printf 'Refusing a target disk with mounted filesystems: %s\n' "$disk" >&2
	exit 1
fi
for number in 5 6; do
	if sgdisk -i "$number" "$disk" 2>/dev/null | grep -q '^Partition GUID code:'; then
		printf 'Partition number %s is already occupied; refusing the expected Windows-first layout.\n' "$number" >&2
		exit 1
	fi
done

mapfile -t esp_candidates < <(
	lsblk -lnpo PATH,PARTTYPE "$disk" | awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1 }'
)
windows_esp=""
probe="$(mktemp -d /run/tracer-esp-probe.XXXXXXXX)"
cleanup_probe() {
	mountpoint -q "$probe" && umount "$probe"
	rmdir "$probe" 2>/dev/null || true
}
trap cleanup_probe EXIT
for candidate in "${esp_candidates[@]}"; do
	if mount -o ro,nosuid,nodev,noexec "$candidate" "$probe" 2>/dev/null; then
		if [[ -f "$probe/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
			[[ -z "$windows_esp" ]] || {
				printf '%s\n' 'More than one Windows ESP was found on the target disk.' >&2
				exit 1
			}
			windows_esp="$candidate"
		fi
		umount "$probe"
	fi
done
[[ -n "$windows_esp" ]] || {
	printf '%s\n' 'Windows Boot Manager was not found on the target disk.' >&2
	exit 1
}
esp_number="$(lsblk -dnro PARTN "$windows_esp" | xargs)"

free_record="$(
	parted -m -s "$disk" unit s print free |
		awk -F: '$5 == "free;" { gsub(/s/, "", $2); gsub(/s/, "", $3); gsub(/s/, "", $4); print $4, $2, $3 }' |
		sort -nr | head -n 1
)"
read -r free_size free_start free_end <<<"$free_record"
sector_size="$(blockdev --getss "$disk")"
minimum_free_sectors=$((2500 * 1024 * 1024 * 1024 / sector_size))
[[ -n "${free_size:-}" && "$free_size" -ge "$minimum_free_sectors" ]] || {
	printf '%s\n' 'The largest unallocated extent is smaller than the 2.5 TiB safety minimum.' >&2
	exit 1
}
boot_sectors=$((2 * 1024 * 1024 * 1024 / sector_size))
boot_end=$((free_start + boot_sectors - 1))
root_start=$((boot_end + 1))
root_end=$((free_end - 2048))
((root_end > root_start)) || {
	printf '%s\n' 'Computed Tracer root extent is invalid.' >&2
	exit 1
}

printf '\nValidated Tracer installation target:\n'
printf '  Disk:          %s\n  Model:         %s\n  Serial:        %s\n  Size:          %s bytes\n' \
	"$disk" "$actual_model" "$actual_serial" "$actual_size"
printf '  Windows ESP:   %s (preserved)\n' "$windows_esp"
printf '  XBOOTLDR:      sectors %s-%s (new)\n' "$free_start" "$boot_end"
printf '  Encrypted Nix: sectors %s-%s (new)\n' "$root_start" "$root_end"
printf '\nType exactly: INSTALL TRACER %s\n> ' "$actual_serial"
read -r confirmation
[[ "$confirmation" == "INSTALL TRACER $actual_serial" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing was changed.' >&2
	exit 1
}

sgdisk \
	--new=5:"$free_start":"$boot_end" --typecode=5:ea00 --change-name=5:TRACER_BOOT \
	--new=6:"$root_start":"$root_end" --typecode=6:8309 --change-name=6:TRACER_CRYPT \
	--change-name="$esp_number":TRACER_ESP \
	"$disk"
partprobe "$disk"
udevadm settle
boot_device="$(readlink -f /dev/disk/by-partlabel/TRACER_BOOT)"
root_device="$(readlink -f /dev/disk/by-partlabel/TRACER_CRYPT)"
windows_esp="$(readlink -f /dev/disk/by-partlabel/TRACER_ESP)"

mkfs.fat -F 32 -n TRACER_BOOT "$boot_device"
printf '\nChoose the Tracer root recovery passphrase. Store it in 1Password.\n'
cryptsetup luksFormat --type luks2 "$root_device"
cryptsetup open "$root_device" tracer-root
mkfs.btrfs --force --label TRACER_NIX /dev/mapper/tracer-root

install -d "$target_root"
mount /dev/mapper/tracer-root "$target_root"
for subvolume in @root @home @nix @games @swap; do
	btrfs subvolume create "$target_root/$subvolume"
done
umount "$target_root"
mount -o subvol=@root,compress=zstd:3,noatime /dev/mapper/tracer-root "$target_root"
install -d "$target_root"/{boot,efi,games,home,nix,swap}
mount -o subvol=@home,compress=zstd:3,noatime /dev/mapper/tracer-root "$target_root/home"
mount -o subvol=@nix,compress=zstd:3,noatime /dev/mapper/tracer-root "$target_root/nix"
mount -o subvol=@games,compress=zstd:3,noatime /dev/mapper/tracer-root "$target_root/games"
mount -o subvol=@swap,noatime /dev/mapper/tracer-root "$target_root/swap"
mount "$boot_device" "$target_root/boot"
mount "$windows_esp" "$target_root/efi"
btrfs filesystem mkswapfile --size 16G "$target_root/swap/swapfile"

fallback_directory="$target_root/efi/EFI/WindowsFallbackBackup"
fallback_backup="$fallback_directory/windows-fallback-original.efi"
fallback_absent="$fallback_directory/windows-fallback-original.absent"
fallback_target="$target_root/efi/EFI/BOOT/BOOTX64.EFI"
install -d -m 0700 "$fallback_directory"
if [[ -f "$fallback_target" ]]; then
	install -m 0600 "$fallback_target" "$fallback_backup"
else
	install -m 0600 /dev/null "$fallback_absent"
fi

invoking_user="${SUDO_USER:-alx}"
invoking_home="$(getent passwd "$invoking_user" | awk -F: '{ print $6 }')"
working_source="$invoking_home/.dotfiles"
if [[ ! -d "$working_source/.git" ]]; then
	working_source="${TRACER_DOTFILES_SOURCE:?TRACER_DOTFILES_SOURCE is not set}"
fi
nixos-install \
	--root "$target_root" \
	--flake "path:$working_source#tracer" \
	--no-root-password \
	--max-jobs 12 \
	--cores 2

# Carry the rescue environment's working Wi-Fi profiles into the installed
# system without ever committing their credentials to the repository. This
# keeps the first permanent boot reachable over SSH before Ethernet and the
# final static profile are configured.
source_connections="/etc/NetworkManager/system-connections"
target_connections="$target_root/etc/NetworkManager/system-connections"
if [[ -d "$source_connections" ]]; then
	install -d -m 0700 "$target_connections"
	while IFS= read -r -d '' connection; do
		install -m 0600 "$connection" "$target_connections/$(basename "$connection")"
	done < <(find "$source_connections" -maxdepth 1 -type f -print0)
fi

install -d -m 0755 -o 1000 -g 100 "$target_root/home/alx"
if [[ -d "$invoking_home/.dotfiles/.git" ]]; then
	rsync -a --exclude=result --exclude='result-*' "$invoking_home/.dotfiles/" "$target_root/home/alx/.dotfiles/"
else
	rsync -a "$working_source/" "$target_root/home/alx/.dotfiles/"
fi
for relative in .codex .config/sunshine .config/obs-studio .ssh/authorized_keys code; do
	if [[ -e "$invoking_home/$relative" && ! -L "$invoking_home/$relative" ]]; then
		install -d -m 0700 "$target_root/home/alx/$(dirname "$relative")"
		rsync -a "$invoking_home/$relative" "$target_root/home/alx/$(dirname "$relative")/"
	fi
done
chown -R 1000:100 "$target_root/home/alx"

printf '\nSet the graphical login password for alx. This is separate from the LUKS recovery passphrase.\n'
nixos-enter --root "$target_root" -c 'passwd alx'

printf '\nTracer installation completed without rebooting.\n'
printf '%s\n' 'Next: boot once with systemd-boot, enroll Secure Boot keys, then enroll TPM2 LUKS unlock and enable Lanzaboote.'
