# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix` is the primary Nix entrypoint. Tracer NixOS and the managed work Mac are the active supported hosts. Windows/WSL, generic Linux, personal macOS and containers retain legacy compatibility paths. `macos-managed` in `scripts/dotctl` is the host-native company Mac path when Nix is not allowed.
- `modules/home/`, `modules/nixos/`, `modules/darwin/`, and `modules/docker/` hold reusable Nix modules. `homeModules.*` is the public Home Manager module API. `docs/nix-wsl-rollout.md` documents the side-by-side WSL rollout.
- `dot-bootstrap` installs and bootstraps the side-by-side `Ubuntu-26.04` WSL distro from an existing control-plane distro.
- `scripts/dotctl` invokes the standard-library Python controller in `scripts/dotfiles/`. Native operations use `scripts/maintenance-adapter.sh`. Existing helpers under `scripts/commands/` and `scripts/profiles/` remain compatibility code, not the update orchestrator.
- The Ubuntu-WSL profile uses `alx` as the default Linux user.
- Editor configs live in `nvim/` (LazyVim-based Lua modules), `neovide/` (native and Windows-WSL GUI profiles), and `wezterm/` (terminal profiles and color schemes). Auxiliary Windows configs live in `komorebi/`.
- Reusable package capabilities are defined once in `lib/toolsets.nix`; host-native manifests live under `platforms/`. Shared Mac apps are separate from managed and personal additions. Helper binaries land in `bin/`.

## Build, Test, and Development Commands

- `dotctl check` validates the catalog and builds the complete native Tracer system. Use `dotctl check mac` on the managed Mac and `dotctl check editor` for an isolated editor restore.
- `dotctl apply ubuntu-wsl` activates Home Manager live and reconciles Windows host applications through WinGet.
- `dotctl apply linux` applies the generic Linux Home Manager profile.
- `dotctl prepare mac` creates the managed Mac's exact package review manifest. `dotctl apply macos-managed` applies a committed, reviewed manifest and configuration links without Nix. Use `dotctl apply --group editor macos-managed` to apply a reviewed editor revision separately.
- `dotctl prepare <group>` prepares and validates an isolated candidate and publishes a draft PR. `updoot [candidate]` reviews one candidate, merges after confirmation, and applies its validated source. `dotctl apply --update` is its compatibility alias. Never stash, reset, or commit unrelated developer work.
- `dotctl map`, `catalog`, `inspect`, `status`, `patches`, and `storage` expose intent and evidence. Cached status never runs network requests. Use `--refresh` explicitly.
- `dotctl apply <profile>` requires a clean committed source and performs no version discovery. Never call the old coupled `apply_with_update` path.
- `./dot-bootstrap ubuntu-wsl` installs and configures the side-by-side Ubuntu WSL distro.
- `nix build .#docker-linux` builds the full Linux container image on AMD64 or ARM64 Linux.
- `nix build .#docker-pocket-knife` builds the slim repair container image.
- `pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName Ubuntu-26.04` updates Windows-side app links to the WSL repo copy.

## Coding Style & Naming Conventions

- Shell scripts stay POSIX-friendly but use Bash features; match tab-indented blocks as seen in existing scripts.
- Nix modules use tabs like the surrounding repo and keep host-specific behavior in the matching `modules/*/` layer.
- Lua files follow `stylua.toml` (tabs, width 3, 120-column wrap). Run `stylua .` inside `nvim/` before committing.
- Markdown snippets follow `prettier.config.js` (tabs, width 3, trailing commas disabled). Use `npx prettier --check .` when changing Markdown-heavy docs.
- Rust snippets honor `rustfmt.toml` (hard tabs, grouped imports). Format with `rustfmt` when touching Rust files.

## Testing Guidelines

- For Nix changes, run `nix flake check --all-systems` or `dotctl check` once Nix is available.
- On the native NixOS workstation, finish an approved configuration change by building and switching to the complete intended host generation (`tracer` on the current workstation), then verify the affected live behavior. Do not activate from a partial clean tree that omits related pending configuration. Never reboot without Alex's explicit approval.
- For the WSL target, run `home-manager build --flake .#ubuntu-wsl`.
- For the standalone Linux target, run `home-manager build --flake .#linux`.
- For container image changes, run `nix build .#docker-pocket-knife` and, when practical, `nix build .#docker-linux`.
- For Neovim config updates, run `dotctl check editor` to restore and validate both profile variants in isolated XDG directories on Tracer. After an approved editor application, verify an ordinary Neovim launch uses its accepted source. Do not update the active editor runtime during candidate preparation.
- WezTerm changes should be loaded with `wezterm start --config-file $PWD/.wezterm.lua` to verify profiles.
- After modifying Windows integration behavior, run `dotctl apply ubuntu-wsl` when practical. For a link-only check, run `pwsh ./scripts/windows/apply-wsl-links.ps1 -DistroName Ubuntu-26.04`, then inspect the links, editor registrations, and Codex handlers from Windows.

## Commit & Pull Request Guidelines

- Keep commit summaries short and in present tense (e.g., `plugin updates`). Add Conventional Commit prefixes when clarifying scope (`fix: Update WSL links`).
- Group related changes; avoid mixing Neovim, terminal, and OS-specific tweaks in a single commit.
- Pull requests need a short description, validation notes (commands run), and screenshots when UI themes or prompt visuals change.
- Link GitHub issues when applicable and call out platform-specific impacts (Linux, macOS, WSL).

## Environment & Security

- Never commit personal secrets or machine-specific IDs; use placeholders and document required env vars in `README.md`.
- On `macos-managed`, declare host tools and language runtimes in `platforms/macos-managed/Brewfile`. Preserve its existing Claude-only policy: no Codex desktop/CLI, AI editor extras, or Nix language extra. npm-registry CLI tools that are not Homebrew-managed use Bun, not npm globals. Mise is project-local only.
- Shared macOS GUI applications belong in `platforms/macos/Brewfile`; personal additions belong in `platforms/macos-personal/Brewfile`. Keep the nix-darwin cask list aligned with both personal inputs.
- Shell startup must not run interactive authentication. Keep 1Password, GitHub, and other credential refreshes behind explicit commands such as `op` or `gh auth login`.
- Codex user configuration is machine-local. The repo may install Codex and maintain required platform integration, but must not manage model preferences, plugins, MCP servers, rules, or other contents of `~/.codex/config.toml`.
- Git aliases and shared behavior are tracked, but Git author identity is local in `~/.config/git/identity`. Configure it before candidate preparation. Legacy profile application may prompt for missing identity or accept `DOTFILES_GIT_NAME` and `DOTFILES_GIT_EMAIL`.

## 1Password SSH Agent

- Enable the SSH agent inside the 1Password desktop app (macOS, Linux, or Windows) and confirm it lists your keys with `ssh-add -l` before bootstrapping these dotfiles.
- Home Manager exports `SSH_AUTH_SOCK=$HOME/.1password/agent.sock` on macOS/Linux when that stable socket path exists. `macos-managed` links that path to the 1Password desktop agent socket.
- On WSL, Home Manager unsets `SSH_AUTH_SOCK` and wraps `ssh`, `scp`, `sftp`, `ssh-add`, and `ssh-agent` to call their Windows counterparts when available. Git uses `GIT_SSH_COMMAND="ssh.exe -o StrictHostKeyChecking=accept-new"` so first-time host keys do not block unattended operations.

## Catalog and maintenance contract

- Every custom command, service, timer, desktop entry, alias, patch, fork and direct package has a catalog owner. Update `catalog/components.json`, `catalog/patches.json`, and the reviewed `catalog/surfaces.json` when behavior changes. Run `dotctl catalog --validate` and `python3 -m unittest discover -s tests -p 'test_dotctl*.py'`.
- Native Nix modules and Brewfiles remain authoritative. Catalog records explain purpose and lifecycle; do not duplicate package versions there. Group ordinary Nix imports under `modules/home/capabilities/`; retain public compatibility paths.
- Maintenance classification is independent of runtime health. Manual tools are on-demand; an unavailable host is unknown. Retired components retain searchable tombstones. Do not call patches obsolete merely because an upstream issue closed or a hunk stopped applying.
- Removing a patch requires evidence from the actual target build and its regression procedure, including hardware/application checks where applicable. Changed sources invalidate previous removal evidence.
- Artifact producers register owned outputs through `scripts/dotfiles/storage.py`. Unknown files, backups, archives and recovery capsules are protected. Only verified disposable scratch and terminal candidate worktrees may expire after their retention period; active source pointers, deployed groups, managed links and references protect retained sources. Cleanup revalidates ownership and contents before removal. Do not remove Nix store paths directly.
- Scheduled maintenance refreshes metadata and prepares bounded, isolated candidates. It never activates, merges, restarts services, reboots, or changes Codex preferences. At most two Codex repair passes may modify a failed group on Tracer; managed Mac failures request local Claude/manual repair. Tests, controller policy and features cannot be removed or weakened.
- Keep schedules disabled until the same committed baseline passes actual acceptance on Tracer and the managed Mac. A Linux mock of Homebrew is not native Mac acceptance.
- See `docs/maintenance.md` for command behavior, receipts, recovery and rollout gates.
