#!/usr/bin/env bash
set -euo pipefail

run() {
	local heading="$1"
	shift
	printf '\n== %s ==\n' "$heading"
	"$@" 2>&1 || true
}

run "System" systemd-analyze --no-pager
run "Kernel" uname -a
run "Block devices" lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS
run "PCI devices" lspci -nnk
run "USB devices" lsusb -t
run "Network addresses" ip -brief address
run "Network links" ip -brief link
run "Temperatures" sensors
run "NVMe devices" nvme list
run "Boot status" bootctl status
run "Failed units" systemctl --failed --no-pager

printf '\nFor drive-specific health, run: sudo smartctl -x /dev/DEVICE\n'
