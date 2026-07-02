# Chev's .dotfiles

Personal environment automation for Linux, WSL, and macOS. The current repo is
Nix-first: NixOS-WSL is the primary host, Home Manager owns shared user config,
and nix-darwin owns macOS host integration.

The final commit before the Nix rewrite is tagged `pre-nix`.

## Architecture

- `flake.nix` is the entrypoint for all supported profiles.
- `modules/nixos/` holds NixOS-WSL host configuration.
- `modules/home/` holds shared Home Manager user configuration.
- `modules/darwin/` holds macOS host configuration through nix-darwin.
- `nvim/`, `wezterm/`, and `komorebi/` hold mutable app configuration linked
  into place by Home Manager or the Windows link script.
- `dot-bootstrap` installs the side-by-side NixOS WSL distro.
- `scripts/dotctl` is the day-to-day maintenance command.

## Bootstrap

Install the side-by-side NixOS WSL distro from an existing WSL control-plane
distro:

```sh
./dot-bootstrap nixos-wsl
```

Then, inside the new NixOS distro:

```sh
git clone git@github.com:AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
sudo nixos-rebuild boot --flake .#nixos-wsl
dotctl doctor
```

See `docs/nix-wsl-rollout.md` for the full WSL rollout and cutover notes.

## Maintenance

```sh
dotctl check
dotctl apply nixos-wsl
dotctl apply --update
dotctl agents
dotctl secrets
```

Profile names:

- `nixos-wsl`
- `wsl-ubuntu`
- `ubuntu`
- `generic-linux`
- `macos`
- `macos-intel`

Shell startup does not authenticate external services. Run `op`, `gh auth login`,
or `dotctl secrets` explicitly when credentials need attention.

## Windows Links

Windows-side application shortcuts are managed separately from Home Manager:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
```

That script points Windows WezTerm, Neovim, komorebi, and whkd config locations
at the files inside the WSL distro.
