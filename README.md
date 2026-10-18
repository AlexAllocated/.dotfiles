# Portable personal environments

## Maintenance and system map

The supported daily environments are **Tracer NixOS** and the **managed work Mac**. Native Nix configuration and Brewfiles remain the source of truth. The catalog explains custom behavior and links it to its source, startup, side effects, and verification procedure.

```sh
dotctl map
dotctl catalog slack
dotctl inspect slack-presence
dotctl status
dotctl status --refresh
dotctl patches
dotctl storage --refresh
```

Updates are prepared separately from application:

```sh
dotctl prepare system    # isolated candidate, full checks, draft PR
updoot                   # review one candidate, then confirm merge and application
```

Other groups are `os-release`, `drivers`, `desktop`, `editor`, and `mac`. Some changes require a manual or hardware review; a hold is reported explicitly. Your working checkout is not automatically stashed or committed. Cached status works offline; every inspection command accepts `--json`. Schedules start disabled pending acceptance on both supported hosts.

See [the maintenance guide](docs/maintenance.md) for the complete command map, protected artifacts, patch retirement, and migration from the old Updoot workflow.

This repository builds a consistent shell and developer environment across
Ubuntu WSL, generic Linux, NixOS, and macOS. Nix is the primary configuration engine,
Home Manager provides reusable user-level capabilities, and Homebrew supports
company-managed Macs where Nix is unavailable.

The final pre-Nix version is preserved by the `pre-nix` tag.

## Profiles

| Profile         | Configuration owner         | Intended use                                 |
| --------------- | --------------------------- | -------------------------------------------- |
| `tracer`        | NixOS + Home Manager        | Supported gaming and development workstation |
| `macos-managed` | Homebrew + repository links | Supported company Mac without Nix            |
| `chev-desktop`  | NixOS + Home Manager        | Retained predecessor desktop configuration   |
| `ubuntu-wsl`    | Home Manager                | Legacy Windows development compatibility     |
| `linux`         | Home Manager                | Legacy standalone Linux compatibility        |
| `macos`         | Home Manager                | Legacy personal Mac without nix-darwin       |
| `darwin-macos`  | nix-darwin + Home Manager   | Legacy personal Mac with nix-darwin          |

Flake outputs use `ubuntu-wsl`, `linux`, and `macos-arm64` for Home Manager.
The shorter macOS profile names remain as compatibility aliases.

On supported hosts, `dotctl` detects the native profile. Routine maintenance is:

```sh
dotctl status
dotctl prepare system # use mac on the managed Mac
updoot
dotctl status --refresh
```

Preparation starts from the canonical branch in a dedicated worktree, checks one
update group, and publishes a draft PR. Updoot verifies that candidate and its CI,
asks for confirmation, then merges and applies the exact merged source. Failed
preparation keeps its logs and leaves the active environment alone. Use
`dotctl retry <id>` to resume a candidate. `dotctl update <group>` is a prepare
alias; `dotctl apply --update` is an Updoot alias.

`dotctl apply <profile>` applies a clean committed source without discovering
new versions. Legacy profiles remain explicit compatibility operations; they do
not participate in scheduled preparation. Ubuntu WSL application still reconciles
the Windows applications in `platforms/windows/winget.json` through WinGet.

The `editor` group prepares and tests Lazy plugins, exact Mason versions and
registry, and Treesitter parsers in isolated XDG directories. Accepted editor
releases retain their source and locks; ordinary Neovim startup uses that accepted
source. Use `dotctl prepare editor` on Tracer to propose updates. The managed Mac
has separate locks with its existing editor policy preserved.

## Fast setup

Clone over HTTPS so first setup does not depend on an SSH agent:

```sh
git clone --filter=blob:none https://github.com/AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
```

Configure your machine-local Git author identity before preparing a candidate.
Shared behavior lives in `.gitconfig`; author name and email belong in
`~/.config/git/identity`. Legacy profile application can prompt for missing
identity or read `DOTFILES_GIT_NAME` and `DOTFILES_GIT_EMAIL`.

### Ubuntu WSL

From an existing WSL distribution:

```sh
cd ~/.dotfiles
./dot-bootstrap ubuntu-wsl
```

The bootstrap installs Ubuntu 26.04 beside the existing distribution, creates
the `alx` account, installs Determinate Nix, and activates standalone Home
Manager. Subsequent generations apply live:

```sh
dotctl apply ubuntu-wsl
```

Run `dotctl doctor` afterward. See
[`docs/nix-wsl-rollout.md`](docs/nix-wsl-rollout.md) for Windows links and the
optional shared Codex conversation migration.

### Native NixOS

Tracer is the supported workstation. Apply a reviewed, committed configuration
with `./scripts/dotctl apply tracer`; use the separate update groups above for
routine maintenance. The older `chev-desktop` profile and its installer remain
available for recovery and compatibility.

The native profiles use the open NVIDIA kernel module, PipeWire, Steam/Proton,
Sunshine/NVENC, WiVRn, and ALVR. Host-specific boot and storage configuration
lives under `hosts/tracer/` and `hosts/chev-desktop/`.

On `tracer`, Fantasy Grounds uses its official native Linux client. Enable it
with `dotfiles.gaming.fantasyGrounds.enable`; the `fantasy-grounds` package is
also available directly from the flake. Nix pins the bootstrap installer and
runtime dependencies, and the vendor updater maintains the writable client in
`~/.smiteworks/fantasygrounds`. Open **Fantasy Grounds** from the app launcher
to finish account setup and download the client and content. Use **Fantasy
Grounds Updater** or `fantasy-grounds --update` for subsequent updates. Campaigns,
content, and account settings remain local and are preserved across Nix changes.

WezTerm is the default terminal and Alacritty remains installed as the fast,
minimal alternative. Both use the BigBlueTerm Nerd Font and Gruvbox Dark
palette.
Konsole gets a non-destructive managed profile with the same font and palette.
Tmux is available everywhere with its stock `Ctrl+B` bindings, plus portable
true color, clipboard forwarding, mouse scrolling, and extended scrollback.
On `chev-desktop`, ordinary local and SSH tmux commands share one system-owned
server, so sessions survive compositor, terminal, and user-service restarts.
Run `tmux-cheatsheet` for the local quick reference.

SDDM starts the `dotfiles-desktop` dispatcher, which remembers the chosen
desktop. Niri + Noctalia is the canonical session and recovery fallback;
Mango + Noctalia and Niri + DMS are also available. Use `desktop-switch --help`
to inspect the supported switches. Common Noctalia bindings are
`Super+Return` for WezTerm, `Super+Space` for the launcher,
`Super+Shift+D` for the fallback launcher, and `Super+Shift+E` for the session
menu. `Ctrl+Alt+Delete` restarts the current experimental session if the shell
fails. Mango remaps its upstream `Super+M` quit binding to minimize the focused
window instead. Display layout and recovery behavior are host-specific; see
`dotctl catalog display` and [the Sunshine display policy](docs/sunshine-display-policy.md).
First-run Noctalia settings select Gruvbox Dark and hide lock, suspend, and
hibernate until the workstation password has been intentionally set and
tested.

Sunshine runs as a persistent system service and selects an available KMS
capture output according to the host's display policy. Its fallback display
keeps Moonlight available as a remote recovery path.

Build the local-first internal installer with:

```sh
nix build path:.#chev-installer-iso
nix build path:.#chev-installer-fat32-check
```

The image embeds this flake plus the confirmation-gated installation and Codex
handoff tools. See
[`docs/chev-desktop-migration.md`](docs/chev-desktop-migration.md) for the
storage contract, operator commands, and versioned capsule format.

### Managed macOS

```sh
cd ~/.dotfiles
./scripts/dotctl prepare mac
./scripts/updoot
exec zsh -l
```

The tracked `platforms/macos-managed/Brewfile` declares host software and
`platforms/macos/Brewfile` declares shared GUI apps. Homebrew owns global tools,
runtimes, Neovide, WezTerm, 1Password, and Claude Code. This
company profile excludes Codex desktop/CLI and AI editor extras. Mise is available
for project-local runtime versions but does not own global tools. Personal Mac
apps belong in `platforms/macos-personal/Brewfile`.

Preparation requires Python 3, Homebrew, Git, and authenticated GitHub CLI.
It records exact package versions, recipes and artifacts for review. Once a
reviewed `platforms/macos-managed/review.json` is committed, plain
`./scripts/dotctl apply macos-managed` can apply it. The existing mutable
`wezterm@nightly` channel is reported as a manual hold; ordinary reviewed packages
can still apply. A failed deterministic update needs local Claude/manual repair.

After reviewing a committed editor revision, apply its managed variant with
`./scripts/dotctl apply --group editor macos-managed`. See the
[maintenance guide](docs/maintenance.md) for native host acceptance and schedules.
Retired Docker workshop data is preserved; this workflow does not purge it.

### Linux or macOS with Nix

```sh
./dot-bootstrap linux # use macos on macOS
# Open a new shell after Nix installation.
./scripts/dotctl apply linux
```

Use `macos` instead of `linux` for a Home Manager-only Apple Silicon Mac. On a
personal Mac using nix-darwin, apply `darwin-macos`. Native Linux installs
Neovide, WezTerm, and 1Password through Nix. OpenAI currently publishes the
Codex desktop app for Windows and macOS; the native NixOS desktop profile also
installs OpenAI's ChatGPT desktop app with Codex (`chatgpt` in the terminal).
The Linux app is packaged in `packages/chatgpt-desktop.nix`, with versioned
official downloads and SHA-256 hashes in `pins/chatgpt-desktop.json`. NixOS is
not an officially supported upstream distro. `dotctl prepare desktop` proposes
that pin update; Updoot applies the reviewed result. The personal Codex CLI has
its own pin, updated by the `system` group.

## Capabilities

The reusable Home Manager API is identity-neutral:

```nix
{
  inputs.dotfiles.url = "github:AlexAllocated/.dotfiles";

  outputs = { home-manager, nixpkgs, dotfiles, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        dotfiles.homeModules.shell
        dotfiles.homeModules.git
        dotfiles.homeModules.nvim
        dotfiles.homeModules.codex
        {
          home.username = "me";
          home.homeDirectory = "/home/me";
          home.stateVersion = "26.05";
        }
      ];
    };
  };
}
```

Available modules:

- `foundation`: core command-line utilities
- `shell`: zsh, Powerlevel10k, navigation, and shell integrations
- `git`: Git, Delta, and Lazygit without an embedded author identity
- `nvim`: the complete Neovim configuration and runtime dependencies
- `neovide`: native Neovide, BigBlueTerm Nerd Font, and shared GUI settings
- `codex`: Codex, Bun, and Node; user settings, plugins, MCP servers, and rules stay machine-local
- `development`: compilers, language runtimes, formatters, and build tools
- `cloud`: Kubernetes and cloud CLIs
- `terminal`: Alacritty, WezTerm, Konsole styling, and portable tmux
- `compositors`: niri/Mango configs, desktop shell integrations, and portable output policy
- `windows`: Windows-side link helper
- `default`: the complete workstation composition

`nixosModules.compositors` provides the desktop dispatcher and the Niri + Noctalia,
Niri + DMS, and Mango + Noctalia display-manager sessions. The retained WSL
configuration uses the standalone `homeConfigurations.ubuntu-wsl` output.

Consumers set their own `home.stateVersion`, username, home directory, and Git
identity.

## Containers

Containers are distribution and emergency-repair artifacts, not the recommended
daily workstation boundary.

```sh
nix build .#docker-linux
nix build .#docker-pocket-knife
docker load < result
```

The full image contains the workstation toolset. The smaller pocket knife keeps
the shell, Git, Neovim, Codex, and practical repair utilities. Both use the
neutral `dev` user and are published for AMD64 and ARM64 Linux:

```sh
docker run --rm -it -v "$PWD:/work" \
  ghcr.io/alexallocated/dotfiles-pocket-knife:latest
```

Commit-addressed `sha-<commit>` tags are published alongside `latest`.

## Development

```sh
nix develop
nix fmt
dotctl check
dotctl catalog --validate
python3 -m unittest discover -s tests -p 'test_dotctl*.py'
```

`dotctl check` performs catalog validation and the complete native Tracer build.
Use `dotctl check mac` on the managed Mac and `dotctl check editor` for isolated
editor validation. Flake checks cover formatting and evaluation, ShellCheck, Bash
and Lua syntax, Stylua, Python compilation and tests, catalog coverage, and the
public Home Manager module API. CI also runs container smoke tests.

The Ubuntu-WSL profile also reconciles the Windows side of the workstation. It
installs or updates WezTerm, Neovide, and the official ChatGPT/Codex desktop app
through WinGet; installs the locked BigBlueTerm Nerd Font; deploys Neovide
settings; maintains WSL-backed application links; and registers terminal
Neovim and Neovide with Windows and Codex's **Open with** menu. Neovide is the
Codex default.

Existing Windows files are backed up before replacement. The link reconciler
can still be run directly for troubleshooting:

```powershell
pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName Ubuntu-26.04
```

Codex CLI and desktop share the Windows Codex home while keeping SQLite on WSL
ext4. The profile maintains only the required Windows/WSL routing and editor
handler fields. Model preferences, TUI settings, plugins, MCP servers, rules,
auth, conversations, and runtime state stay machine-local. Migrating
pre-existing separate conversation stores remains an explicit
`dotctl codex-share migrate` operation because both clients must be closed.

Neovide is installed Windows-native and starts Neovim in the default WSL
distro; do not install the Linux Neovide package for this workflow.

Shared Git behavior is tracked in `.gitconfig`; author identity stays in
`~/.config/git/identity`. Optional machine-only Git overrides belong in
`~/.config/git/local`.
