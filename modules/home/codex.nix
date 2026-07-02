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
  codexPackage = if builtins.hasAttr "codex" toolPkgs then toolPkgs.codex else pkgs.codex;
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
      home.packages = [
        codexPackage
        pkgs.bun
        pkgs.nodejs
      ];
    }
    (lib.mkIf cfg.codex.manageConfig {
      home.file.".codex/config.toml".source = sourceRoot + "/codex/config.toml";
      home.file.".codex/rules/default.rules".source = sourceRoot + "/codex/rules/default.rules";
    })
  ];
}
