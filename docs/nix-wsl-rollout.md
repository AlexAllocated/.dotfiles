# Ubuntu-WSL Rollout

Ubuntu 26.04 with standalone Home Manager is the primary WSL target.

## Install

From any existing WSL distro:

```sh
./dot-bootstrap ubuntu-wsl
```

The bootstrap installs `Ubuntu-26.04`, creates `alx`, enables systemd, installs
the small apt-owned system foundation and Determinate Nix, then activates Home
Manager. It terminates the new distro once to apply `/etc/wsl.conf`; routine
Home Manager generations never require that restart.

## First apply

Inside the new distro, routine application is live:

```sh
dotctl apply ubuntu-wsl
dotctl doctor
```

The Ubuntu-WSL profile declares `/home/alx` and installs or upgrades the Windows applications in
`platforms/windows/winget.json` through WinGet.

That manifest carries the workstation choices that remain useful on Windows:
1Password, Chrome, Discord, Vesktop, Steam, Battle.net, Sunshine, Synergy,
Mullvad VPN, Razer Synapse 4, the NVIDIA App, OBS Studio, VLC, Spotify, qBittorrent,
SumatraPDF, ImageGlass, Teams, WezTerm, Neovide, and the Codex desktop app.
GPU driver selection and installation remain interactive and hardware-specific,
while the NVIDIA App used to manage those drivers is reproducible. Linux
desktop services such as Niri, Noctalia, PipeWire, OpenRazer, and ALVR are
intentionally not part of the WSL profile.

The reconciler refreshes every WinGet source before importing the versionless
manifest. Because the import does not use `--no-upgrade`, declared applications
are upgraded to the newest version currently published by their source as well
as installed when missing. Applications with a newer self-updated version are
not downgraded when the community catalog lags behind the publisher.

## OBS streaming profile

The Windows integration reconciles a `HiveTech 1440p` OBS profile at
2560x1440 and 60 FPS. It pins Branch Output 1.0.9 by checksum, installs the
matching 2560x1440 meadow backdrop into Windows-local application data, uses
x264 `fast` at 8 Mbps with a 12-thread ceiling for the primary stream, and uses
NVENC HEVC CQP 18 for the clean recording branch. This keeps the edit-critical
recording on the GPU while preserving NVENC capacity for an occasional
concurrent Sunshine session. The clean branch is interlocked with streaming,
so starting the main `Stream + Bumblebee` output also records `Clean Ultrawide`
without the browser overlay into `Videos\\OBS Clean`.

OBS owns the mutable scene collection. The Bumblebee dashboard's tokenized
overlay URL is machine-local secret state and must never be committed. On a
fresh Windows installation, create the two-scene composition once, paste the
current dashboard URL into the `Bumblebee Overlay` browser source, and leave
the public reconciler responsible only for the plugin, backdrop, profile, and
encoder contract.

## AudioArray streaming graph

The Windows integration builds the private Rust `AudioArray` utility, installs
its tracked graph configuration into `%APPDATA%\AudioArray`, and runs it at
interactive logon. Game, Comms, and Music use VAC Lines 1-3; Game is the normal
Windows output and Comms is its communications output. The selected physical
Windows microphone is processed by DeepFilterNet3 and published as Clean Mic
on Line 4, which is the normal and communications input. Selecting a physical
input or output updates the machine-local hardware endpoint and AudioArray then
restores the virtual Windows defaults. Unassigned applications therefore land
on Game instead of bypassing the graph.

VAC volume processing stays disabled. AudioArray treats the normal Windows
volume/mute state on Game as an event-driven master control for the selected
physical output and mirrors Windows-visible changes in either direction. This
final-sink volume never changes the VAC buses captured by OBS.

Windows 11 exposes one playback endpoint while switching Bluetooth headsets
between high-quality A2DP and hands-free HFP internally. AudioArray keeps its
monitor attached to that unified endpoint while the selected headset microphone
is open. It keeps the chosen master state authoritative during graph rebuilds
and restores it after the transport transition, while separately repairing a
muted or zero-level physical microphone. Choosing another microphone lets
Windows return the headphones to A2DP without changing AudioArray's remembered
output preference.

The installed Sunshine release temporarily makes its capture endpoint the
Windows default. AudioArray observes that actual endpoint transition, yields
only the render roles, and sends the combined Game, Comms, and Music monitor mix
to Steam Streaming Speakers. At disconnect it restores AudioArray Game and
AudioArray Comms as the normal and communications defaults and selects the
first usable device from its recency-ordered physical input/output histories.
Temporary Steam and Oculus
endpoints are never persisted as physical hardware selections.

Eugene Muzychenko's signed Virtual Audio Cable driver remains a private,
manually installed prerequisite. The reconciler provisions at least five cables,
requesting UAC and briefly restarting audio only if capacity is missing. It
preserves existing cable settings and never reboots automatically. The public
repository never stores the licensed installer. OBS master track 1 is the complete single-track stream mix. The clean
Branch Output recording embeds five audio streams in order: Publish Mix without
music, Clean Mic, Comms, Game, and Music.

## Minecraft VR

Prism Launcher is declared in the Windows WinGet manifest. Run the tracked
`configure-minecraft-vr.ps1` helper once on a new machine to import the pinned
Vivecraft Fabric profile for Minecraft 26.2. Prism owns Microsoft account
authentication and mutable worlds; the helper owns only the reproducible game,
Fabric Loader, and Vivecraft versions. Launch SteamVR before starting the
instance, and keep Minecraft's desktop window focused for controller input.

Both tracked Minecraft helpers install the same graphics stack: Iris and its
matching Sodium release, Fabric API and Continuity for connected textures, and
Complementary Unbound with LabPBR and parallax enabled, Fresh Animations with
EMF/ETF, dynamic lights, spatial sound, and supporting
performance mods. Both profiles include Distant Horizons; Vivecraft uses a
restrained 128-chunk, two-block-detail DH profile with six half-duty generation
workers, while desktop retains the unrestricted desktop configuration.
Visuality is omitted because its decorative
particle load is disproportionately expensive in stereo VR. Fresh Animations and Full Emissive are layered
above the selected PBR pack so animated entities and a broad set of ores, metals,
lamps, sculk, redstone, mobs, tools, and armor glow under the shader. Pixlli 128x
is the reproducible default; Patrix 32x, ModernArch 128x, rotrBLOCKS 128x, Prime's HD
32x, SPBR 16x, and Optimum Realism 64x are installed but inactive for quick
comparison. Desktop and Vivecraft remain
separate instances so their mutable game settings and worlds cannot collide,
but neither receives reduced texture or shader choices. The Vivecraft profile
uses a 5080-tuned Complementary Unbound Medium+
water-first profile: shader FXAA and water reflections remain enabled while
POM is disabled, shadow distance is limited to 96 chunks, simulation distance
to 8, entity distance to 85%, and particles to Decreased. SteamVR remains at an
explicit 100% resolution. Vivecraft's redundant FSAA
pass remains off so the Quest can sustain native refresh without half-rate ASW
ghosting. The desktop profile remains the unrestricted full-quality default.

Glowing Emissive Ores is also installed as a popular ore-focused alternative,
but remains disabled by default to avoid overlapping Full Emissive. Both can be
selected from Minecraft's Resource Packs screen.

## Per-monitor wallpapers

Windows receives the same matching meadow crops as the native NixOS desktop:
the 3440x1440 ultrawide image is assigned to the physical LG UltraGear and the
2732x2048 image is assigned to Sunshine's iPad VDD. The assignment uses stable
monitor identities rather than Windows display numbers, which change as the LG
and VDD trade places. Windows persists the per-monitor mapping, and a logon task
reconciles it without an always-running watcher. Sunshine's display-session hook
also reapplies the mapping whenever a Moonlight session creates the VDD.

## SSH from the home network

The WSL profile runs a key-only OpenSSH server for the managed `alx` account.
Windows owns the LAN endpoint: an elevated scheduled task forwards Windows TCP
22 to the current `Ubuntu-26.04` address and limits the firewall opening to the
Private-profile local subnet. The task runs at Windows logon, and WSL asks it to
refresh once at each distro boot. There is no polling watchdog.

The first `dotctl apply ubuntu-wsl` requests one Windows UAC approval to install
the task and firewall rule. SSH public keys remain machine-local in
`~/.ssh/authorized_keys`; they are intentionally not committed to this public
repository. Verify the endpoint from Windows with:

```powershell
Test-NetConnection -ComputerName 127.0.0.1 -Port 22
Get-ScheduledTask -TaskName "Dotfiles WSL SSH Forward"
netsh interface portproxy show v4tov4
```

If a fresh client cannot export its key without an initial login, use a
temporary enrollment session and return `sshd` to its declared key-only policy
immediately afterward. Never leave password authentication enabled.

## Quest VR hotspot

On Tracer, Windows Mobile Hotspot reserves the Qualcomm Wi-Fi radio for the
`Tracer-Quest-VR` WPA2 network on 5 GHz and shares the wired Ethernet uplink.
The Qualcomm radio supports 6 GHz as a client and Wi-Fi Direct group owner, but
its Windows hotspot path currently rejects 6 GHz with `RadioRestriction`.
An event-driven scheduled task starts it at logon, after the network reconnects,
and after resume; the Windows no-client timeout is disabled. There is no polling
watchdog. The integration also pins the exact radio to a Microsoft-signed driver,
prevents Windows from powering it off while idle, and minimizes roaming scans so
latency-sensitive VR traffic does not inherit workstation power-saving defaults.
Windows persists the passphrase locally, and the public dotfiles never contain
it. Inspect the live state with:

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
& \\wsl.localhost\Ubuntu-26.04\home\alx\.dotfiles\scripts\windows\restore-sunshine-identity.ps1 `
  -SourceDirectory C:\path\to\Sunshine-Handoff\identity
```

The restore validates the state/certificate/key, backs up the installer-created
identity, restarts `SunshineService`, and never copies secret state into Git.

## Windows integration

`dotctl apply ubuntu-wsl` keeps the Windows links and default WSL distro aligned.
To reconcile only the links manually, run:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName Ubuntu-26.04
wsl.exe --set-default Ubuntu-26.04
```

The Ubuntu-WSL profile deploys the Windows-native Neovide config into Roaming
AppData. That config enables Neovide's supported WSL transport, so launching
Neovide from Windows runs the `nvim` managed by Ubuntu Home Manager.

## Shared Codex conversations

The Ubuntu-WSL profile uses one logical Codex home for the Windows Codex
GUI and the WSL CLI:

- `CODEX_HOME=$WINHOME/.codex` keeps GUI settings, auth, plugins,
  conversation rollouts, history, rules, and memories in the Windows home.
- `CODEX_SQLITE_HOME=$HOME/.codex/sqlite` keeps the live SQLite indexes on
  WSL ext4, where SQLite locking and WAL behavior are reliable.

Do not symlink a live SQLite database across the WSL/Windows boundary. Also use
one active writer at a time: finish or stop the CLI before opening the GUI for
work, and close the GUI before starting a writing CLI session.

When importing a pre-existing WSL Codex home, close the Codex GUI and every
Codex CLI. From a plain WSL terminal, run:

```sh
~/.dotfiles/scripts/dotctl codex-share preflight
~/.dotfiles/scripts/dotctl codex-share migrate
```

The migration refuses to start while either client is running. It preserves the
Windows settings, imports the WSL conversation payloads and supporting history,
memories, goals, and rules, rewrites the thread index to the shared Windows
paths, and retains complete timestamped Windows and WSL rollback homes. Validate
the shared layout afterward with:

```sh
dotctl codex-share doctor
```

The Windows GUI already launches its backend inside WSL when
`desktop.runCodexInWindowsSubsystemForLinux` is enabled. The environment above
also makes ordinary Ubuntu Codex CLI sessions use the same home and index.

Rollback archives must remain in place until the shared layout has been used
successfully from both clients and is explicitly approved for cleanup.

## 1Password model

The Windows 1Password app owns SSH authentication for WSL. In 1Password, turn on
**Settings > Developer > Use the SSH Agent** and keep 1Password running in the
notification area. The native Windows OpenSSH Authentication Agent service must
remain stopped and disabled so 1Password can own the system-wide agent pipe.

Git is configured to invoke Windows `ssh.exe` directly, including for
non-interactive callers such as Codex Desktop. Interactive WSL shells expose the
same Windows OpenSSH commands through their usual `ssh`, `scp`, `sftp`, and
`ssh-add` names. Verify the bridge and GitHub authentication with:

```sh
ssh-add -l
ssh -T git@github.com
```

Shell startup intentionally avoids interactive authentication. Use these
commands directly when needed:

```sh
op vault list
gh auth login --web -h github.com
```
