# Tracer Migration Runbook

This runbook installs the Ryzen/RTX workstation as `tracer`, with local user
`alx`, while keeping `chev-desktop` and WSL on `alex`.

## Recovered hardware inventory

- CPU: AMD Ryzen 9 9950X3D2 Dual Edition (`100-100001978WOF`), 16 cores / 32
  threads, 5.6 GHz maximum boost, 192 MiB L3 plus 16 MiB L2, 200 W TDP
- Cooler: ARCTIC Liquid Freezer III Pro 420 with its included AM5 hardware,
  three 140 mm fans, VRM fan, and MX-6 thermal compound
- Motherboard: MSI PRO X870-P WIFI (`MS-7E47`), ATX, AM5, Wi-Fi 7, Bluetooth
  5.4, 5 GbE, USB4, and Flash BIOS Button
- Memory: KLEVV CRAS V RGB black 64 GB kit (`KD5BGUA80-60A300G`), two 32 GB
  DDR5-6000 CL30-36-36-76 SK Hynix A-die DIMMs with AMD EXPO
- GPU: ZOTAC GAMING GeForce RTX 5080 SOLID CORE OC 16 GB
  (`ZT-B50800J2-10A`), 303.5 x 115.8 x 55.7 mm, 360 W, one 12V-2x6 input
- Primary SSD: WD_BLACK SN8100 4 TB (`WDS400T1X0M`), M.2 2280 PCIe 5.0 x4
- PSU: be quiet! Pure Power 13 M 1200 W (`BP029US`), ATX 3.1 with a native
  600 W 12V-2x6 cable
- Case: Antec FLUX PRO black full tower with three front 140 mm intake fans,
  two 120 mm reverse-blade PSU-shroud intake fans, one rear 140 mm exhaust fan,
  and support for the 420 mm radiator at the top

Use the PSU's native 12V-2x6 cable, fully seated at both ends, instead of the
three-to-one adapter included with the GPU. Install the memory in `DIMMA2` and
`DIMMB2`, the SN8100 in CPU-attached `M2_1`, and the RTX 5080 in `PCI_E1`.
Top-mount the 420 mm radiator as exhaust. Leave the Intel 2 TB and old 500 GB
drives disconnected for the initial build.

Manufacturer references:

- [MSI motherboard manual](https://download.msi.com/archive/mnu_exe/mb/PROX870-PWIFI_English.pdf)
- [MSI Flash BIOS Button procedure](https://www.msi.com/support/technical_details/MB_Flash_BIOS_Button)
- [Antec FLUX PRO specifications](https://www.antec.com/product/case/flux-pro)
- [ARCTIC Liquid Freezer III Pro 420 AMD guide](https://support.arctic.de/products/liquid-freezer-iii-pro-420-a-rgb/techdocs/Quick_Manual_AMD_r1b.pdf)
- [be quiet! Pure Power 13 M specifications](https://www.bequiet.com/en/powersupply/6022)
- [ZOTAC RTX 5080 product brief](https://www.zotac.com/download/mediadrivers/External/GraphicsCard/5080/Brochure/ZT-B50800J2-10A-brochure.pdf)
- [WD_BLACK SN8100 data sheet](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/product/internal-drives/wd-black-ssd/data-sheet-wd-black-sn8100-nvme-ssd.pdf)

## Removable media

- Lexar 128 GB rescue/installer:
  `/dev/disk/by-id/usb-Lexar_USB_Flash_Drive_3756941132526803-0:0`, serial
  `3756941132526803`. It is rebuilt from `.#tracer-rescue-media` with a 1 GiB
  UEFI partition, a 16 GiB immutable NixOS payload, and LUKS2/Btrfs encrypted
  persistence containing the migration state.
- SanDisk Cruzer 64 GB firmware media:
  `/dev/disk/by-id/usb-SanDisk_Cruzer_04020122101921225345-0:0`, serial
  `04020122101921225345`. It has a 1 GiB active FAT32 partition labeled
  `MSI_BIOS` and the firmware at `/MSI.ROM`. After firmware setup is complete,
  this drive can be repurposed as the Windows 11 installer.

The firmware image is MSI PRO X870-P WIFI `V1.A92`, released 2026-07-01. The
official ZIP is
[`7E47v1A92.zip`](https://download.msi.com/bos_exe/mb/7E47v1A92.zip):

```text
ZIP SHA256  071fd580ef18d9847c10e4bad424c3b0547a833dd538f64444db715640f763e3
ROM SHA256  e5b36f99c2bce46fd7d456593205491d98377371a881d11611e65426add220fa
```

The extracted `E7E47AMSI.1A92` is renamed to `MSI.ROM` for Flash BIOS Button
use. Do not use M-Flash for this oversized physical stick. With the board on a
nonconductive surface, connect PSU `ATX_PWR1` and `CPU_PWR1`, insert the SanDisk
in the rear port labeled `Flash BIOS`, turn on the PSU, press the Flash BIOS
button, and do not remove power until its LED stops flashing.

## Guided assembly order

Stop after each numbered phase for inspection rather than rushing through the
whole list at once.

1. Inventory every box and accessory. Set aside a #2 Phillips screwdriver,
   small parts tray, zip ties, the motherboard manual, and both prepared USB
   drives. Work on a hard, nonconductive surface; never place the motherboard
   on the outside of its antistatic bag.
2. Flash the bare motherboard before installing CPU or RAM. Put it on its
   cardboard box, connect only the PSU's 24-pin ATX and `CPU_PWR1` cables, and
   follow the Flash BIOS Button procedure above. Power off and unplug the PSU
   after the LED has completely stopped.
3. Inspect the AM5 socket under bright light, install the CPU by its alignment
   triangle without touching socket contacts, and close the retention frame.
4. Install the SN8100 in `M2_1`, remove the protective film from the M.2
   heatsink pad, and reinstall the heatsink. Install the two DIMMs in `DIMMA2`
   and `DIMMB2` until both double-sided latches lock.
5. Strip both case panels and the top radiator bracket, verify the ATX standoff
   pattern, and plan cable routes. Install the PSU fan-down and pre-route the
   24-pin ATX, both 8-pin CPU/EPS cables, native 12V-2x6 GPU cable, SATA power
   for any fan/RGB hub, and front-panel cables.
6. Install the motherboard without trapping cables. Remove only the stock AM5
   plastic cooler brackets while retaining the factory backplate, then install
   ARCTIC's AM5 offset brackets in the documented orientation.
7. Install the 420 mm radiator at the top as exhaust. Connect radiator fans to
   `CPU_FAN1`, the pump to `PUMP_SYS1`, and the VRM fan to an available
   `SYS_FAN` header when using ARCTIC's individual-control cable. Apply the
   included MX-6 and mount the pump block evenly without overtightening.
8. Connect and audit the case's power/reset/LED leads, front USB-A, front USB-C,
   front audio, six case fans, temperature display, fan/RGB hub power, Wi-Fi
   antenna, 24-pin ATX, and both CPU/EPS connectors against the manuals.
9. Install the RTX 5080 in `PCI_E1`, secure it and its support stand, and use
   only the PSU's native 12V-2x6 cable. Seat both ends fully, confirm its Power
   Safety Light shows no warning, and avoid a tight bend where the cable leaves
   the plug.
10.   Before applying power, photograph and inspect every connection, look for
      loose screws, verify no cable touches a fan, and leave the Intel 2 TB and
      old 500 GB drives disconnected. First POST with the side panels still off.
11.   In firmware, load optimized defaults, verify `V1.A92`, CPU, 64 GB memory,
      SN8100, and fan/pump readings. Then enable EXPO, UEFI-only boot and AMD
      fTPM; leave Secure Boot disabled. Save changes and run the rescue media's
      diagnostics before installing either operating system.

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

- Keep Chev at its Master Chief address, `192.168.0.117`, and enable Tracer's
  static `192.168.0.69` profile after confirming its Ethernet interface.
- Verify audio buses/noise suppression, physical outputs, RTX 5080 decode and
  encode, OBS/Vesktop capture, Noctalia thermals, Bluetooth, Sunshine/Moonlight,
  dummy display, Steam, SSH/tmux, Docker, and both boot paths.
- Keep the old 500 GB system disk untouched until every acceptance check passes.
