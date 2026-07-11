{ config, ... }:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
in
{
  imports = [ ./core.nix ];

  config.home.file = {
    ".local/share/dotfiles/windows/NvimWSL.cs".source = sourceRoot + "/scripts/windows/NvimWSL.cs";
    ".local/share/dotfiles/windows/apply-wsl-links.ps1".source =
      sourceRoot + "/scripts/windows/apply-wsl-links.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.ps1".source =
      sourceRoot + "/scripts/windows/open-in-nvim.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.sh".source =
      sourceRoot + "/scripts/windows/open-in-nvim.sh";
  };
}
