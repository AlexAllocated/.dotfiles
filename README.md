# Alex's .dotfiles

Personal environment automation for Linux, WSL, and macOS. The current repo is
Nix-first: NixOS-WSL is the primary host, Home Manager owns shared user config,
and nix-darwin is available only for opt-in macOS host integration.

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

### macOS

This repo has three macOS tracks:

- `macos-docker`: company-managed Macs, with plain host shell startup, host
  WezTerm, and a locally built workshop container.
- `macos` / `macos-intel`: Home Manager-only profiles for Macs where Nix is
  allowed but nix-darwin is not.
- `darwin-macos` / `darwin-macos-intel`: nix-darwin system profiles for a Mac
  where this repo is allowed to manage host-level settings.

#### Company-managed Mac

Use the Docker-backed profile here. It does not install Nix on macOS or manage
system settings. The host stays intentionally minimal: Homebrew, 1Password,
WezTerm, Docker Desktop, a `dotctl` link, and WezTerm config. Shell startup,
prompt, Neovim, Codex, language tools, and the rest of the portable environment
live in the Linux container. If missing, the profile installs Homebrew,
1Password, 1Password CLI, WezTerm, and Docker Desktop, then uses a `nixos/nix`
builder container to build the managed workshop image from this checkout.

Bootstrap or refresh the host links, host dependencies, Docker Desktop, and the
managed container:

```sh
cd ~/.dotfiles
./scripts/dotctl apply macos-docker
./scripts/dotctl doctor
```

Enter the container:

```sh
~/.dotfiles/scripts/dotctl shell macos-docker
```

After first setup, `dotctl shell macos-docker` uses a fast path that starts the
existing managed container and enters zsh without re-running host provisioning.
Run `dotctl apply macos-docker` after pulling dotfiles changes or when host
links, sockets, imports, or container mounts need to be repaired.

`macos-docker` links only host `~/.wezterm.lua`, `~/.config/wezterm`, and
`~/.local/bin/dotctl` to this checkout. It removes repo-owned host shell and
developer config links from earlier installs so macOS Terminal opens a normal
host shell. WezTerm gets a `Dotfiles Docker` launch entry and, after the profile
marker is written, opens the Docker shell by default by calling
`~/.dotfiles/scripts/dotctl` directly through `/bin/bash`, so it does not depend
on host shell startup or `PATH`. Set `DOTFILES_WEZTERM_HOST_SHELL=1` before
launching WezTerm to force a host shell.

The managed container uses `dotfiles-workshop:local` by default. It mounts this
checkout at `~/.dotfiles` and the host `~/code` directory at container
`~/code`, then starts shells in `~/code`. Run `dotctl apply --update
macos-docker` to rebuild the local image from the current checkout and recreate
the container while preserving the Docker home volume. Override the image tag
with `DOTCTL_DOCKER_IMAGE`; override the mounted work tree with
`DOTCTL_DOCKER_WORK`, which must stay under the host home directory.
Container provisioning primes Neovim with pinned `Lazy restore`, `MasonUpdate`,
and `TSUpdateSync` whenever the repo Neovim config changes, so first interactive
`nvim` launch should not spend time installing plugins, Mason metadata, or
Treesitter parsers. Set `DOTCTL_DOCKER_PRIME_NVIM=0` to skip that step.

When Docker Desktop exposes its host SSH agent bridge, `macos-docker` mounts it
into the container at `/run/host-services/ssh-auth.sock` and links
`~/.1password/agent.sock` plus the standard macOS 1Password agent path to that
socket. This lets Git and SSH inside the container use the host 1Password SSH
agent and still prompt through the macOS desktop app. The profile installs the
desktop app and CLI if they are missing, but sign-in, Touch ID, CLI integration,
and SSH-agent enablement still happen in 1Password itself. Set
`DOTCTL_DOCKER_SSH_AUTH_SOCK=0` to disable the mount, or set it to a custom
host socket path before applying the profile. This only forwards the SSH agent;
direct Linux-container 1Password desktop integration is not attempted.

The profile also installs a small macOS user `launchd` service named
`com.alexallocated.dotfiles.hostd`. It listens on
`~/.local/share/dotfiles/hostd/hostd.sock`, and the managed container mounts
that runtime directory at `/run/host-services/dotfiles-hostd`. Inside the
container, use the allowlisted host command surface for host-only integrations:

```sh
dotctl host ping
dotctl host op account list
dotctl host op item get "Item Name" --fields label=username,password
```

`dotctl host op ...` runs the macOS host `op` binary so 1Password desktop app
integration, Touch ID, and company policy stay on the host. The socket does not
expose arbitrary host shell. Set `DOTFILES_HOSTD=0` before applying the profile
to skip hostd setup.

Inside the workshop, `updoot` maps to `dotctl workshop-update`. It leaves dirty
or untracked dotfiles changes alone, rebuilds `dotfiles-workshop:local` from the
current checkout when Docker is reachable, and then tells you to restart the
managed container from the host with `dotctl apply --recreate macos-docker`.
The first local build is large; the Nix builder store is cached in the Docker
volume `dotfiles-nix-builder-store`.

On first setup, the profile imports allowlisted host auth/config state into the
container home, including Codex auth/session state, SSH files, GitHub CLI
config, and common cloud CLI credential stores. Repo-managed files such as
shell startup, WezTerm, Neovim, and `codex/config.toml` remain linked from the
checkout. To re-run the import later:

```sh
dotctl import-host-state macos-docker
```

#### Mac With Nix

Use the Home Manager-only profile on Macs where Nix is allowed but host-level
nix-darwin management is not:

```sh
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
cd ~/.dotfiles
nix --extra-experimental-features "nix-command flakes" run github:nix-community/home-manager/release-26.05 -- switch -b hm-backup --flake "$PWD#macos"
```

#### Personal Mac

Use the nix-darwin profile on a Mac you own and are comfortable letting this
repo manage at the host level:

```sh
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
cd ~/.dotfiles
sudo /nix/var/nix/profiles/default/bin/nix --extra-experimental-features "nix-command flakes" run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake "$PWD#darwin-macos"
./scripts/dotctl doctor
```

After the first nix-darwin switch, day-to-day applies use:

```sh
dotctl apply darwin-macos
```

Homebrew cleanup is disabled in the nix-darwin profile so existing Homebrew
installs are not removed while packages are being migrated into Nix or declared
in `modules/darwin/default.nix`.

## Maintenance

```sh
dotctl check
dotctl apply nixos-wsl
dotctl apply linux
dotctl apply --update
nix run .#dotctl -- doctor
```

`dotctl apply --update` is the Nix-era `updoot`. It refreshes repo-managed
pins, refreshes Neovim's local plugin runtime, runs the flake checks, applies
the detected profile, and leaves changed lockfiles in the checkout for review:

```sh
nix flake update --flake "$HOME/.dotfiles"
DOTFILES_NVIM_AUTOMATION=1 nvim --headless "+set nomore" "+Lazy! update" "+MasonUpdate" "+TSUpdateSync" "+lua require(\"config.bootstrap\").wait_for_mason()" +qa
nix flake check "$HOME/.dotfiles"
sudo nixos-rebuild boot --flake "$HOME/.dotfiles#nixos-wsl"
```

On Linux Home Manager and macOS hosts, the final apply command becomes
`home-manager switch --flake "$HOME/.dotfiles#linux"` or
`home-manager switch --flake "$HOME/.dotfiles#macos"`. On a personal Mac using
nix-darwin, use `darwin-rebuild switch --flake "$HOME/.dotfiles#darwin-macos"`.

Profile names:

- `nixos-wsl`
- `linux`
- `macos-docker`
- `macos`
- `macos-intel`
- `darwin-macos`
- `darwin-macos-intel`

Reusable modules can be imported individually from this flake, for example:

```nix
inputs.dotfiles.homeModules.nvim
inputs.dotfiles.homeModules.codex
```

Shell startup does not authenticate external services. Run tools such as `op`
or `gh auth login` explicitly when credentials need attention.

## Git Identity

Shared Git behavior lives in the tracked `.gitconfig`, including aliases,
Delta settings, default branch behavior, and credential helpers. Machine- or
account-specific author identity is intentionally local. On first apply,
`dotctl` prompts for a Git author name and email, then writes:

```sh
~/.config/git/identity
```

For unattended setup, provide:

```sh
DOTFILES_GIT_NAME="Alex" DOTFILES_GIT_EMAIL="alex@example.com" dotctl apply
```

Optional machine-local Git overrides can live in `~/.config/git/local`; the
tracked config includes it when present. On `macos-docker`, the host identity
is copied into the managed container during provisioning.

## Containers

The flake builds two Linux images. `docker-linux` is the portable workshop
image: it includes the dotfiles source at `~/.dotfiles`, starts in `~/code`,
and links the default shell/editor/Codex config from that built-in source.
`docker-pocket-knife` is the smaller repair shell.

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

Try the published workshop directly:

```sh
docker run --rm -it ghcr.io/alexallocated/dotfiles-linux:latest
```

The Dockerfiles under `docker/` are thin extension entrypoints. The canonical
image definitions live in Nix.

## Windows Links

Windows-side application shortcuts are managed separately from Home Manager:

```powershell
.\scripts\windows\apply-wsl-links.ps1 -DistroName NixOS
```

That script points Windows WezTerm, Neovim, komorebi, and whkd config locations
at the files inside the WSL distro.
