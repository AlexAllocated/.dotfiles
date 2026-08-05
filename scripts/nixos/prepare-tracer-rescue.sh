#!/usr/bin/env bash
set -euo pipefail

device=""
expected_serial=""
thread_id=""
source_home="${SUDO_USER:+/home/$SUDO_USER}"
source_home="${source_home:-$HOME}"
include_paths=()
include_repos=()

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
Usage: sudo prepare-tracer-rescue \
  --device /dev/disk/by-id/... --expected-serial SERIAL --thread-id UUID \
  [--source-home /home/alex] [--include-path PATH ...] [--include-repo PATH ...]

ERASES exactly one validated removable USB disk and creates:
  1. A 1 GiB removable-path UEFI boot partition
  2. A 16 GiB immutable NixOS payload partition
  3. LUKS2-encrypted Btrfs persistence using the remaining space

The command snapshots the selected Codex thread and dotfiles before displaying
the final destructive confirmation. Additional --include-path values are copied
under /home/alx/migration-files. --include-repo creates a Git-aware checkout
under /home/alx/code without copying ignored dependencies or build caches.
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
		--thread-id)
			thread_id="${2:-}"
			shift 2
			;;
		--source-home)
			source_home="${2:-}"
			shift 2
			;;
		--include-path)
			include_paths+=("${2:-}")
			shift 2
			;;
		--include-repo)
			include_repos+=("${2:-}")
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

[[ -n "$device" && -n "$expected_serial" && -n "$thread_id" ]] || {
	printf '%s\n' '--device, --expected-serial, and --thread-id are required.' >&2
	exit 2
}
[[ "$thread_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
	printf '%s\n' '--thread-id must be a UUID.' >&2
	exit 2
}

if ((EUID != 0)); then
	arguments=(
		--device "$device"
		--expected-serial "$expected_serial"
		--thread-id "$thread_id"
		--source-home "$source_home"
	)
	for path in "${include_paths[@]}"; do
		arguments+=(--include-path "$path")
	done
	for path in "${include_repos[@]}"; do
		arguments+=(--include-repo "$path")
	done
	exec sudo --preserve-env=TRACER_RESCUE_ISO,TRACER_DOTFILES_SOURCE -- "$0" "${arguments[@]}"
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
	printf '%s\n' 'Refusing to erase the disk containing the running root filesystem.' >&2
	exit 1
}
if lsblk -nrpo MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
	printf 'Refusing to erase a disk with mounted filesystems: %s\n' "$device" >&2
	exit 1
fi

iso_root="${TRACER_RESCUE_ISO:?TRACER_RESCUE_ISO is not set by the packaged command}"
dotfiles_source="${TRACER_DOTFILES_SOURCE:?TRACER_DOTFILES_SOURCE is not set by the packaged command}"
iso_file="$(find "$iso_root/iso" -maxdepth 1 -type f -name '*.iso' -print -quit)"
[[ -f "$iso_file" ]] || {
	printf 'Cannot locate the built Tracer rescue ISO below %s\n' "$iso_root" >&2
	exit 1
}
[[ -d "$source_home/.codex" && -d "$source_home/.dotfiles/.git" ]] || {
	printf 'Source home lacks .codex or the dotfiles checkout: %s\n' "$source_home" >&2
	exit 1
}

staging="$(mktemp -d /dev/shm/tracer-rescue-seed.XXXXXXXX)"
mount_root="$(mktemp -d /run/tracer-rescue-media.XXXXXXXX)"
mapper="tracer-rescue-persist-$$"
cleanup() {
	set +e
	for mounted in "$mount_root/store" "$mount_root/home" "$mount_root/state" "$mount_root/payload" "$mount_root/efi" "$mount_root/persist"; do
		mountpoint -q "$mounted" && umount "$mounted"
	done
	cryptsetup status "$mapper" >/dev/null 2>&1 && cryptsetup close "$mapper"
	[[ "$staging" == /dev/shm/tracer-rescue-seed.* && -d "$staging" ]] && rm -r -- "$staging"
	[[ "$mount_root" == /run/tracer-rescue-media.* && -d "$mount_root" ]] && rm -r -- "$mount_root"
}
trap cleanup EXIT INT TERM

install -d -m 0700 "$staging/home"
python3 "$dotfiles_source/scripts/nixos/seed-tracer-codex.py" \
	--thread-id "$thread_id" \
	--source "$source_home/.codex" \
	--destination "$staging/home/.codex"
rsync -a --exclude=result --exclude='result-*' \
	"$source_home/.dotfiles/" "$staging/home/.dotfiles/"

for relative in .config/sunshine .config/obs-studio .ssh/authorized_keys; do
	if [[ -e "$source_home/$relative" && ! -L "$source_home/$relative" ]]; then
		install -d -m 0700 "$staging/home/$(dirname "$relative")"
		rsync -a "$source_home/$relative" "$staging/home/$(dirname "$relative")/"
	fi
done
for path in "${include_paths[@]}"; do
	resolved="$(realpath -e -- "$path")"
	[[ "$resolved" == "$source_home"/* && ! -L "$resolved" ]] || {
		printf 'Additional path must be a non-symlink below %s: %s\n' "$source_home" "$path" >&2
		exit 1
	}
	install -d -m 0700 "$staging/home/migration-files"
	rsync -a "$resolved" "$staging/home/migration-files/"
done
for repo in "${include_repos[@]}"; do
	resolved="$(realpath -e -- "$repo")"
	[[ "$resolved" == "$source_home"/* && -d "$resolved/.git" && ! -L "$resolved" ]] || {
		printf 'Additional repository must be a non-symlink checkout below %s: %s\n' "$source_home" "$repo" >&2
		exit 1
	}
	repo_name="$(basename "$resolved")"
	destination="$staging/home/code/$repo_name"
	[[ ! -e "$destination" ]] || {
		printf 'Repository destination collides with another seed: %s\n' "$destination" >&2
		exit 1
	}
	install -d -m 0755 "$staging/home/code"
	git clone --quiet --no-hardlinks --local "$resolved" "$destination"
	git -C "$resolved" ls-files -z --cached --others --exclude-standard |
		rsync -a --from0 --files-from=- --ignore-missing-args "$resolved/" "$destination/"
	while IFS= read -r -d '' deleted; do
		case "$deleted" in
			/* | ../* | */../* | */..)
				printf 'Unsafe deleted Git path: %s\n' "$deleted" >&2
				exit 1
				;;
		esac
		rm -f -- "$destination/$deleted"
	done < <(git -C "$resolved" ls-files -z --deleted)
	diff -ruN \
		<(git -C "$resolved" status --porcelain=v1) \
		<(git -C "$destination" status --porcelain=v1) >/dev/null || {
		printf 'Seeded repository status does not match its source: %s\n' "$resolved" >&2
		exit 1
	}
done

printf '\nValidated rescue-media target:\n'
printf '  Device:    %s\n  Model:     %s\n  Serial:    %s\n  Size:      %s bytes\n' \
	"$device" "$actual_model" "$actual_serial" "$actual_size"
printf '  ISO:       %s\n  Thread:    %s\n' "$iso_file" "$thread_id"
printf '\nThis erases every existing partition and byte of filesystem metadata on %s.\n' "$device"
printf 'Type exactly: ERASE TRACER RESCUE %s\n> ' "$actual_serial"
read -r confirmation
[[ "$confirmation" == "ERASE TRACER RESCUE $actual_serial" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing was changed.' >&2
	exit 1
}

sgdisk --zap-all "$device"
sgdisk \
	--new=1:0:+1G --typecode=1:ef00 --change-name=1:TRACER_RESCUE_EFI \
	--new=2:0:+16G --typecode=2:8300 --change-name=2:TRACER_RESCUE_SYSTEM \
	--new=3:0:0 --typecode=3:8309 --change-name=3:TRACER_RESCUE_CRYPT \
	"$device"
partprobe "$device"
udevadm settle

efi_device="$(readlink -f /dev/disk/by-partlabel/TRACER_RESCUE_EFI)"
payload_device="$(readlink -f /dev/disk/by-partlabel/TRACER_RESCUE_SYSTEM)"
persist_device="$(readlink -f /dev/disk/by-partlabel/TRACER_RESCUE_CRYPT)"
for partition in "$efi_device" "$payload_device" "$persist_device"; do
	[[ -b "$partition" && "$(lsblk -dnro PKNAME "$partition" | xargs)" == "$(basename "$device")" ]] || {
		printf 'Resolved partition does not belong to %s: %s\n' "$device" "$partition" >&2
		exit 1
	}
done

mkfs.fat -F 32 -n RESCUE_EFI "$efi_device"
wipefs --all "$payload_device"
mkfs.ext4 -F -L NIXOS_ISO "$payload_device"
printf '\nChoose the portable LUKS passphrase for Tracer rescue persistence.\n'
cryptsetup luksFormat --type luks2 "$persist_device"
cryptsetup open "$persist_device" "$mapper"
mkfs.btrfs --force --label TRACER_RESCUE_PERSIST "/dev/mapper/$mapper"

install -d "$mount_root"/{efi,payload,store,persist,home,state}
mount "$efi_device" "$mount_root/efi"
mount "$payload_device" "$mount_root/payload"
xorriso -osirrox on -indev "$iso_file" -extract / "$mount_root/payload"
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
install_efi_boot_payload
test -f "$mount_root/payload/EFI/nixos-installer-image"
test -f "$mount_root/payload/nix-store.squashfs"
sync -f "$mount_root/efi/EFI/BOOT/BOOTX64.EFI"
sync
umount "$mount_root/efi"
mount -o ro "$efi_device" "$mount_root/efi"
test -s "$mount_root/efi/EFI/TRACER/bzImage"
test -s "$mount_root/efi/EFI/TRACER/initrd"
grep -Fq 'initrd /EFI/TRACER/initrd' "$mount_root/efi/EFI/BOOT/grub.cfg"
umount "$mount_root/efi"
umount "$mount_root/payload"

mount "/dev/mapper/$mapper" "$mount_root/persist"
for subvolume in @home @state @networkmanager @network-connections; do
	btrfs subvolume create "$mount_root/persist/$subvolume"
done
umount "$mount_root/persist"
mount -o subvol=@home,compress=zstd:3,noatime "/dev/mapper/$mapper" "$mount_root/home"
mount -o subvol=@state,compress=zstd:3,noatime "/dev/mapper/$mapper" "$mount_root/state"
install -d -m 0755 "$mount_root/home/alx"
rsync -a "$staging/home/" "$mount_root/home/alx/"
install -d -m 0700 "$mount_root/state/ssh" "$mount_root/state/migration"
jq -n \
	--arg threadId "$thread_id" \
	--arg sourceHost "$(hostname)" \
	--arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{schemaVersion: 1, kind: "tracer-rescue-persistence", $threadId, $sourceHost, $createdAt}' \
	>"$mount_root/state/migration/manifest.json"
chown -R 1000:100 "$mount_root/home/alx"
chmod 0700 "$mount_root/home/alx/.codex"
sync
umount "$mount_root/home"
umount "$mount_root/state"
cryptsetup close "$mapper"

trap - EXIT INT TERM
rm -r -- "$staging" "$mount_root"
printf '\nTracer rescue media is ready on %s (%s).\n' "$device" "$actual_serial"
printf '%s\n' 'Before relying on it, boot it with Secure Boot disabled and run tracer-diagnostics.'
