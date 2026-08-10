#!/usr/bin/env bash
set -euo pipefail

device=""
expected_serial=""

install_efi_boot_payload() {
	local source_config="$mount_root/payload/EFI/BOOT/grub.cfg"
	local target_config="$mount_root/efi/EFI/BOOT/grub.cfg"
	local kernel_path initrd_path
	local -a kernel_paths initrd_paths

	mapfile -t kernel_paths < <(
		awk '$1 == "linux" && $2 ~ /\/nix\/store\/.*\/bzImage$/ { print $2 }' "$source_config" | sort -u
	)
	mapfile -t initrd_paths < <(awk '$1 == "initrd" { print $2 }' "$source_config" | sort -u)
	if ((${#kernel_paths[@]} != 1 || ${#initrd_paths[@]} != 1)); then
		printf 'Expected one kernel and one initrd path in the rescue GRUB configuration.\n' >&2
		exit 1
	fi
	kernel_path="${kernel_paths[0]}"
	initrd_path="${initrd_paths[0]}"
	test -f "$mount_root/payload/${kernel_path#/}"
	test -f "$mount_root/payload/${initrd_path#/}"

	install -d "$mount_root/efi/EFI/BOOT" "$mount_root/efi/EFI/TRACER"
	cp -a "$mount_root/payload/EFI/BOOT/." "$mount_root/efi/EFI/BOOT/"
	install -m 0644 "$mount_root/payload/${kernel_path#/}" "$mount_root/efi/EFI/TRACER/bzImage"
	install -m 0644 "$mount_root/payload/${initrd_path#/}" "$mount_root/efi/EFI/TRACER/initrd"
	: >"$mount_root/efi/EFI/tracer-rescue-loader"
	sed \
		-e 's#search --set=root --file /EFI/nixos-installer-image#search --set=root --file /EFI/tracer-rescue-loader#g' \
		-e "s#${kernel_path}#/EFI/TRACER/bzImage#g" \
		-e "s#${initrd_path}#/EFI/TRACER/initrd#g" \
		"$source_config" >"$target_config"
	# The ISO's BOOTX64.EFI embeds a bootstrap configuration that searches for
	# the ISO marker and can bypass the adjacent grub.cfg. Build our own
	# standalone loader so the FAT-resident kernel and initrd paths are the
	# configuration the firmware actually executes.
	grub-mkstandalone \
		--format=x86_64-efi \
		--output="$mount_root/efi/EFI/BOOT/BOOTX64.EFI" \
		--disable-shim-lock \
		--locales="" \
		--themes="" \
		--fonts="" \
		--modules="part_gpt part_msdos fat search search_fs_file normal linux gfxterm png all_video" \
		"boot/grub/grub.cfg=$target_config"
	install -m 0644 "$target_config" "$source_config"
	(
		cd "$(dirname "$target_config")"
		sha256sum "$(basename "$target_config")"
	) >"$mount_root/efi/EFI/TRACER/grub.cfg.sha256"

	test -s "$mount_root/efi/EFI/BOOT/BOOTX64.EFI"
	grep -Fq 'search --set=root --file /EFI/tracer-rescue-loader' "$target_config"
	grep -Fq 'linux /EFI/TRACER/bzImage ' "$target_config"
	grep -Fq 'initrd /EFI/TRACER/initrd' "$target_config"
	grep -Fq 'initrd /EFI/TRACER/initrd' "$source_config"
	cmp "$mount_root/payload/${kernel_path#/}" "$mount_root/efi/EFI/TRACER/bzImage"
	cmp "$mount_root/payload/${initrd_path#/}" "$mount_root/efi/EFI/TRACER/initrd"
}

usage() {
	cat <<'EOF'
Usage: sudo refresh-tracer-rescue \
  --device /dev/disk/by-id/... --expected-serial SERIAL

Refreshes only the immutable NixOS payload and UEFI loader on an existing
Tracer rescue drive. The temporary persistence partition is validated before
and after the refresh and is never mounted or reformatted.
EOF
}

while (($#)); do
	case "$1" in
		--device)
			device="${2:-}"
			shift 2
			;;
		--expected-serial)
			expected_serial="${2:-}"
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

[[ -n "$device" && -n "$expected_serial" ]] || {
	printf '%s\n' '--device and --expected-serial are required.' >&2
	exit 2
}

if ((EUID != 0)); then
	exec sudo --preserve-env=TRACER_RESCUE_ISO -- "$0" \
		--device "$device" --expected-serial "$expected_serial"
fi

device="$(readlink -f -- "$device")"
[[ -b "$device" && "$(lsblk -dnro TYPE "$device" | xargs)" == disk ]] || {
	printf 'Target is not a whole block device: %s\n' "$device" >&2
	exit 1
}

actual_serial="$(lsblk -dnro SERIAL "$device" | xargs)"
actual_model="$(lsblk -dnro MODEL "$device" | xargs)"
actual_size="$(lsblk -bdnro SIZE "$device" | xargs)"
actual_transport="$(lsblk -dnro TRAN "$device" | xargs)"
removable="$(lsblk -dnro RM "$device" | xargs)"
read_only="$(lsblk -dnro RO "$device" | xargs)"

[[ "$actual_serial" == "$expected_serial" ]] || {
	printf 'Serial mismatch: expected %s, found %s.\n' "$expected_serial" "$actual_serial" >&2
	exit 1
}
[[ "$actual_transport" == usb && "$removable" == 1 && "$read_only" == 0 ]] || {
	printf 'Refusing non-removable, non-USB, or read-only target: %s\n' "$device" >&2
	exit 1
}
((actual_size >= 120000000000 && actual_size <= 130000000000)) || {
	printf 'Target size is outside the expected 128 GB-class range: %s bytes\n' "$actual_size" >&2
	exit 1
}

root_source="$(findmnt -nro SOURCE /)"
root_source="${root_source%%\[*}"
root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n 1 | xargs)"
[[ -z "$root_parent" || "$device" != "/dev/$root_parent" ]] || {
	printf '%s\n' 'Refusing to modify the disk containing the running root filesystem.' >&2
	exit 1
}
if lsblk -nrpo MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
	printf 'Refusing to refresh a disk with mounted filesystems: %s\n' "$device" >&2
	exit 1
fi

partition_by_label() {
	lsblk -lnpo PATH,PARTLABEL "$device" |
		awk -v label="$1" '$2 == label { print $1; exit }'
}

efi_device="$(partition_by_label TRACER_RESCUE_EFI)"
payload_device="$(partition_by_label TRACER_RESCUE_SYSTEM)"
persist_device="$(partition_by_label TRACER_RESCUE_DATA)"
for partition in "$efi_device" "$payload_device" "$persist_device"; do
	[[ -b "$partition" && "$(lsblk -dnro PKNAME "$partition" | xargs)" == "$(basename "$device")" ]] || {
		printf 'Required rescue partition is missing or belongs to another disk: %s\n' "$partition" >&2
		exit 1
	}
done
[[ "$(lsblk -dnro FSTYPE "$persist_device" | xargs)" == btrfs ]] || {
	printf 'Persistence is not a Btrfs filesystem: %s\n' "$persist_device" >&2
	exit 1
}
persist_uuid="$(blkid -s UUID -o value "$persist_device")"

iso_root="${TRACER_RESCUE_ISO:?TRACER_RESCUE_ISO is not set by the packaged command}"
iso_file="$(find "$iso_root/iso" -maxdepth 1 -type f -name '*.iso' -print -quit)"
[[ -f "$iso_file" ]] || {
	printf 'Cannot locate the built Tracer rescue ISO below %s\n' "$iso_root" >&2
	exit 1
}

printf '\nValidated rescue-media refresh target:\n'
printf '  Device:       %s\n  Model:        %s\n  Serial:       %s\n' \
	"$device" "$actual_model" "$actual_serial"
printf '  EFI:          %s\n  System:       %s\n  Persistence:  %s (%s)\n' \
	"$efi_device" "$payload_device" "$persist_device" "$persist_uuid"
printf '  ISO:          %s\n' "$iso_file"
printf '\nThis replaces only the EFI and immutable system partitions on %s.\n' "$device"
printf '%s\n' 'Temporary persistence will not be mounted or reformatted.'
printf 'Type exactly: REFRESH TRACER RESCUE %s\n> ' "$actual_serial"
read -r confirmation
[[ "$confirmation" == "REFRESH TRACER RESCUE $actual_serial" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing was changed.' >&2
	exit 1
}

mount_root="$(mktemp -d /run/tracer-rescue-refresh.XXXXXXXX)"
cleanup() {
	set +e
	for mounted in "$mount_root/store" "$mount_root/efi" "$mount_root/payload"; do
		mountpoint -q "$mounted" && umount "$mounted"
	done
	[[ "$mount_root" == /run/tracer-rescue-refresh.* && -d "$mount_root" ]] && rm -r -- "$mount_root"
}
trap cleanup EXIT INT TERM
install -d "$mount_root"/{efi,payload,store}

wipefs --all "$payload_device"
mkfs.ext4 -F -L NIXOS_ISO "$payload_device"
mount -t ext4 "$payload_device" "$mount_root/payload"
xorriso -osirrox on -indev "$iso_file" -extract / "$mount_root/payload"
test -f "$mount_root/payload/EFI/BOOT/BOOTX64.EFI"
test -f "$mount_root/payload/EFI/nixos-installer-image"
test -f "$mount_root/payload/nix-store.squashfs"
mapfile -t boot_inits < <(grep -Eo 'init=/nix/store/[^[:space:]]+/init' \
	"$mount_root/payload/EFI/BOOT/grub.cfg" | sort -u)
if ((${#boot_inits[@]} != 1)); then
	printf 'Expected exactly one boot closure in the rescue GRUB configuration, found %s.\n' \
		"${#boot_inits[@]}" >&2
	exit 1
fi
boot_closure="${boot_inits[0]#init=}"
boot_closure="${boot_closure%/init}"
mount -o ro,loop "$mount_root/payload/nix-store.squashfs" "$mount_root/store"
test -x "$mount_root/store/${boot_closure#/nix/store/}/init" || {
	printf 'GRUB requests a closure missing from nix-store.squashfs: %s\n' "$boot_closure" >&2
	exit 1
}
umount "$mount_root/store"

mkfs.fat -F 32 -n RESCUE_EFI "$efi_device"
mount -t vfat "$efi_device" "$mount_root/efi"
install_efi_boot_payload
sync
umount "$mount_root/efi"
mount -t vfat -o ro "$efi_device" "$mount_root/efi"
test -s "$mount_root/efi/EFI/TRACER/bzImage"
test -s "$mount_root/efi/EFI/TRACER/initrd"
grep -Fq 'initrd /EFI/TRACER/initrd' "$mount_root/efi/EFI/BOOT/grub.cfg"
umount "$mount_root/efi"
umount "$mount_root/payload"

[[ "$(blkid -s UUID -o value "$persist_device")" == "$persist_uuid" ]] || {
	printf '%s\n' 'Persistence UUID changed unexpectedly; stop using this drive.' >&2
	exit 1
}

trap - EXIT INT TERM
rm -r -- "$mount_root"
printf '\nTracer rescue system refreshed on %s; persistence %s was preserved.\n' \
	"$device" "$persist_uuid"
printf 'TRACER_RESCUE_REFRESH_OK device=%s persistence=%s\n' "$device" "$persist_uuid"
