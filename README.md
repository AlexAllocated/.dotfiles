# Alex's .dotfiles

Personal environment automation for Linux, WSL, and macOS. The current repo is
Nix-first: NixOS-WSL is the primary host, Home Manager owns shared user config,
and nix-darwin owns macOS host integration.

The final commit before the Nix rewrite is tagged `pre-nix`.

## Architecture

- `flake.nix` is the entrypoint for all supported profiles.
- `homeModules.*` exposes thin, reusable Home Manager modules for shell, Git,
  Neovim, Codex, cloud CLIs, terminal config, Windows helpers, and shared
  packages.
- `modules/nixos/` holds NixOS-WSL host configuration.
- `modules/home/` holds shared Home Manager user configuration.
- `modules/darwin/` holds macOS host configuration through nix-darwin.
- `modules/docker/` holds Linux container image definitions built by Nix.
- `nvim/`, `wezterm/`, and `komorebi/` hold mutable app configuration linked
  into place by Home Manager or the Windows link script.
- `dot-bootstrap` installs the side-by-side NixOS WSL distro.
- `scripts/dotctl` is the day-to-day maintenance command.

The NixOS-WSL profile uses `alex` as the default Linux user.

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
dotctl apply linux
dotctl apply --update
nix run .#dotctl -- doctor
```

`dotctl apply --update` is the Nix-era `updoot`. It refreshes repo-managed
pins, runs the flake checks, applies the detected profile, and leaves changed
lockfiles in the checkout for review:

```sh
nix flake update --flake "$HOME/.dotfiles"
nvim --headless "+Lazy! update" +qa
nix flake check "$HOME/.dotfiles"
sudo nixos-rebuild boot --flake "$HOME/.dotfiles#nixos-wsl"
```

On Linux Home Manager and macOS hosts, the final apply command becomes
`home-manager switch --flake "$HOME/.dotfiles#linux"` or
`darwin-rebuild switch --flake "$HOME/.dotfiles#macos"`.

Profile names:

- `nixos-wsl`
- `linux`
- `macos`
- `macos-intel`

Reusable modules can be imported individually from this flake, for example:

```nix
inputs.dotfiles.homeModules.nvim
inputs.dotfiles.homeModules.codex
```

Shell startup does not authenticate external services. Run tools such as `op`
or `gh auth login` explicitly when credentials need attention.

## Containers

The flake builds two Linux images:

```sh
nix build .#docker-linux
nix build .#docker-pocket-knife
```

Load a local build with:

```sh
docker load < result
```

The pocket-knife image is for quick repair work on a machine without your usual
tools:

```sh
docker run --rm -it \
  -v "$PWD:/work" \
  ghcr.io/alexallocated/dotfiles-pocket-knife:latest
```

Published image names:

- `ghcr.io/alexallocated/dotfiles-linux:latest`
- `ghcr.io/alexallocated/dotfiles-pocket-knife:latest`

The Dockerfiles under `docker/` are thin extension entrypoints. The canonical
image definitions live in Nix.

## Windows Links

Windows-side application shortcuts are managed separately from Home Manager:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
```

That script points Windows WezTerm, Neovim, komorebi, and whkd config locations
at the files inside the WSL distro.
