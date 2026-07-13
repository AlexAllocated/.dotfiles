# Portable personal environments

This repository builds a consistent shell and developer environment across
NixOS-WSL, generic Linux, and macOS. Nix is the primary configuration engine,
Home Manager provides reusable user-level capabilities, and Homebrew supports
company-managed Macs where Nix is unavailable.

The final pre-Nix version is preserved by the `pre-nix` tag.

## Profiles

| Profile         | Configuration owner         | Intended use                                  |
| --------------- | --------------------------- | --------------------------------------------- |
| `nixos-wsl`     | NixOS + Home Manager        | Primary Windows development environment       |
| `linux`         | Home Manager                | Ubuntu and other Linux distributions with Nix |
| `macos-managed` | Homebrew + repository links | Macs where `/nix` cannot be installed         |
| `macos`         | Home Manager                | Apple Silicon Macs without nix-darwin         |
| `darwin-macos`  | nix-darwin + Home Manager   | Personally managed Apple Silicon Macs         |

Flake outputs use `wsl`, `linux`, and `macos-arm64` consistently inside their
respective NixOS, Home Manager, and nix-darwin namespaces. The shorter macOS
profile names remain as compatibility aliases.

`dotctl` detects the normal profile automatically, so routine maintenance is:

```sh
dotctl apply
updoot
dotctl doctor
```

`updoot` is an alias for `dotctl apply --update`. Updates happen in a staging
checkout with isolated Neovim state. Before staging, local changes are saved,
the branch is rebased onto its latest upstream, and the local changes are
restored. New lockfiles are accepted only after Neovim automation and all-system
Nix evaluation succeed. Neovim, Lazy, Mason, and Treesitter progress is streamed
directly to the terminal. The isolated phase updates only Lazy plugin pins;
installed Mason tools and Treesitter parsers are updated once in the persistent
runtime after validation. After applying, `updoot` commits every outstanding
change and fetches again. Any late upstream changes are rebased, validated, and
reapplied before the current branch is pushed. `dotctl update` refreshes pins
without applying, committing, or pushing them.

Interactive Lazy updates write to `nvim/lazy-lock.json` in a writable
`DOTFILES_ROOT` or `~/.dotfiles` checkout. When the Neovim module is consumed
without a checkout, Lazy uses a writable lockfile under Neovim's state directory
instead of the immutable Home Manager configuration.

## Fast setup

Clone over HTTPS so first setup does not depend on an SSH agent:

```sh
git clone --filter=blob:none https://github.com/AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
```

The first apply prompts for a machine-local Git author name and email. For
unattended setup, set `DOTFILES_GIT_NAME` and `DOTFILES_GIT_EMAIL`.

### NixOS-WSL

From an existing WSL distribution:

```sh
cd ~/.dotfiles
./dot-bootstrap nixos-wsl
```

The bootstrap downloads a pinned NixOS-WSL image, verifies its checksum, and
installs it beside the existing distribution. Inside the new distribution:

```sh
git clone --filter=blob:none https://github.com/AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
sudo nixos-rebuild boot --flake .#wsl
wsl.exe -t NixOS
```

After reopening NixOS, run `dotctl doctor`. See
[`docs/nix-wsl-rollout.md`](docs/nix-wsl-rollout.md) for Windows links and the
optional shared Codex conversation migration.

### Managed macOS

```sh
cd ~/.dotfiles
./scripts/dotctl apply macos-managed
exec zsh -l
```

The tracked `platforms/macos-managed/Brewfile` declares host software. Homebrew
owns global tools and runtimes; Bun owns npm-registry CLIs such as Codex. Mise is
available for project-local runtime versions but does not own global tools.

### Linux or macOS with Nix

```sh
./dot-bootstrap linux # use macos on macOS
# Open a new shell after Nix installation.
./scripts/dotctl apply linux
```

Use `macos` instead of `linux` for a Home Manager-only Apple Silicon Mac. On a
personal Mac using nix-darwin, apply `darwin-macos`.

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
- `codex`: Codex, Bun, Node, and reusable sanitized configuration
- `development`: compilers, language runtimes, formatters, and build tools
- `cloud`: Kubernetes and cloud CLIs
- `terminal`: WezTerm configuration
- `windows`: Windows-side link helper
- `default`: the complete workstation composition

`nixosModules.wsl` exposes the host module with neutral defaults; set
`dotfiles.wsl.user` and `dotfiles.wsl.userDescription` in the consuming NixOS
configuration.

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
```

Checks cover Nix formatting and evaluation, ShellCheck, Bash syntax, Lua syntax,
Stylua, Python compilation, the public Home Manager module API, and container
smoke tests in CI.

Windows-side application links are applied separately and existing files are
backed up before replacement:

```powershell
pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName NixOS
```

Shared Git behavior is tracked in `.gitconfig`; author identity stays in
`~/.config/git/identity`. Optional machine-only Git overrides belong in
`~/.config/git/local`.
