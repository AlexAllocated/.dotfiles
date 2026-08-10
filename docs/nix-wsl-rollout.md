# NixOS-WSL Rollout

NixOS is the primary WSL target.

## Install side-by-side

On a fresh Windows host, first run this from an elevated Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\bootstrap\nixos-wsl.ps1 -EnsureWindowsFeatures -NoLaunch
```

The bootstrap explicitly enables `Microsoft-Windows-Subsystem-Linux` and
`VirtualMachinePlatform`, updates the WSL runtime, and makes WSL 2 the default.
If either feature was newly enabled, it stops and requests a Windows reboot;
run the same command again afterward to install the pinned NixOS-WSL image.

Alternatively, from an existing WSL control-plane distro whose Windows host is
already WSL 2-ready:

```sh
./dot-bootstrap nixos-wsl
```

The bootstrap installs a WSL distro named `NixOS` in `D:\WSL\NixOS` using the
latest `nixos.wsl` asset from NixOS-WSL.

## First apply

Inside the new distro:

```sh
git clone --filter=blob:none https://github.com/AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
./scripts/dotctl apply nixos-wsl
wsl.exe -t NixOS
dotctl doctor
```

The NixOS-WSL profile declares `alx` as the default user with `/home/alx` as
its home directory. Existing installations migrate `/home/alex` atomically and
retain it as a compatibility link so historical workspace paths remain valid.
It also installs or upgrades the Windows applications in
`platforms/windows/winget.json` through WinGet.

That manifest carries the workstation choices that remain useful on Windows:
1Password, Chrome, Discord, Vesktop, Steam, Battle.net, Sunshine, Synergy,
Razer Synapse 4, the NVIDIA App, OBS Studio, VLC, Spotify, qBittorrent,
SumatraPDF, ImageGlass, Teams, WezTerm, Neovide, and the Codex desktop app.
GPU driver selection and installation remain interactive and hardware-specific,
while the NVIDIA App used to manage those drivers is reproducible. Linux
desktop services such as Niri, Noctalia, PipeWire, OpenRazer, and ALVR are
intentionally not part of the WSL profile.

## SSH from the home network

The WSL profile runs a key-only OpenSSH server for the managed `alx` account.
Windows owns the LAN endpoint: an elevated scheduled task forwards Windows TCP
22 to the current NixOS-WSL address and limits the firewall opening to the
Private-profile local subnet. The task runs at Windows logon, and WSL asks it to
refresh once at each distro boot. There is no polling watchdog.

The first `dotctl apply nixos-wsl` requests one Windows UAC approval to install
the task and firewall rule. SSH public keys remain machine-local in
`~/.ssh/authorized_keys`; they are intentionally not committed to this public
repository. Verify the endpoint from Windows with:

```powershell
Test-NetConnection -ComputerName 127.0.0.1 -Port 22
Get-ScheduledTask -TaskName "Dotfiles NixOS-WSL SSH Forward"
netsh interface portproxy show v4tov4
```

If a fresh client cannot export its key without an initial login, use a
temporary enrollment session and return `sshd` to its declared key-only policy
immediately afterward. Never leave password authentication enabled.

## Quest VR hotspot

On Tracer, Windows Mobile Hotspot reserves the Qualcomm Wi-Fi radio for the
`Tracer-Quest-VR` WPA2 network on 5 GHz and shares the wired Ethernet uplink.
An event-driven scheduled task starts it at logon, after the network reconnects,
and after resume; the Windows no-client timeout is disabled. There is no polling
watchdog. Windows persists the passphrase locally, and the public dotfiles never
contain it. Inspect the live state with:

```powershell
& "$env:LOCALAPPDATA\dotfiles\configure-quest-hotspot.ps1" -Mode Status
Get-ScheduledTask -TaskName "Dotfiles Quest VR Hotspot"
```

Steam, WezTerm, Chrome, Discord, Battle.net, Sunshine, Synergy, Razer Synapse,
and the NVIDIA App are prioritized so a fresh workstation immediately has game
downloads, its WSL terminal, a browser, communications, remote access, shared
input, and hardware management while the remaining Windows applications and
integration are being reconciled.

Battle.net's WinGet package requires an explicit install root. The Windows
package reconciler detects a missing installation and supplies
`C:\Program Files (x86)\Battle.net` before running the complete idempotent
manifest import.

Sunshine's package and automatic Windows service are reproducible, but its host
identity and Moonlight client pairings are machine-local secrets. Restore an
existing identity from an elevated Windows PowerShell with:

```powershell
& \\wsl.localhost\NixOS\home\alx\.dotfiles\scripts\windows\restore-sunshine-identity.ps1 `
  -SourceDirectory C:\path\to\Sunshine-Handoff\identity
```

The restore validates the state/certificate/key, backs up the installer-created
identity, restarts `SunshineService`, and never copies secret state into Git.

## Cutover

After validation, run this from an elevated Windows PowerShell if Developer Mode
is not enabled:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
wsl.exe --set-default NixOS
```

The NixOS-WSL profile deploys the Windows-native Neovide config into Roaming
AppData. That config enables Neovide's supported WSL transport, so launching
Neovide from Windows runs the `nvim` managed by the default NixOS WSL distro.

## Shared Codex conversations

The NixOS-WSL profile uses one logical Codex home for the Windows ChatGPT/Codex
GUI and the WSL CLI:

- `CODEX_HOME=$WINHOME/.codex` keeps GUI settings, auth, plugins,
  conversation rollouts, history, rules, and memories in the Windows home.
- `CODEX_SQLITE_HOME=$HOME/.codex/sqlite` keeps the live SQLite indexes on
  WSL ext4, where SQLite locking and WAL behavior are reliable.

Do not symlink a live SQLite database across the WSL/Windows boundary. Also use
one active writer at a time: finish or stop the CLI before opening the GUI for
work, and close the GUI before starting a writing CLI session.

Before the one-time migration, close the ChatGPT/Codex GUI and every Codex CLI.
From a plain WSL terminal, run:

```sh
~/.dotfiles/scripts/dotctl codex-share preflight
~/.dotfiles/scripts/dotctl codex-share migrate
```

Use the checkout path for this first run because the currently installed
`dotctl` predates the migration command. The migration installs the new NixOS
boot generation after the data cutover.

The migration refuses to start while either client is running. It preserves the
Windows settings, imports the WSL conversation payloads and supporting history,
memories, goals, and rules, rewrites the thread index to the shared Windows
paths, and retains complete timestamped Windows and WSL rollback homes. WSL
diagnostic logs start fresh. The original stores are not deleted.

After migration, terminate the distro from Windows and validate the shared
layout in a new WSL session:

```sh
wsl.exe -t NixOS
# Open a new NixOS terminal after the command above.
dotctl codex-share doctor
```

The Windows GUI already launches its backend inside WSL when
`desktop.runCodexInWindowsSubsystemForLinux` is enabled. The environment above
also makes ordinary NixOS Codex CLI sessions use the same home and index.

Rollback archives must remain in place until the shared layout has been used
successfully from both clients and is explicitly approved for cleanup.

## 1Password model

Shell startup intentionally avoids interactive authentication. Use these commands
directly when needed:

```sh
op vault list
gh auth login --web -h github.com
```
