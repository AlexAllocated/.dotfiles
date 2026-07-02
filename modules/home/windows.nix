{ config, ... }:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
in
{
  imports = [ ./core.nix ];

  config.home.file.".local/share/dotfiles/windows/apply-wsl-links.ps1".source =
    sourceRoot + "/scripts/windows/apply-wsl-links.ps1";
}
