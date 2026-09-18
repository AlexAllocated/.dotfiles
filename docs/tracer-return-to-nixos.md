# Returning Tracer to native NixOS

Build the remote-capable live environment with:

```sh
nix build .#tracer-remote-rescue-iso
```

This is a temporary installation/recovery desktop. It does not format or install
onto an internal disk automatically. The older Btrfs-persistent rescue target
remains available as `.#tracer-rescue-iso`.

Use a Ventoy USB data partition labeled `TRACERDATA`. Store the ISO below `/ISO`
and the private `remote-seed` directory at the data partition root. Configure
Ventoy's default image and menu timeout to boot it without a selection.

The remote image provides Plasma auto-login as `alx`, NVIDIA NVENC Sunshine,
Ethernet at Tracer's existing static LAN address, and key-only SSH. The private
seed supplies:

```text
remote-seed/
  SHA256SUMS
  ssh/
    authorized_keys
    ssh_host_ed25519_key
    ssh_host_ed25519_key.pub
  sunshine/
    sunshine_state.json
    credentials/
      cacert.pem
      cakey.pem
```

Copy Sunshine's current state, certificate and private key together. Reusing only
the hostname or UUID is insufficient to preserve existing Moonlight pairing.
The seed is verified and restored before SSH key generation and graphical login.
Never add the seed or other private migration data to this repository or the Nix
store. Keep removable recovery media physically secure.

Keep Windows as the ordinary firmware fallback until Linux has been verified on
the real hardware. Use a one-shot firmware boot selection for the initial USB
boot. Secure Boot may require physical key enrollment at first boot; do not
assume a successful image build proves firmware trust or physical GPU streaming.

The current migration targets approximately 1.5 TB for Windows and 2.5 TB for
NixOS on the 4 TB SN8100, retaining Windows EFI and Recovery. Back up private
configuration, authentication and Codex history to verified off-disk media before
removing WSL, old migration archives or restore points. Repositories are recovered
from their pushed migration branches, not full source-tree archives. Local
Bumblebee databases and Docker volumes are disposable.

The installer accepts at least 2.4 decimal TB of contiguous free space for this
split. It must not resize Windows itself. The installed boot-order service keeps
Linux first while retaining existing Windows and USB fallback entries. Keep the
LUKS recovery key off the internal disk and verify TPM unlock before the first
unattended boot; changes to Secure Boot policy can require that recovery key.

The Windows package manifest no longer installs Docker Desktop, and normal WSL
reconciliation no longer starts it. `configure-docker-desktop.ps1` remains an
explicit, opt-in helper. `configure-system-restore.ps1 -Disable` applies the
requested System Restore policy and requests elevation only if the policy needs
changing; it does not explicitly delete unrelated VSS snapshots.
