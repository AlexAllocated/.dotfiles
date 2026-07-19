# chev-desktop migration

`chev-desktop` is the native NixOS 26.05 target for the RTX 3090 Ti
workstation. Windows remains bootable for Rust and Phasmophobia. The internal
installer contains the Nix configuration and recovery tools, while a separate
local capsule carries machine identity, Git history, Codex continuity, and
Sunshine pairing secrets. No secret is embedded in the ISO or repository.

## Hard gates before partitioning

- Repair the existing Windows EFI System Partition in Windows first. Its
  current health report says **Full Repair Needed**. The installer runs
  `fsck.fat -n` and refuses a dirty or inconsistent ESP; it never repairs it.
- Confirm firmware CSM is already **Disabled**. Stop if it is not; do not change
  CSM as part of this migration.
- Commit and push every dotfiles and `D:\` worktree change that should survive.
- Move the OBS recordings that must survive from `D:\` to `C:\`.
- Do not wipe `D:\` until both operating systems, Sunshine/Moonlight, native
  development, and the games being retained have been verified.

## Build and verify the internal installer

```sh
nix build path:.#chev-installer-iso
ls -lh result/iso/

# Builds the ISO, verifies its NIXOS_ISO volume ID and classic findiso-capable
# initrd, stages the EFI/kernel files plus the unchanged ISO as a FAT32 file,
# and compares the copied ISO, GRUB config, and EFI loader byte-for-byte.
nix build path:.#chev-installer-fat32-check
```

The image volume ID is `NIXOS_ISO`. The installer ISO deliberately uses the
classic stage-1 initrd because it implements `findiso=`. The internal FAT32
partition stores the unchanged ISO as `nixos-chev-internal.iso`, plus the
extracted `EFI` and `boot` directories needed to start it. Its copied GRUB
config adds a literal `findiso=/nixos-chev-internal.iso` argument to every
Linux entry. A read-only OVMF rehearsal can boot the built ISO without exposing
any host disk:

```sh
iso="$(find result/iso -name '*.iso' -print -quit)"
ovmf="$(nix build --no-link --print-out-paths nixpkgs#OVMF.fd)"
vars="$(mktemp)"
cp "$ovmf/FV/OVMF_VARS.fd" "$vars"
nix run nixpkgs#qemu_kvm -- \
  -machine q35,accel=kvm:tcg -m 4096 -boot d \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf/FV/OVMF_CODE.fd" \
  -drive if=pflash,format=raw,file="$vars" \
  -cdrom "$iso"
rm -f "$vars"
```

No host block device is passed to QEMU. Confirm Plasma appears, open a terminal,
and run each operator command with `--help`. Also copy the staged layout into a
temporary FAT32 disk image and boot that image under OVMF before writing the
physical internal-installer partition.

The installer provides:

- `resume-migration`: read-only discovery, hash verification, private capsule
  import, Codex SQLite path normalization, and exact Codex 0.144.4 resume. It
  reuses the active private import by default; use `--fresh-import` only to
  discard that live pointer and rebuild from persistent state. `--status`
  validates and prints the active resume target without starting Codex. An
  interactive resume runs in the private `migration` tmux socket, so a browser
  or terminal disconnect only detaches the viewer; attach explicitly with
  `tmux -L migration attach-session -t migration`.
- `checkpoint-migration`: publishes an online SQLite backup and complete-line
  rollout snapshot below `NixOS-Checkpoints` without changing the immutable
  handoff capsule. Checkpoints are staged and atomically renamed into unique,
  timestamped directories; a new import automatically applies the newest
  checkpoint tied to its handoff-manifest hash.
- `install-chev-desktop`: manifest-guarded formatting of only the two new
  partitions. It never partitions the disk, formats/relabels the ESP, or
  reboots.
- `export-machine-manifest` and `validate-machine-manifest`: read-only Linux
  observation/validation against the authoritative Windows manifest. Linux
  export cannot bless arbitrary devices.
- `rescue-remote-on` / `rescue-remote-off`: optional temporary ttyd on one
  detected private IPv4 address. It is disabled by default and has **no
  authentication or encryption**. Use it only on a trusted LAN and turn it off
  immediately. The rescue service prevents sleep, sends WebSocket keepalives,
  uses a mobile viewport with larger text and an embedded BigBlueTerm Nerd Font.
  The native `chev-desktop` profile temporarily starts the same unauthenticated
  service at boot on port 7681 and attaches every browser to the dedicated
  `recovery` tmux session. Its tmux server is a separate system service, so a
  browser or ttyd restart cannot kill the shell or Codex process. Mouse reporting
  and the terminal alternate screen are disabled for that session so normal
  touch scrolling reaches browser scrollback. Attach locally with
  `tmux -S /run/chev-ttyd-rescue-tmux/tmux.sock attach -t recovery`.
- `reboot-windows`: after the operator types `WINDOWS`, select the unique
  Windows entry through systemd-boot or UEFI `BootNext`, then reboot.
- `recover-windows-fallback`: after an interrupted `bootctl`, validate the
  imported machine/capsule, ESP cleanliness, Microsoft loader, and recorded
  fallback hash; touch only `EFI/BOOT/BOOTX64.EFI` after a long typed phrase.

## Expected storage layout

Windows creates the two new GPT partitions in space released from `C:`. The
installer does not resize or create them.

| Purpose              |          Suggested size | GPT type / installed filesystem                    | Mount            |
| -------------------- | ----------------------: | -------------------------------------------------- | ---------------- |
| Existing Windows ESP |         exactly 100 MiB | EFI System / existing FAT32, unchanged             | `/efi`           |
| New XBOOTLDR         |                   2 GiB | `bc13c2ff-59e6-4262-a352-b275fd6f7172` / `NIXBOOT` | `/boot`          |
| New NixOS root       | remaining planned space | `0fc63daf-8483-4772-8e79-3d69d8477de4` / `NIXROOT` | Btrfs subvolumes |

`NIXROOT` contains `@root`, `@home`, `@nix`, and `@swap`. The native target
uses compression, an 8 GiB swapfile, and 25% zram. systemd-boot places kernels
on XBOOTLDR and its small loader in the shared ESP. The ESP mount uses the
manifest's PARTUUID; its FAT label is not needed and is never changed.

The installer records the original `EFI/BOOT/BOOTX64.EFI` (or its absence)
under `EFI/NixOS` before systemd-boot installation. Every later `dotctl apply`
restores that exact fallback state after `bootctl`; the Microsoft loader under
`EFI/Microsoft/Boot/bootmgfw.efi` is hashed before and after installation.

## Create the local handoff capsule

After Windows has created both partitions with the exact GPT types, open an
elevated PowerShell. Normally close all Codex writers first. If this migration
thread itself is performing the handoff, explicitly authorize only that same
UUID with `-AllowLiveThread`; the exporter uses SQLite online backup and a
stable, complete-line JSONL snapshot.

```powershell
$thread = 'REPLACE_WITH_THIS_THREAD_UUID'
& \\wsl.localhost\NixOS\home\alex\.dotfiles\scripts\windows\new-nixos-handoff.ps1 `
  -ThreadId $thread `
  -BootPartitionNumber REPLACE_XBOOTLDR_NUMBER `
  -RootPartitionNumber REPLACE_NIXROOT_NUMBER `
  -AllowLiveThread $thread
```

The script derives the disk from the Windows `C:` partition, refuses a non-GPT
system disk, reads the GPT disk GUID with read-only `diskpart uniqueid disk`,
uses `Win32_DiskDrive.BytesPerSector`, verifies the unique 100 MiB ESP and
Microsoft loader, and captures exact byte/sector geometry and partition GUIDs.
`-CaptureDiskOnly` is a non-writing diagnostic mode.

It refuses an existing `C:\NixOS-Handoff\v1`, a dirty dotfiles worktree, or
unrelated live Codex writers. It creates the capsule through a staging
directory and atomic rename. Payloads include:

- `machine-manifest.json` with the cross-OS model (trimming only Windows' `WDC`
  vendor token), normalized serial, source
  UniqueId evidence, GPT disk GUID, sector geometry, and exact partition data;
- a verified Git bundle containing the complete dotfiles history;
- sanitized Codex config/auth, one online-backed `codex/sqlite/state_*.sqlite`,
  and the selected dated rollout;
- Sunshine `sunshine_state.json`, matching RSA certificate/private key, host
  unique ID, and paired clients.

Every payload has a SHA-256 record in `manifest.json`. The Linux importer
rejects links, devices, duplicates, unmanifested/unknown paths, invalid hashes,
files over 2 GiB, capsules over 4 GiB, config files that still set
`sqlite_home`, malformed Sunshine JSON/PEM, mismatched Sunshine keys, or an
ambiguous Codex rollout/database.

## Import, continue, and install

Boot the internal USB and run:

```sh
resume-migration --import-only
```

It mounts NTFS only when necessary and only read-only with
`nosuid,nodev,noexec`, copies verified files into a new private `0700` import,
sets files to `0600`, rewrites the selected SQLite `rollout_path`, then unmounts
the NTFS source. Without `--import-only`, it resumes the exact thread with
`CODEX_HOME` and `CODEX_SQLITE_HOME` isolated inside that import and with the
already authorized migration sandbox/approval policy.

Use the printed private import path for all four explicit installer arguments:

```sh
sudo install-chev-desktop \
  --root-device /dev/disk/by-id/REPLACE_ROOT_PARTITION \
  --boot-device /dev/disk/by-id/REPLACE_XBOOTLDR_PARTITION \
  --efi-device /dev/disk/by-id/REPLACE_WINDOWS_ESP_PARTITION \
  --machine-manifest /home/nixos/.local/state/chev-migration/imports/REPLACE/machine-manifest.json
```

Before any write, the command resolves aliases to kernel devices, rejects
duplicate MAJ:MIN values, validates disk model/serial/GPT GUID/size/sector
geometry, exact PARTUUIDs, GPT types and extents, the ESP filesystem and
Microsoft loader, capsule hashes, Sunshine material, and dotfiles Git bundle.
It accepts target filesystems only in the Windows-captured preformat state or
the guarded retry state (`btrfs/NIXROOT` and `vfat/NIXBOOT`). It then prints the
plan and requires the complete canonical root-device path to be typed.

Installation restores the dotfiles Git repository, writes the generated ESP
PARTUUID module, restores Sunshine pairing before autologin can start it, and
installs native Codex auth/database/rollout at `/home/alex/.codex`. It rewrites
the native rollout path, runs `codex login status` and `codex doctor`, and asks
for an initial `alex` password. Plasma autologin is enabled, but the password is
still required for `sudo`. On success the command unmounts every target
filesystem and does not reboot.

If password entry is interrupted after NixOS installation, do not boot an
unadministerable system. The failure trap unmounts the target. Mount the two
required Btrfs subvolumes explicitly, set the password, and unmount them:

```sh
sudo mount -o subvol=@root /dev/disk/by-label/NIXROOT /mnt
sudo mkdir -p /mnt/nix
sudo mount -o subvol=@nix /dev/disk/by-label/NIXROOT /mnt/nix
sudo nixos-enter --root /mnt -c 'passwd alex'
sudo umount /mnt/nix /mnt
```

If power is lost during `bootctl` before the post-install fallback restoration,
do not manually copy EFI files and do not reformat the installed partitions.
Boot the live image, import the same capsule, and run:

```sh
sudo recover-windows-fallback \
  --efi-device /dev/disk/by-id/REPLACE_WINDOWS_ESP_PARTITION \
  --machine-manifest /home/nixos/.local/state/chev-migration/imports/REPLACE/machine-manifest.json
```

The helper derives root/XBOOTLDR from their manifest PARTUUIDs, runs the full
machine validator and read-only FAT check, verifies the Microsoft loader and
installer-created fallback record against the Windows-captured hashes, then
requires `RESTORE WINDOWS FALLBACK`. It writes or removes only
`EFI/BOOT/BOOTX64.EFI`, remounts read-only, and verifies the final state.

## iPad dummy display and Sunshine parity

The dummy adapter is `FUN7F52` / `EK1080T4KHR`; the LG is `GSM774B`. Its stock
EDID advertises common 1080p/1440p/4K modes but not the custom iPad mode.
NixOS supplies the iPad Pro panel's exact 2732x2048 size at approximately 60 Hz
(365.61 MHz, totals 2892x2107), avoiding a host-side resize before encoding.

NixOS declaratively generates that EDID. On the first native boot:

```sh
ipad-display-prepare
```

The command finds exactly one connected FUN/EK1080 adapter, explicitly excludes
the LG, and prints the connector assignment to add alongside the generated ESP
PARTUUID in `hosts/chev-desktop/hardware-generated.nix`, for example:

```nix
dotfiles.desktop.ipadDisplay.connector = "DP-2";
```

Run `dotctl apply`, reboot once for the connector-specific
`drm.edid_firmware=...:edid/ipad2732.bin` setting, then use:

```sh
ipad-display-on          # dummy as another Plasma display
ipad-display-on --sole   # disable other currently enabled Plasma outputs
ipad-display-off
```

The workstation helper applies 175% scale to the iPad dummy without changing
the LG's independently stored 100% scale.

If the dummy is the only enabled output, `ipad-display-off` refuses to leave
Plasma with no display. Connect the LG (or another display) and restore it in
the same atomic KScreen update:

```bash
ipad-display-off --restore-output DP-1
```

Sunshine probes displays before it runs an application's preparation command.
The native profile therefore runs a retrying `ipad-display-on` preflight before
every Sunshine start, and Plasma retains the dummy's enabled state. Keep the
dummy enabled for dependable downstairs/headless recovery. `ipad-display-off`
is a local teardown command, not a remote wake mechanism; after using it,
restart Sunshine locally before relying on Moonlight again.

`ipad-display-prepare --apply-now` can use the kernel's per-connector debugfs
override and either its hotplug trigger or the standard DRM reprobe interface;
it still refuses any connector whose EDID is not FUN/EK1080. Request 2732x2048
in Moonlight so Sunshine's host capture and encoded client frame remain the
same native iPad size.

The pinned Sunshine build supports the Plasma Wayland `kwin` capture backend.
Once the connector is configured, Nix also sets Sunshine `output_name` to that
dummy output and its Desktop prep command enables the mode. `alex` belongs to
the `uinput` group so Moonlight keyboard, mouse, and gamepad injection works.

The native target also enables the Docker daemon, Steam/GE-Proton, Gamescope,
GameMode, Sunshine, and non-autostart WiVRn/ALVR. OBS, Kdenlive, GIMP, Krita,
Audacity, Ardour, Flameshot, and ksnip are installed as the initial creative and
capture toolset.
