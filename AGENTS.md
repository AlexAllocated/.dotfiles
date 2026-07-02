# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix` is the primary configuration entrypoint. NixOS-WSL is the first-class host; Home Manager handles shared user config; nix-darwin handles macOS.
- `modules/home/`, `modules/nixos/`, and `modules/darwin/` hold reusable Nix modules. `docs/nix-wsl-rollout.md` documents the side-by-side WSL rollout.
- `dot-bootstrap` installs the side-by-side `NixOS` WSL distro from an existing control-plane distro.
- `scripts/dotctl` is the maintenance entrypoint for checks, applies, updates, agent installs, and secret refreshes.
- Editor configs live in `nvim/` (LazyVim-based Lua modules) and `wezterm/` (terminal profiles and color schemes). Auxiliary Windows configs live in `komorebi/`.
- Assets are under `images/`; helper binaries land in `bin/`. Root-level files are limited to active repo config and Home Manager sources.

## Build, Test, and Development Commands

- `dotctl check` runs the flake checks when Nix is available.
- `dotctl apply nixos-wsl` installs the next NixOS-WSL boot generation from inside the `NixOS` distro; restart the distro afterward.
- `dotctl apply --update` updates flake inputs and reapplies the detected profile; `updoot` aliases to this in the Home Manager shell.
- `./dot-bootstrap nixos-wsl` installs the side-by-side `NixOS` WSL distro.
- `dotctl agents` installs or updates global Bun coding agents.
- `dotctl secrets` refreshes the repository `.env` from 1Password after the CLI is already authenticated.
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
- For Neovim config updates, run `nvim --headless "+Lazy! sync" +qa` to catch plugin errors.
- WezTerm changes should be loaded with `wezterm start --config-file $PWD/.wezterm.lua` to verify profiles.
- After modifying Windows link behavior, run `pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName NixOS` and inspect the target links from Windows.

## Commit & Pull Request Guidelines

- Keep commit summaries short and in present tense (e.g., `plugin updates`). Add Conventional Commit prefixes when clarifying scope (`fix: Update for Ubuntu WSL distro`).
- Group related changes; avoid mixing Neovim, terminal, and OS-specific tweaks in a single commit.
- Pull requests need a short description, validation notes (commands run), and screenshots when UI themes or prompt visuals change.
- Link GitHub issues when applicable and call out platform-specific impacts (Linux, macOS, WSL).

## Environment & Security

- Never commit personal secrets or machine-specific IDs; use placeholders and document required env vars in `README.md`.
- Shell startup must not run interactive authentication. Keep 1Password, GitHub, and other credential refreshes behind explicit commands such as `op`, `gh auth login`, or `dotctl secrets`.

## 1Password SSH Agent

- Enable the SSH agent inside the 1Password desktop app (macOS, Linux, or Windows) and confirm it lists your keys with `ssh-add -l` before bootstrapping these dotfiles.
- Home Manager exports `SSH_AUTH_SOCK=$HOME/.1password/agent.sock` on macOS/Linux when that stable socket path exists.
- On WSL, Home Manager unsets `SSH_AUTH_SOCK` and wraps `ssh`, `scp`, `sftp`, `ssh-add`, and `ssh-agent` to call their Windows counterparts when available. Git uses `GIT_SSH_COMMAND="ssh.exe -o StrictHostKeyChecking=accept-new"` so first-time host keys do not block unattended operations.
