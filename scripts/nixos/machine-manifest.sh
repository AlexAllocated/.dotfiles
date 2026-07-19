#!/usr/bin/env bash
set -euo pipefail

command_name="$(basename "$0")"
mode=""
manifest=""
output=""
disk=""
efi_device=""
boot_device=""
root_device=""

case "$command_name" in
	export-machine-manifest) mode="export" ;;
	validate-machine-manifest) mode="validate" ;;
	*)
		mode="${1:-}"
		shift || true
		;;
esac

usage() {
	cat <<'EOF'
Usage:
  export-machine-manifest --manifest WINDOWS_MANIFEST --disk /dev/... \
    --efi-device /dev/... --boot-device /dev/... --root-device /dev/... \
    --output FILE
  validate-machine-manifest --manifest FILE --disk /dev/... \
    --efi-device /dev/... --boot-device /dev/... --root-device /dev/...

Both commands read device identity and geometry without modifying any disk and
require an exact match with the authoritative manifest created in Windows.
Export writes the matching Linux observation to a new file; it cannot create a
new authoritative machine identity from arbitrary command-line targets.
EOF
}

while (($#)); do
	case "$1" in
		--manifest)
			manifest="${2:-}"
			shift 2
			;;
		--output)
			output="${2:-}"
			shift 2
			;;
		--disk)
			disk="${2:-}"
			shift 2
			;;
		--efi-device)
			efi_device="${2:-}"
			shift 2
			;;
		--boot-device)
			boot_device="${2:-}"
			shift 2
			;;
		--root-device)
			root_device="${2:-}"
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

case "$mode" in
	export | validate) ;;
	*)
		usage >&2
		exit 2
		;;
esac

[[ -n "$disk" && -n "$efi_device" && -n "$boot_device" && -n "$root_device" ]] || {
	printf '%s\n' 'Disk and all three partition arguments are required.' >&2
	exit 2
}

[[ -b "$disk" && "$(lsblk --noheadings --nodeps --output TYPE "$disk" | xargs)" == "disk" ]] || {
	printf 'Not a whole-disk block device: %s\n' "$disk" >&2
	exit 1
}
for partition in "$efi_device" "$boot_device" "$root_device"; do
	[[ -b "$partition" && "$(lsblk --noheadings --nodeps --output TYPE "$partition" | xargs)" == "part" ]] || {
		printf 'Not a partition block device: %s\n' "$partition" >&2
		exit 1
	}
	parent="$(lsblk --noheadings --output PKNAME "$partition" | xargs)"
	[[ "/dev/$parent" -ef "$disk" ]] || {
		printf 'Partition %s is not on %s.\n' "$partition" "$disk" >&2
		exit 1
	}
done

trim() {
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

normalise_serial() {
	tr '[:lower:]' '[:upper:]' | tr -d '._:[:space:]-'
}

normalise_model() {
	trim | sed -E 's/^WDC[[:space:]]+//I'
}

nullable_json_string() {
	local value="$1"
	if [[ -n "$value" ]]; then
		jq -Rn --arg value "$value" '$value'
	else
		printf '%s\n' null
	fi
}

partition_json() {
	local role="$1"
	local partition="$2"
	local intended_mount="$3"
	local partuuid part_type start_sector sector_count end_sector byte_size fs_type fs_label
	partuuid="$(blkid -o value -s PARTUUID "$partition" | trim | tr '[:upper:]' '[:lower:]')"
	part_type="$(lsblk --noheadings --output PARTTYPE "$partition" | trim | tr '[:upper:]' '[:lower:]')"
	start_sector="$(lsblk --noheadings --output START "$partition" | xargs)"
	sector_count="$(blockdev --getsz "$partition")"
	end_sector=$((start_sector + sector_count - 1))
	byte_size="$(blockdev --getsize64 "$partition")"
	fs_type="$(blkid -o value -s TYPE "$partition" 2>/dev/null | trim || true)"
	fs_label="$(blkid -o value -s LABEL "$partition" 2>/dev/null | trim || true)"

	jq -n \
		--arg role "$role" \
		--arg partuuid "$partuuid" \
		--arg gptType "$part_type" \
		--argjson startSector "$start_sector" \
		--argjson endSector "$end_sector" \
		--argjson sectorCount "$sector_count" \
		--argjson byteSize "$byte_size" \
		--argjson fsType "$(nullable_json_string "$fs_type")" \
		--argjson fsLabel "$(nullable_json_string "$fs_label")" \
		--arg intendedMount "$intended_mount" \
		'{
			role: $role,
			partuuid: $partuuid,
			gptType: $gptType,
			startSector: $startSector,
			endSector: $endSector,
			sectorCount: $sectorCount,
			byteSize: $byteSize,
			fsType: $fsType,
			fsLabel: $fsLabel,
			intendedMount: $intendedMount
		}'
}

capture_manifest() {
	local model serial unique_id gpt_guid logical_sector_size byte_size sector_count
	model="$(lsblk --noheadings --nodeps --output MODEL "$disk" | normalise_model)"
	serial="$(lsblk --noheadings --nodeps --output SERIAL "$disk" | trim | normalise_serial)"
	unique_id="$(lsblk --noheadings --nodeps --output WWN "$disk" | trim | tr '[:upper:]' '[:lower:]')"
	gpt_guid="$(blkid -o value -s PTUUID "$disk" | trim | tr '[:upper:]' '[:lower:]')"
	logical_sector_size="$(blockdev --getss "$disk")"
	byte_size="$(blockdev --getsize64 "$disk")"
	sector_count="$(blockdev --getsz "$disk")"

	jq -n \
		--arg model "$model" \
		--arg normalizedSerial "$serial" \
		--argjson platformUniqueId "$(nullable_json_string "$unique_id")" \
		--arg gptDiskGuid "$gpt_guid" \
		--argjson logicalSectorSize "$logical_sector_size" \
		--argjson byteSize "$byte_size" \
		--argjson sectorCount "$sector_count" \
		--arg microsoftLoaderSha256 "$windows_microsoft_loader_hash" \
		--argjson fallbackPresent "$windows_fallback_present" \
		--argjson fallbackSha256 "$(nullable_json_string "$windows_fallback_hash")" \
		--argjson windowsEsp "$(partition_json windows-esp "$efi_device" /efi)" \
		--argjson xbootldr "$(partition_json xbootldr "$boot_device" /boot)" \
		--argjson nixRoot "$(partition_json nix-root "$root_device" /)" \
		'{
			schemaVersion: 1,
			kind: "chev-desktop-machine",
			modelNormalization: "trim; remove leading WDC vendor token only",
			serialNormalization: "uppercase; remove period underscore colon hyphen and ASCII whitespace only",
			systemDisk: {
				model: $model,
				normalizedSerial: $normalizedSerial,
				platformUniqueId: $platformUniqueId,
				gptDiskGuid: $gptDiskGuid,
				logicalSectorSize: $logicalSectorSize,
				byteSize: $byteSize,
				sectorCount: $sectorCount
			},
			windowsBoot: {
				microsoftLoaderSha256: $microsoftLoaderSha256,
				fallbackPresent: $fallbackPresent,
				fallbackSha256: $fallbackSha256
			},
			partitions: {
				windowsEsp: $windowsEsp,
				xbootldr: $xbootldr,
				nixRoot: $nixRoot
			}
		}'
}

validate_schema() {
	jq -e '
		def disjoint($a; $b):
			($a.endSector < $b.startSector) or ($b.endSector < $a.startSector);
		.schemaVersion == 1
		and .kind == "chev-desktop-machine"
		and .modelNormalization == "trim; remove leading WDC vendor token only"
		and .serialNormalization == "uppercase; remove period underscore colon hyphen and ASCII whitespace only"
		and (.systemDisk.model | type == "string" and length > 0)
		and (.systemDisk.normalizedSerial | type == "string" and length > 0)
		and (.systemDisk.platformUniqueId == null or (.systemDisk.platformUniqueId | type == "string" and length > 0))
		and (.systemDisk.gptDiskGuid | type == "string" and length > 0)
		and (.systemDisk.logicalSectorSize | type == "number" and . >= 512)
		and (.systemDisk.byteSize | type == "number" and . > 0)
		and (.systemDisk.sectorCount | type == "number" and . > 0)
		and (.systemDisk.byteSize == (.systemDisk.logicalSectorSize * .systemDisk.sectorCount))
		and (.windowsBoot.microsoftLoaderSha256 | type == "string" and test("^[0-9a-f]{64}$"))
		and (.windowsBoot.fallbackPresent | type == "boolean")
		and (
			if .windowsBoot.fallbackPresent then
				(.windowsBoot.fallbackSha256 | type == "string" and test("^[0-9a-f]{64}$"))
			else
				.windowsBoot.fallbackSha256 == null
			end
		)
		and .partitions.windowsEsp.role == "windows-esp"
		and .partitions.windowsEsp.intendedMount == "/efi"
		and (.partitions.windowsEsp.gptType | ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
		and .partitions.windowsEsp.byteSize == 104857600
		and .partitions.xbootldr.role == "xbootldr"
		and .partitions.xbootldr.intendedMount == "/boot"
		and (.partitions.xbootldr.gptType | ascii_downcase) == "bc13c2ff-59e6-4262-a352-b275fd6f7172"
		and .partitions.nixRoot.role == "nix-root"
		and .partitions.nixRoot.intendedMount == "/"
		and (.partitions.nixRoot.gptType | ascii_downcase) == "0fc63daf-8483-4772-8e79-3d69d8477de4"
		and ([.partitions.windowsEsp.partuuid, .partitions.xbootldr.partuuid, .partitions.nixRoot.partuuid] | unique | length) == 3
		and disjoint(.partitions.windowsEsp; .partitions.xbootldr)
		and disjoint(.partitions.windowsEsp; .partitions.nixRoot)
		and disjoint(.partitions.xbootldr; .partitions.nixRoot)
		and ([.partitions.windowsEsp, .partitions.xbootldr, .partitions.nixRoot] | all(.[];
			(.role | type == "string")
			and (.partuuid | type == "string" and length > 0)
			and (.gptType | type == "string" and length > 0)
			and (.startSector | type == "number" and . > 0)
			and (.endSector | type == "number" and . >= 0)
			and (.sectorCount | type == "number" and . > 0)
			and (.byteSize | type == "number" and . > 0)
			and (.endSector == (.startSector + .sectorCount - 1))
			and (.byteSize == (.sectorCount * $logicalSectorSize))
			and (.fsType == null or (.fsType | type == "string"))
			and (.fsLabel == null or (.fsLabel | type == "string"))
			and (.intendedMount | type == "string")))
	' --argjson logicalSectorSize "$(jq '.systemDisk.logicalSectorSize' "$1")" "$1" >/dev/null
}

[[ -n "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || {
	printf 'Manifest is missing or unsafe: %s\n' "$manifest" >&2
	exit 1
}
validate_schema "$manifest" || {
	printf '%s\n' 'Machine manifest failed schema validation.' >&2
	exit 1
}

efi_probe="$(mktemp -d)"
cleanup_probe() {
	umount "$efi_probe" >/dev/null 2>&1 || true
	rmdir "$efi_probe" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT
mount -o ro,nosuid,nodev,noexec "$efi_device" "$efi_probe"
[[ -f "$efi_probe/EFI/Microsoft/Boot/bootmgfw.efi" ]] || {
	printf 'The selected ESP does not contain EFI/Microsoft/Boot/bootmgfw.efi: %s\n' "$efi_device" >&2
	exit 1
}
windows_microsoft_loader_hash="$(sha256sum "$efi_probe/EFI/Microsoft/Boot/bootmgfw.efi" | awk '{print $1}')"
if [[ -f "$efi_probe/EFI/BOOT/BOOTX64.EFI" ]]; then
	windows_fallback_present=true
	windows_fallback_hash="$(sha256sum "$efi_probe/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}')"
else
	windows_fallback_present=false
	windows_fallback_hash=""
fi
cleanup_probe
trap - EXIT

live_manifest="$(mktemp)"
expected_manifest="$(mktemp)"
live_comparable="$(mktemp)"
expected_comparable="$(mktemp)"
trap 'rm -f "$live_manifest" "$expected_manifest" "$live_comparable" "$expected_comparable"' EXIT
capture_manifest | jq --sort-keys . >"$live_manifest"
jq --sort-keys . "$manifest" >"$expected_manifest"

# Windows Get-Disk.UniqueId and Linux lsblk WWN are source-specific evidence,
# not guaranteed representations of the same identifier. The cross-OS guard
# instead uses model, normalized serial, GPT GUID, and exact disk geometry.
jq 'del(
	.systemDisk.platformUniqueId,
	.windowsBoot.fallbackPresent,
	.windowsBoot.fallbackSha256,
	.partitions.xbootldr.fsType,
	.partitions.xbootldr.fsLabel,
	.partitions.nixRoot.fsType,
	.partitions.nixRoot.fsLabel
)' "$live_manifest" >"$live_comparable"
jq 'del(
	.systemDisk.platformUniqueId,
	.windowsBoot.fallbackPresent,
	.windowsBoot.fallbackSha256,
	.partitions.xbootldr.fsType,
	.partitions.xbootldr.fsLabel,
	.partitions.nixRoot.fsType,
	.partitions.nixRoot.fsLabel
)' "$expected_manifest" >"$expected_comparable"
if ! cmp -s "$expected_comparable" "$live_comparable"; then
	printf '%s\n' 'Machine manifest does not match live disk identity, geometry, partition GUIDs, or ESP state:' >&2
	diff -u "$expected_comparable" "$live_comparable" >&2 || true
	exit 1
fi

jq -e --slurpfile expected "$expected_manifest" --slurpfile live "$live_manifest" -n '
	def same($role):
		$live[0].partitions[$role].fsType == $expected[0].partitions[$role].fsType
		and $live[0].partitions[$role].fsLabel == $expected[0].partitions[$role].fsLabel;
	def formatted($role; $type; $label):
		(($live[0].partitions[$role].fsType // "") | ascii_downcase) == $type
		and $live[0].partitions[$role].fsLabel == $label;
	(same("xbootldr") or formatted("xbootldr"; "vfat"; "NIXBOOT"))
	and (same("nixRoot") or formatted("nixRoot"; "btrfs"; "NIXROOT"))
' >/dev/null || {
	printf '%s\n' 'Root/XBOOTLDR filesystem state is neither the Windows capture nor the guarded post-format state.' >&2
	exit 1
}

if [[ "$mode" == export ]]; then
	[[ -n "$output" ]] || {
		printf '%s\n' '--output is required for export.' >&2
		exit 2
	}
	[[ ! -e "$output" && ! -L "$output" ]] || {
		printf 'Refusing to overwrite observation path: %s\n' "$output" >&2
		exit 1
	}
	umask 077
	mkdir -p "$(dirname "$output")"
	temporary_output="$(mktemp "$(dirname "$output")/.machine-observation.XXXXXXXX")"
	install -m 0600 "$live_manifest" "$temporary_output"
	mv "$temporary_output" "$output"
	printf 'Wrote matching read-only Linux observation to %s\n' "$output"
	exit 0
fi

printf '%s\n' 'Machine manifest matches live disk identity, geometry, partitions, ESP, and an allowed target filesystem state.'
