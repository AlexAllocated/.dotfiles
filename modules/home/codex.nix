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
  wslCodex = pkgs.writeShellScriptBin "codex" ''
    if [[ -z "''${CODEX_HOME:-}" ]] && command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
      windows_home="$(powershell.exe -NoLogo -NoProfile -Command '$env:UserProfile' 2>/dev/null | tr -d '\r')"
      if [[ -n "$windows_home" ]]; then
        export CODEX_HOME="$(wslpath -u "$windows_home")/.codex"
      fi
    fi
    export CODEX_SQLITE_HOME="''${CODEX_SQLITE_HOME:-${config.home.homeDirectory}/.codex/sqlite}"
    exec ${codexPackage}/bin/codex "$@"
  '';
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages =
      if cfg.profile == "nixos-wsl" then
        [
          wslCodex
          pkgs.bun
          pkgs.nodejs
        ]
      else
        toolsets.agent;

    home.sessionVariables =
      lib.optionalAttrs
        (builtins.elem cfg.profile [
          "nixos-wsl"
          "nixos-desktop"
        ])
        {
          # Keep SQLite on the native Linux filesystem. WSL shares config/auth with
          # Windows; the native desktop imports a private migration copy at install.
          CODEX_SQLITE_HOME = "${config.home.homeDirectory}/.codex/sqlite";
        };
  };
}
