#!/usr/bin/env bash
set -euo pipefail

root_device=""
boot_device=""
efi_device=""
target_root="/mnt"
machine_manifest=""

usage() {
	cat <<'EOF'
Usage: sudo install-chev-desktop \
  --root-device /dev/... --boot-device /dev/... --efi-device /dev/... \
  --machine-manifest /path/to/machine-manifest.json

Formats only --root-device and --boot-device, creates the declared Btrfs
subvolumes, preserves the Windows EFI filesystem, and installs chev-desktop.
The EFI device must already contain the Microsoft Windows boot manager.

Options:
  --target-root PATH  Mount target (default: /mnt)
EOF
}

while (($#)); do
	case "$1" in
		--root-device)
			root_device="${2:-}"
			shift 2
			;;
		--boot-device)
			boot_device="${2:-}"
			shift 2
			;;
		--efi-device)
			efi_device="${2:-}"
			shift 2
			;;
		--target-root)
			target_root="${2:-}"
			shift 2
			;;
		--machine-manifest)
			machine_manifest="${2:-}"
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

if ((EUID != 0)); then
	sudo_arguments=(
		--root-device "$root_device"
		--boot-device "$boot_device"
		--efi-device "$efi_device"
		--target-root "$target_root"
		--machine-manifest "$machine_manifest"
	)
	exec sudo -- "$(command -v bash)" "$0" "${sudo_arguments[@]}"
fi

[[ -n "$root_device" && -n "$boot_device" && -n "$efi_device" && -n "$machine_manifest" ]] || {
	printf '%s\n' 'All device arguments and --machine-manifest are required.' >&2
	usage >&2
	exit 2
}

[[ -f "$machine_manifest" && ! -L "$machine_manifest" ]] || {
	printf 'Machine manifest is missing or is a symlink: %s\n' "$machine_manifest" >&2
	exit 1
}
machine_manifest="$(realpath "$machine_manifest")"
import_root="$(dirname "$machine_manifest")"
capsule_manifest="$import_root/manifest.json"
[[ "$(basename "$machine_manifest")" == "machine-manifest.json" && -f "$capsule_manifest" && ! -L "$capsule_manifest" ]] || {
	printf '%s\n' 'The machine manifest must be the verified machine-manifest.json payload in an imported capsule.' >&2
	exit 1
}
expected_machine_hash="$(jq -er '.files[] | select(.path == "machine-manifest.json") | .sha256' "$capsule_manifest")" || {
	printf '%s\n' 'The imported capsule does not declare machine-manifest.json.' >&2
	exit 1
}
actual_machine_hash="$(sha256sum "$machine_manifest" | awk '{print $1}')"
[[ "${actual_machine_hash,,}" == "${expected_machine_hash,,}" ]] || {
	printf '%s\n' 'The imported machine manifest no longer matches its capsule hash.' >&2
	exit 1
}

dotfiles_bundle="$import_root/dotfiles/repository.bundle"
[[ -f "$dotfiles_bundle" && ! -L "$dotfiles_bundle" ]] || {
	printf '%s\n' 'The verified capsule is missing its dotfiles Git bundle.' >&2
	exit 1
}
expected_bundle_hash="$(jq -er '.files[] | select(.path == "dotfiles/repository.bundle") | .sha256' "$capsule_manifest")" || {
	printf '%s\n' 'The dotfiles Git bundle is not declared by the imported capsule.' >&2
	exit 1
}
actual_bundle_hash="$(sha256sum "$dotfiles_bundle" | awk '{print $1}')"
[[ "${actual_bundle_hash,,}" == "${expected_bundle_hash,,}" ]] || {
	printf '%s\n' 'The dotfiles Git bundle no longer matches its capsule hash.' >&2
	exit 1
}
git bundle verify "$dotfiles_bundle" >/dev/null

sunshine_state="$import_root/sunshine/sunshine_state.json"
sunshine_cert="$import_root/sunshine/credentials/cacert.pem"
sunshine_key="$import_root/sunshine/credentials/cakey.pem"
for sunshine_file in "$sunshine_state" "$sunshine_cert" "$sunshine_key"; do
	[[ -f "$sunshine_file" && ! -L "$sunshine_file" ]] || {
		printf 'Required Sunshine migration payload is missing or unsafe: %s\n' "$sunshine_file" >&2
		exit 1
	}
	relative_sunshine_path="${sunshine_file#"$import_root"/}"
	expected_sunshine_hash="$(jq -er --arg path "$relative_sunshine_path" '.files[] | select(.path == $path) | .sha256' "$capsule_manifest")" || {
		printf 'Sunshine payload is not declared by the imported capsule: %s\n' "$relative_sunshine_path" >&2
		exit 1
	}
	actual_sunshine_hash="$(sha256sum "$sunshine_file" | awk '{print $1}')"
	[[ "${actual_sunshine_hash,,}" == "${expected_sunshine_hash,,}" ]] || {
		printf 'Sunshine payload hash mismatch: %s\n' "$relative_sunshine_path" >&2
		exit 1
	}
done

target_root="$(realpath -m "$target_root")"
case "$target_root" in
	/mnt | /mnt/*) ;;
	*)
		printf 'Target root must be /mnt or a directory below it: %s\n' "$target_root" >&2
		exit 1
		;;
esac

root_device="$(readlink -f "$root_device")"
boot_device="$(readlink -f "$boot_device")"
efi_device="$(readlink -f "$efi_device")"

declare -A selected_devices=()
for device in "$root_device" "$boot_device" "$efi_device"; do
	[[ -b "$device" ]] || {
		printf 'Not a block device: %s\n' "$device" >&2
		exit 1
	}
	[[ "$(lsblk --noheadings --output TYPE "$device" | xargs)" == "part" ]] || {
		printf 'Expected a partition, not a whole disk: %s\n' "$device" >&2
		exit 1
	}
	device_number="$(lsblk --noheadings --output MAJ:MIN "$device" | head -n 1 | xargs)"
	[[ -n "$device_number" && -z "${selected_devices[$device_number]:-}" ]] || {
		printf 'The same partition was selected more than once (device %s).\n' "$device_number" >&2
		exit 1
	}
	selected_devices["$device_number"]="$device"
done

for device in "$root_device" "$boot_device" "$efi_device"; do
	if findmnt --noheadings --source "$device" >/dev/null 2>&1; then
		printf 'Refusing to operate on a mounted partition: %s\n' "$device" >&2
		exit 1
	fi
done

root_type="$(blkid -o value -s TYPE "$root_device" 2>/dev/null || true)"
root_label="$(blkid -o value -s LABEL "$root_device" 2>/dev/null || true)"
if [[ -n "$root_type" ]] && [[ "$root_type" != "btrfs" || "$root_label" != "NIXROOT" ]]; then
	printf 'Root partition already contains %s (%s); refusing to format it.\n' "$root_type" "$root_label" >&2
	exit 1
fi

boot_type="$(blkid -o value -s TYPE "$boot_device" 2>/dev/null || true)"
boot_label="$(blkid -o value -s LABEL "$boot_device" 2>/dev/null || true)"
case "${boot_type,,}:$boot_label" in
	: | vfat:NIXBOOT | fat:NIXBOOT | fat32:NIXBOOT) ;;
	*)
		printf 'XBOOTLDR partition already contains %s (%s); refusing to format it.\n' "$boot_type" "$boot_label" >&2
		exit 1
		;;
esac

root_size="$(blockdev --getsize64 "$root_device")"
boot_size="$(blockdev --getsize64 "$boot_device")"
((root_size >= 80 * 1024 * 1024 * 1024)) || {
	printf 'Root partition is smaller than the 80 GiB safety minimum: %s\n' "$root_device" >&2
	exit 1
}
((boot_size >= 1024 * 1024 * 1024)) || {
	printf 'XBOOTLDR partition is smaller than 1 GiB: %s\n' "$boot_device" >&2
	exit 1
}

root_parent="$(lsblk --noheadings --output PKNAME "$root_device" | xargs)"
boot_parent="$(lsblk --noheadings --output PKNAME "$boot_device" | xargs)"
efi_parent="$(lsblk --noheadings --output PKNAME "$efi_device" | xargs)"
[[ -n "$root_parent" && "$root_parent" == "$boot_parent" && "$root_parent" == "$efi_parent" ]] || {
	printf '%s\n' 'All target partitions must be on the same physical disk.' >&2
	exit 1
}
target_disk="/dev/$root_parent"
target_disk="$(readlink -f "$target_disk")"

validate-machine-manifest \
	--manifest "$machine_manifest" \
	--disk "$target_disk" \
	--efi-device "$efi_device" \
	--boot-device "$boot_device" \
	--root-device "$root_device"

efi_type="$(blkid -o value -s TYPE "$efi_device" 2>/dev/null || true)"
case "${efi_type,,}" in
	vfat | fat | fat32) ;;
	*)
		printf 'EFI partition is not FAT: %s (%s)\n' "$efi_device" "$efi_type" >&2
		exit 1
		;;
esac

if ! fsck.fat -n "$efi_device"; then
	printf '%s\n' 'The Windows EFI filesystem is dirty or inconsistent; repair it in Windows before installing.' >&2
	exit 1
fi

efi_probe="$(mktemp -d)"
cleanup_probe() {
	umount "$efi_probe" >/dev/null 2>&1 || true
	rmdir "$efi_probe" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT
mount -o ro,nosuid,nodev,noexec "$efi_device" "$efi_probe"
[[ -f "$efi_probe/EFI/Microsoft/Boot/bootmgfw.efi" ]] || {
	printf 'Windows Boot Manager not found on %s; refusing installation.\n' "$efi_device" >&2
	exit 1
}
microsoft_loader_hash="$(sha256sum "$efi_probe/EFI/Microsoft/Boot/bootmgfw.efi" | awk '{print $1}')"
cleanup_probe
trap - EXIT

printf '%s\n' 'Installation plan:'
lsblk --output NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$root_device" "$boot_device" "$efi_device"
printf '\nWILL FORMAT: %s as Btrfs NIXROOT\n' "$root_device"
printf 'WILL FORMAT: %s as FAT32 XBOOTLDR NIXBOOT\n' "$boot_device"
printf 'WILL NOT FORMAT OR RELABEL: %s; preserve Windows files, add NixOS loader files, restore original fallback\n' "$efi_device"
printf '\nType the exact root device path (%s) to continue: ' "$root_device"
IFS= read -r confirmation
[[ "$confirmation" == "$root_device" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing changed.' >&2
	exit 1
}

mkfs.btrfs --force --label NIXROOT "$root_device"
mkfs.fat -F 32 -n NIXBOOT "$boot_device"

mkdir -p "$target_root"
installation_source=""
cleanup_target() {
	if [[ -n "$installation_source" && "$installation_source" == /tmp/chev-desktop-source.* ]]; then
		rm -rf -- "$installation_source"
	fi
	for mount_path in "$target_root/efi" "$target_root/boot" "$target_root/swap" "$target_root/nix" "$target_root/home" "$target_root"; do
		umount "$mount_path" >/dev/null 2>&1 || true
	done
}
trap cleanup_target EXIT

mount "$root_device" "$target_root"
for subvolume in @root @home @nix @swap; do
	btrfs subvolume create "$target_root/$subvolume"
done
umount "$target_root"

mount -o compress=zstd,noatime,subvol=@root "$root_device" "$target_root"
mkdir -p "$target_root"/{boot,efi,home,nix,swap}
mount -o compress=zstd,noatime,subvol=@home "$root_device" "$target_root/home"
mount -o compress=zstd,noatime,subvol=@nix "$root_device" "$target_root/nix"
mount -o noatime,subvol=@swap "$root_device" "$target_root/swap"
mount "$boot_device" "$target_root/boot"
mount "$efi_device" "$target_root/efi"

# Do not place these records under EFI/nixos: FAT is case-insensitive and the
# NixOS bootloader owns and may replace that directory during installation.
fallback_backup="$target_root/efi/EFI/WindowsFallbackBackup/windows-fallback-original.efi"
fallback_absent="$target_root/efi/EFI/WindowsFallbackBackup/windows-fallback-original.absent"
fallback_target="$target_root/efi/EFI/BOOT/BOOTX64.EFI"
expected_fallback_present="$(jq -r '.windowsBoot.fallbackPresent' "$machine_manifest")"
expected_fallback_hash="$(jq -r '.windowsBoot.fallbackSha256 // empty' "$machine_manifest")"
if [[ -e "$fallback_backup" && -e "$fallback_absent" ]]; then
	printf '%s\n' 'Conflicting Windows EFI fallback records already exist; refusing to continue.' >&2
	exit 1
elif [[ -e "$fallback_backup" ]]; then
	[[ "$expected_fallback_present" == "true" ]] || {
		printf '%s\n' 'Unexpected fallback backup exists for a manifest that recorded no fallback.' >&2
		exit 1
	}
	[[ "$(sha256sum "$fallback_backup" | awk '{print $1}')" == "$expected_fallback_hash" ]] || {
		printf '%s\n' 'Existing Windows fallback backup does not match the authoritative manifest.' >&2
		exit 1
	}
elif [[ -e "$fallback_absent" ]]; then
	[[ "$expected_fallback_present" == "false" ]] || {
		printf '%s\n' 'Fallback-absent record conflicts with the authoritative manifest.' >&2
		exit 1
	}
elif [[ ! -e "$fallback_backup" && ! -e "$fallback_absent" ]]; then
	install -d -m 0700 "$(dirname "$fallback_backup")"
	if [[ "$expected_fallback_present" == "true" && -f "$fallback_target" ]]; then
		[[ "$(sha256sum "$fallback_target" | awk '{print $1}')" == "$expected_fallback_hash" ]] || {
			printf '%s\n' 'Current Windows fallback loader does not match the authoritative manifest.' >&2
			exit 1
		}
		install -m 0600 "$fallback_target" "$fallback_backup"
	elif [[ "$expected_fallback_present" == "false" && ! -e "$fallback_target" ]]; then
		install -m 0600 /dev/null "$fallback_absent"
	else
		printf '%s\n' 'Current Windows fallback presence conflicts with the authoritative manifest.' >&2
		exit 1
	fi
fi

dotfiles_source="${CHEV_DOTFILES_SOURCE:?installer did not provide CHEV_DOTFILES_SOURCE}"
installation_source="$(mktemp -d /tmp/chev-desktop-source.XXXXXXXX)"
rsync -a --chmod=Du+w,Fu+w "$dotfiles_source/" "$installation_source/"
efi_partuuid="$(jq -r '.partitions.windowsEsp.partuuid' "$machine_manifest")"
cat >"$installation_source/hosts/chev-desktop/hardware-generated.nix" <<EOF
{
  dotfiles.desktop.efiPartuuid = "$efi_partuuid";
}
EOF

nixos-install \
	--root "$target_root" \
	--flake "path:$installation_source#chev-desktop" \
	--no-root-password

[[ "$(sha256sum "$target_root/efi/EFI/Microsoft/Boot/bootmgfw.efi" | awk '{print $1}')" == "$microsoft_loader_hash" ]] || {
	printf '%s\n' 'Microsoft Boot Manager changed unexpectedly during installation.' >&2
	exit 1
}
if [[ -f "$fallback_backup" ]]; then
	cmp -s "$fallback_backup" "$fallback_target" || {
		printf '%s\n' 'The original Windows fallback loader was not restored after systemd-boot installation.' >&2
		exit 1
	}
elif [[ -f "$fallback_absent" && -e "$fallback_target" ]]; then
	printf '%s\n' 'A fallback loader was left behind even though none existed before installation.' >&2
	exit 1
fi

install -d -m 0755 -o 1000 -g 100 "$target_root/home/alex"
git clone --quiet "$dotfiles_bundle" "$target_root/home/alex/.dotfiles"
install -m 0644 \
	"$installation_source/hosts/chev-desktop/hardware-generated.nix" \
	"$target_root/home/alex/.dotfiles/hosts/chev-desktop/hardware-generated.nix"
chown -R 1000:100 "$target_root/home/alex/.dotfiles"

sunshine_target="$target_root/home/alex/.config/sunshine"
install -d -m 0700 -o 1000 -g 100 "$target_root/home/alex/.config" "$sunshine_target" "$sunshine_target/credentials"
install -m 0600 -o 1000 -g 100 "$sunshine_state" "$sunshine_target/sunshine_state.json"
install -m 0600 -o 1000 -g 100 "$sunshine_cert" "$sunshine_target/credentials/cacert.pem"
install -m 0600 -o 1000 -g 100 "$sunshine_key" "$sunshine_target/credentials/cakey.pem"

thread_id="$(jq -r '.threadId' "$capsule_manifest")"
mapfile -d '' codex_databases < <(find "$import_root/codex/sqlite" -maxdepth 1 -type f -name 'state_*.sqlite' -print0)
mapfile -d '' codex_rollouts < <(find "$import_root/codex" -type f -name 'rollout-*.jsonl' -print0)
((${#codex_databases[@]} == 1)) || {
	printf '%s\n' 'Imported capsule does not have exactly one Codex state database.' >&2
	exit 1
}
matched_rollout=""
for rollout in "${codex_rollouts[@]}"; do
	if grep -F -q -- "$thread_id" "$rollout"; then
		[[ -z "$matched_rollout" ]] || {
			printf '%s\n' 'More than one imported rollout contains the migration thread.' >&2
			exit 1
		}
		matched_rollout="$rollout"
	fi
done
[[ -n "$matched_rollout" ]] || {
	printf '%s\n' 'The imported Codex rollout for the migration thread is missing.' >&2
	exit 1
}

codex_target="$target_root/home/alex/.codex"
rollout_relative="${matched_rollout#"$import_root/codex/"}"
rollout_target="$codex_target/$rollout_relative"
database_target="$codex_target/sqlite/$(basename "${codex_databases[0]}")"
install -d -m 0700 -o 1000 -g 100 "$codex_target" "$codex_target/sqlite" "$(dirname "$rollout_target")"
install -m 0600 -o 1000 -g 100 "$import_root/codex/auth.json" "$codex_target/auth.json"
install -m 0600 -o 1000 -g 100 "$import_root/codex/config.toml" "$codex_target/config.toml"
if [[ -f "$import_root/codex/history.jsonl" ]]; then
	install -m 0600 -o 1000 -g 100 "$import_root/codex/history.jsonl" "$codex_target/history.jsonl"
fi

python3 - \
	"${codex_databases[0]}" \
	"$database_target" \
	"$matched_rollout" \
	"$rollout_target" \
	"$thread_id" \
	"/home/alex/.codex/$rollout_relative" <<'PY'
import json
import pathlib
import sqlite3
import sys
import time

source_database = pathlib.Path(sys.argv[1])
target_database = pathlib.Path(sys.argv[2])
source_rollout = pathlib.Path(sys.argv[3])
target_rollout = pathlib.Path(sys.argv[4])
thread_id = sys.argv[5]
native_rollout_path = sys.argv[6]

with sqlite3.connect(f"file:{source_database}?mode=ro", uri=True) as source:
	with sqlite3.connect(target_database) as target:
		source.backup(target)
		rows = target.execute(
			"SELECT id FROM threads WHERE id = ?", (thread_id,)
		).fetchall()
		if len(rows) != 1:
			raise SystemExit(f"expected one target state row, found {len(rows)}")
		# The capsule intentionally carries only the authoritative migration
		# rollout. Remove metadata for older threads whose rollout files are not
		# present so the native Codex state is internally consistent.
		tables = {
			row[0]
			for row in target.execute(
				"SELECT name FROM sqlite_master WHERE type = 'table'"
			)
		}
		if "thread_spawn_edges" in tables:
			target.execute(
				"DELETE FROM thread_spawn_edges "
				"WHERE parent_thread_id != ? OR child_thread_id != ?",
				(thread_id, thread_id),
			)
		if "thread_dynamic_tools" in tables:
			target.execute(
				"DELETE FROM thread_dynamic_tools WHERE thread_id != ?",
				(thread_id,),
			)
		target.execute("DELETE FROM threads WHERE id != ?", (thread_id,))
		target.execute(
			"UPDATE threads SET rollout_path = ? WHERE id = ?",
			(native_rollout_path, thread_id),
		)
		target.commit()
		if target.execute("PRAGMA integrity_check").fetchone() != ("ok",):
			raise SystemExit("target Codex database failed integrity_check")

for attempt in range(30):
	before = source_rollout.stat().st_size
	data = source_rollout.read_bytes()
	after = source_rollout.stat().st_size
	if before == after == len(data) and data.endswith(b"\n"):
		try:
			for line in data.splitlines():
				json.loads(line)
		except json.JSONDecodeError:
			pass
		else:
			target_rollout.write_bytes(data)
			break
	time.sleep(0.1)
else:
	raise SystemExit("could not take a stable complete-line rollout snapshot")
PY
chown -R 1000:100 "$codex_target"
find "$codex_target" -type d -exec chmod 0700 {} +
find "$codex_target" -type f -exec chmod 0600 {} +

nixos-enter --root "$target_root" -c \
	'runuser --user alex -- env HOME=/home/alex CODEX_HOME=/home/alex/.codex CODEX_SQLITE_HOME=/home/alex/.codex/sqlite codex login status'
nixos-enter --root "$target_root" -c \
	'runuser --user alex -- env HOME=/home/alex CODEX_HOME=/home/alex/.codex CODEX_SQLITE_HOME=/home/alex/.codex/sqlite codex doctor --summary --no-color'

if [[ -n "${CHEV_INITIAL_PASSWORD_FILE:-}" ]]; then
	password_file="$(realpath -e -- "$CHEV_INITIAL_PASSWORD_FILE" 2>/dev/null || true)"
	[[ -n "$password_file" && -f "$password_file" && ! -L "$password_file" ]] || {
		printf '%s\n' 'CHEV_INITIAL_PASSWORD_FILE must name a safe regular file.' >&2
		exit 1
	}
	password_mode="$(stat -c '%a' "$password_file")"
	[[ "$password_mode" == "600" ]] || {
		printf 'CHEV_INITIAL_PASSWORD_FILE must have mode 0600, not %s.\n' "$password_mode" >&2
		exit 1
	}
	IFS= read -r initial_password <"$password_file"
	[[ ${#initial_password} -ge 20 && "$initial_password" != *:* ]] || {
		printf '%s\n' 'Generated initial password failed the local length/format guard.' >&2
		exit 1
	}
	printf 'alex:%s\n' "$initial_password" | nixos-enter --root "$target_root" -c chpasswd
	initial_password=""
	printf '%s\n' 'Installed the generated initial password for alex from the protected local file.'
else
	printf '%s\n' 'Set the initial password for alex:'
	nixos-enter --root "$target_root" -c 'passwd alex'
fi

printf '\nNixOS is installed; unmounting the target filesystems at %s.\n' "$target_root"
printf '%s\n' 'Do not wipe D: yet. Verify Windows Boot Manager and NixOS from firmware first.'
printf '%s\n' 'This command intentionally does not reboot.'
cleanup_target
trap - EXIT
printf '%s\n' 'Target filesystems are unmounted.'
