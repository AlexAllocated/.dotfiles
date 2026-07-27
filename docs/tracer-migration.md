# Tracer Migration Runbook

This runbook installs the Ryzen/RTX workstation as `tracer`, with local user
`alx`, while keeping `chev-desktop` and WSL on `alex`.

## Before assembly

1. Finish and push the complete dotfiles tree.
2. Move Docker onto the existing `/data` filesystem with
   `migrate-docker-data-root`; verify containers and named volumes before
   removing the old `/var/lib/docker` copy.
3. Build `.#tracer-rescue-iso` and write the Lexar rescue drive with the
   confirmation-gated `.#tracer-rescue-media` package.
4. Boot the Lexar on Chev with Secure Boot disabled. Unlock persistence, run
   `tracer-diagnostics`, verify networking and SSH, and run `resume-tracer`.
5. Leave the Intel 2 TB drive unchanged until Tracer is assembled and its 4 TB
   NixOS filesystem is available as a verified temporary migration target.

## Firmware and Windows

1. Install the WD_BLACK SN8100 in `M2_1`. Leave the Intel 2 TB and old 500 GB
   disks physically disconnected.
2. Update the MSI firmware from the SanDisk, then enable UEFI and AMD fTPM.
   Keep Secure Boot disabled initially.
3. Install Windows 11 Pro first. Allocate `512000 MB`, create local user `alx`,
   and link the Microsoft account afterward. Do not enable BitLocker yet.
4. Install without a key and try the Activation Troubleshooter. The old
   Doghouse license may be non-transferable OEM licensing; use a legitimate
   retail Pro license if activation does not transfer.

## NixOS installation

1. Boot the Lexar rescue system and verify that only the SN8100 is installed.
2. Confirm Windows Boot Manager works and identify the SN8100 by its stable
   `/dev/disk/by-id` path and printed serial.
3. Run `install-tracer --disk PATH --expected-serial SERIAL`. The installer
   preserves Windows, uses only the largest unallocated extent, and requires a
   serial-specific typed confirmation before creating:
   - `TRACER_BOOT`: 2 GiB XBOOTLDR
   - `TRACER_CRYPT`: LUKS2 container
   - `TRACER_NIX`: Btrfs with `@root`, `@home`, `@nix`, `@games`, and `@swap`
4. Store the LUKS recovery passphrase in 1Password and set a separate graphical
   login password for `alx`.
5. Boot systemd-boot once before enabling Secure Boot.

## Secure Boot and TPM

1. Run `bootctl status` and confirm UEFI, systemd-boot, and TPM2 support.
2. Create `/etc/secureboot` keys with `sbctl`, enroll them while retaining
   Microsoft keys, and test signed boot recovery before changing firmware.
3. Set `dotfiles.tracer.secureBoot.enable = true`, build and switch, then enable
   Secure Boot in firmware and verify `sbctl verify` plus both OS boot paths.
4. Enroll `TRACER_CRYPT` with
   `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`; retain and test the
   recovery passphrase. Systemd discovers the enrolled LUKS2 token at boot.
5. Enable Windows BitLocker last and store its recovery key separately.

## Intel 2 TB migration — deferred

Do not perform this phase until the new PC is assembled.

1. Power down, install the Intel SSD in `M2_2`, and boot Tracer from the SN8100.
2. Copy Steam games, preserved files, and `/data/docker` to temporary locations
   on `TRACER_NIX`. Stop Docker before copying its data-root.
3. Run a second checksum-based `rsync` verification and retain the source until
   all counts and hashes agree.
4. Only after verification, replace the Intel layout with one LUKS2/Btrfs
   volume labeled `TRACER_DATA_CRYPT`/`TRACER_DATA` and an `@data` subvolume.
5. Restore bulk files and Docker to `/data`, enroll TPM2 unlock, and verify that
   a missing `/data` skips Docker without blocking desktop boot. Then set
   `dotfiles.tracer.dataDisk.enable = true` and switch the complete generation.
6. Recreate Compose containers from the `alx` checkout so bind mounts change
   from `/home/alex/code` to `/home/alx/code`; preserve and verify named volumes.

## Final acceptance

- Move Chev from static `192.168.0.117` to DHCP before enabling Tracer's static
  profile with its discovered Ethernet interface.
- Verify audio buses/noise suppression, physical outputs, RTX 5080 decode and
  encode, OBS/Vesktop capture, Noctalia thermals, Bluetooth, Sunshine/Moonlight,
  dummy display, Steam, SSH/tmux, Docker, and both boot paths.
- Keep the old 500 GB system disk untouched until every acceptance check passes.
