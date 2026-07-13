# NixOS-WSL Rollout

NixOS is the primary WSL target.

## Install side-by-side

From an existing WSL control-plane distro:

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

The NixOS-WSL profile declares `alex` as the default user and home directory.
It also installs or upgrades the Windows applications in
`platforms/windows/winget.json` through WinGet.

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
