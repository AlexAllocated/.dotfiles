{
  config,
  lib,
  pkgs,
  toolPkgs ? pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
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

  options.dotfiles.codex.manageConfig = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Manage sanitized reusable Codex config and rules.";
  };

  config = lib.mkMerge [
    {
      home.packages =
        if cfg.profile == "nixos-wsl" then
          [
            wslCodex
            pkgs.bun
            pkgs.nodejs
          ]
        else
          toolsets.agent;
    }
    (lib.mkIf (cfg.profile == "nixos-wsl") {
      # The Windows GUI owns config/auth/plugin state. Conversation payloads live
      # in that shared home, while SQLite stays on WSL ext4 for reliable locking.
      home.sessionVariables.CODEX_SQLITE_HOME = "${config.home.homeDirectory}/.codex/sqlite";
    })
    (lib.mkIf cfg.codex.manageConfig {
      home.file.".codex/config.toml".source = sourceRoot + "/codex/config.toml";
      home.file.".codex/rules/default.rules".source = sourceRoot + "/codex/rules/default.rules";
    })
  ];
}
