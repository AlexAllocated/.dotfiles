# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix` is the primary configuration entrypoint. NixOS-WSL is the first-class host; Home Manager handles shared user config; nix-darwin handles macOS.
- `modules/home/`, `modules/nixos/`, `modules/darwin/`, and `modules/docker/` hold reusable Nix modules. `homeModules.*` is the public Home Manager module API. `docs/nix-wsl-rollout.md` documents the side-by-side WSL rollout.
- `dot-bootstrap` installs the side-by-side `NixOS` WSL distro from an existing control-plane distro.
- `scripts/dotctl` is the maintenance entrypoint for checks, applies, updates, and diagnostics.
- The NixOS-WSL profile uses `alex` as the default Linux user.
- Editor configs live in `nvim/` (LazyVim-based Lua modules) and `wezterm/` (terminal profiles and color schemes). Auxiliary Windows configs live in `komorebi/`.
- Assets are under `images/`; helper binaries land in `bin/`. Root-level files are limited to active repo config and Home Manager sources.

## Build, Test, and Development Commands

- `dotctl check` runs the flake checks when Nix is available.
- `dotctl apply nixos-wsl` installs the next NixOS-WSL boot generation from inside the `NixOS` distro; restart the distro afterward.
- `dotctl apply linux` applies the generic Linux Home Manager profile.
- `dotctl apply --update` refreshes repo-managed pins, runs flake checks, and reapplies the detected profile; `updoot` aliases to this in the Home Manager shell.
- `./dot-bootstrap nixos-wsl` installs the side-by-side `NixOS` WSL distro.
- `nix build .#docker-linux` builds the full Linux container image.
- `nix build .#docker-pocket-knife` builds the slim repair container image.
- `pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName NixOS` updates Windows-side app links to the WSL repo copy.

## Coding Style & Naming Conventions

- Shell scripts stay POSIX-friendly but use Bash features; match tab-indented blocks as seen in existing scripts.
- Nix modules use tabs like the surrounding repo and keep host-specific behavior in the matching `modules/*/` layer.
- Lua files follow `stylua.toml` (tabs, width 3, 120-column wrap). Run `stylua .` inside `nvim/` before committing.
- Markdown snippets follow `prettier.config.js` (tabs, width 3, trailing commas disabled). Use `npx prettier --check .` when changing Markdown-heavy docs.
- Rust snippets honor `rustfmt.toml` (hard tabs, grouped imports). Format with `rustfmt` when touching Rust files.

## Testing Guidelines

- For Nix changes, run `nix flake check` or `dotctl check` once Nix is available.
- For the WSL target, run `sudo nixos-rebuild build --flake .#nixos-wsl` or `sudo nixos-rebuild boot --flake .#nixos-wsl`.
- For the standalone Linux target, run `home-manager build --flake .#linux`.
- For container image changes, run `nix build .#docker-pocket-knife` and, when practical, `nix build .#docker-linux`.
- For Neovim config updates, run `nvim --headless "+Lazy! sync" +qa` to catch plugin errors.
- WezTerm changes should be loaded with `wezterm start --config-file $PWD/.wezterm.lua` to verify profiles.
- After modifying Windows link behavior, run `pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName NixOS` and inspect the target links from Windows.

## Commit & Pull Request Guidelines

- Keep commit summaries short and in present tense (e.g., `plugin updates`). Add Conventional Commit prefixes when clarifying scope (`fix: Update WSL links`).
- Group related changes; avoid mixing Neovim, terminal, and OS-specific tweaks in a single commit.
- Pull requests need a short description, validation notes (commands run), and screenshots when UI themes or prompt visuals change.
- Link GitHub issues when applicable and call out platform-specific impacts (Linux, macOS, WSL).

## Environment & Security

- Never commit personal secrets or machine-specific IDs; use placeholders and document required env vars in `README.md`.
- Shell startup must not run interactive authentication. Keep 1Password, GitHub, and other credential refreshes behind explicit commands such as `op` or `gh auth login`.

## 1Password SSH Agent

- Enable the SSH agent inside the 1Password desktop app (macOS, Linux, or Windows) and confirm it lists your keys with `ssh-add -l` before bootstrapping these dotfiles.
- Home Manager exports `SSH_AUTH_SOCK=$HOME/.1password/agent.sock` on macOS/Linux when that stable socket path exists.
- The `macos-docker` profile installs the host 1Password desktop app and CLI when missing, mounts Docker Desktop's host SSH agent bridge at `/run/host-services/ssh-auth.sock`, then links `~/.1password/agent.sock` and the standard macOS 1Password agent path to that socket inside the container.
- On WSL, Home Manager unsets `SSH_AUTH_SOCK` and wraps `ssh`, `scp`, `sftp`, `ssh-add`, and `ssh-agent` to call their Windows counterparts when available. Git uses `GIT_SSH_COMMAND="ssh.exe -o StrictHostKeyChecking=accept-new"` so first-time host keys do not block unattended operations.
