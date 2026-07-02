# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix` is the primary configuration entrypoint. NixOS-WSL is the first-class host; Home Manager handles shared user config; nix-darwin handles macOS.
- `modules/home/`, `modules/nixos/`, and `modules/darwin/` hold reusable Nix modules. `docs/nix-wsl-rollout.md` documents the side-by-side WSL rollout.
- Legacy scripts `install.sh` and `create-symlinks.sh` remain as the pre-Nix reference path; the `pre-nix` tag is the final old-structure checkpoint.
- `dot-bootstrap` and `scripts/dotctl` are the new bootstrap and maintenance entrypoints. Docker helpers `devenv.sh` and `nvim.sh` remain for container validation.
- Editor configs live in `nvim/` (LazyVim-based Lua modules) and `wezterm/` (terminal profiles and color schemes). Auxiliary configs sit in `komorebi/`.
- Assets are under `images/`; helper binaries land in `bin/`. Root-level config files (`.zshrc`, `.wezterm.lua`, `.gitconfig`) mirror their home-directory targets.

## Build, Test, and Development Commands

- `dotctl check` runs the flake checks when Nix is available.
- `dotctl apply nixos-wsl` installs the next NixOS-WSL boot generation from inside the `NixOS` distro; restart the distro afterward.
- `dotctl apply --update` updates flake inputs and reapplies the detected profile; `updoot` aliases to this in the Home Manager shell.
- `./dot-bootstrap nixos-wsl` installs the side-by-side `NixOS` WSL distro from the current Ubuntu control-plane distro.
- `./create-symlinks.sh` backs up existing dotfiles to `~/.backup_dotfiles/` and updates symlinks—run after any structural change.
- `./devenv.sh [path]` rebuilds the full `chevcast/devenv:latest` image and optionally mounts a workspace for interactive validation.
- `./nvim.sh [path]` rebuilds the slim `chevcast/nvim:latest` image for editor-only smoke tests.

## Coding Style & Naming Conventions

- Shell scripts stay POSIX-friendly but use Bash features; match tab-indented blocks as seen in existing scripts.
- Nix modules use tabs like the surrounding repo and keep host-specific behavior in the matching `modules/*/` layer.
- Lua files follow `stylua.toml` (tabs, width 3, 120-column wrap). Run `stylua .` inside `nvim/` before committing.
- TypeScript/Markdown snippets follow `prettier.config.js` (tabs, width 3, trailing commas disabled). Use `npx prettier --check .`.
- Rust snippets honor `rustfmt.toml` (hard tabs, grouped imports). Format with `rustfmt` when touching Rust files.

## Testing Guidelines

- For Nix changes, run `nix flake check` or `dotctl check` once Nix is available. For the WSL target, also run `sudo nixos-rebuild build --flake .#nixos-wsl` or `sudo nixos-rebuild boot --flake .#nixos-wsl`.
- For Neovim config updates, run `nvim --headless "+Lazy! sync" +qa` inside the `./nvim.sh` container to catch plugin errors.
- WezTerm changes should be loaded with `wezterm start --config-file $PWD/.wezterm.lua` to verify profiles.
- After modifying symlink lists, rerun `./create-symlinks.sh` and inspect `~/.backup_dotfiles/` for unintended moves.

## Commit & Pull Request Guidelines

- Keep commit summaries short and in present tense (e.g., `plugin updates`). Add Conventional Commit prefixes when clarifying scope (`fix: Update for Ubuntu WSL distro`).
- Group related changes; avoid mixing Neovim, terminal, and OS-specific tweaks in a single commit.
- Pull requests need a short description, validation notes (commands run), and screenshots when UI themes or prompt visuals change.
- Link GitHub issues when applicable and call out platform-specific impacts (Linux, macOS, WSL).

## Environment & Security

- Never commit personal secrets or machine-specific IDs; use placeholders and document required env vars in `README.md`.
- Prefer testing destructive commands (package installs, symlink cleanup) inside the Docker images before running on a host system.

## 1Password SSH Agent

- Enable the SSH agent inside the 1Password desktop app (macOS, Linux, or Windows) and confirm it lists your keys with `ssh-add -l` before bootstrapping these dotfiles.
- `install.sh` links `~/.1password/agent.sock` to the platform-specific agent socket so `SSH_AUTH_SOCK` can point at a stable path across macOS and Ubuntu, and ensures the Windows `~/.ssh/known_hosts` directory exists for WSL sessions.
- `.zshrc` exports `SSH_AUTH_SOCK=$HOME/.1password/agent.sock` on macOS/Linux and, on WSL, unsets it while wrapping `ssh`, `scp`, and `sftp` to call their Windows counterparts with `StrictHostKeyChecking=accept-new` and setting `GIT_SSH_COMMAND="ssh.exe -o StrictHostKeyChecking=accept-new"` so the first connection never blocks on host-key prompts.
