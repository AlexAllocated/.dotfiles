{
  config,
  lib,
  pkgs,
  toolPkgs ? pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs toolPkgs; };
  codexPackage = if builtins.hasAttr "codex" toolPkgs then toolPkgs.codex else pkgs.codex;
  wslCodexHome = "/mnt/c/Users/${config.home.username}/.codex";
  desktopCodex = pkgs.writeShellApplication {
    name = "codex";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      # Durable tmux panes outlive compositor sessions. Text paste is handled
      # by the terminal, but Codex reads image data from the compositor's
      # clipboard itself, so refresh the display sockets before it starts.
      if [[ -n "''${TMUX:-}" ]]; then
        unset WAYLAND_DISPLAY DISPLAY XAUTHORITY
        while IFS= read -r entry; do
          case "$entry" in
            WAYLAND_DISPLAY=* | DISPLAY=* | XAUTHORITY=* | XDG_RUNTIME_DIR=* | DBUS_SESSION_BUS_ADDRESS=*)
              export "''${entry?}"
              ;;
          esac
        done < <(systemctl --user show-environment 2>/dev/null || true)

        if [[ -n "''${WAYLAND_DISPLAY:-}" && ! -S "''${XDG_RUNTIME_DIR:-/run/user/$UID}/$WAYLAND_DISPLAY" ]]; then
          unset WAYLAND_DISPLAY
        fi
      fi

      exec ${codexPackage}/bin/codex "$@"
    '';
  };
  wslCodex = pkgs.writeShellScriptBin "codex" ''
    export CODEX_HOME="''${CODEX_HOME:-${wslCodexHome}}"
    export CODEX_SQLITE_HOME="''${CODEX_SQLITE_HOME:-${config.home.homeDirectory}/.codex/sqlite}"
    exec ${codexPackage}/bin/codex "$@"
  '';
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages =
      if cfg.profile == "nixos-desktop" then
        [
          desktopCodex
          pkgs.bun
          pkgs.nodejs
        ]
      else if cfg.profile == "nixos-wsl" then
        [
          wslCodex
          pkgs.bun
          pkgs.nodejs
        ]
      else
        toolsets.agent;

    home.sessionVariables = lib.mkMerge [
      (lib.optionalAttrs
        (builtins.elem cfg.profile [
          "nixos-wsl"
          "nixos-desktop"
        ])
        {
          # Keep SQLite on the native Linux filesystem. WSL shares config/auth with
          # Windows; the native desktop imports a private migration copy at install.
          CODEX_SQLITE_HOME = "${config.home.homeDirectory}/.codex/sqlite";
        }
      )
      (lib.optionalAttrs (cfg.profile == "nixos-wsl") {
        # SSH logins do not inherit Windows' appended PATH, so discovery via
        # powershell.exe is not reliable there. The first-class WSL profile
        # deliberately uses the same account name on both sides.
        CODEX_HOME = wslCodexHome;
      })
    ];
  };
}
