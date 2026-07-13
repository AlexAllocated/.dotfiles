{ config, ... }:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
in
{
  imports = [ ./core.nix ];

  config.home.file = {
    ".local/share/dotfiles/windows/NvimWSL.cs".source = sourceRoot + "/scripts/windows/NvimWSL.cs";
    ".local/share/dotfiles/windows/apply-packages.ps1".source =
      sourceRoot + "/scripts/windows/apply-packages.ps1";
    ".local/share/dotfiles/windows/apply-wsl-links.ps1".source =
      sourceRoot + "/scripts/windows/apply-wsl-links.ps1";
    ".local/share/dotfiles/windows/configure-codex.py".source =
      sourceRoot + "/scripts/windows/configure-codex.py";
    ".local/share/dotfiles/windows/install-user-fonts.ps1".source =
      sourceRoot + "/scripts/windows/install-user-fonts.ps1";
    ".local/share/dotfiles/windows/codex-desktop.toml".source =
      sourceRoot + "/platforms/windows/codex-desktop.toml";
    ".local/share/dotfiles/windows/open-in-neovide.ps1".source =
      sourceRoot + "/scripts/windows/open-in-neovide.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.ps1".source =
      sourceRoot + "/scripts/windows/open-in-nvim.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.sh".source =
      sourceRoot + "/scripts/windows/open-in-nvim.sh";
    ".local/share/dotfiles/windows/winget.json".source = sourceRoot + "/platforms/windows/winget.json";
  };
}
