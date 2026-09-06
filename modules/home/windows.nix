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
    ".local/share/dotfiles/windows/configure-always-on.ps1".source =
      sourceRoot + "/scripts/windows/configure-always-on.ps1";
    ".local/share/dotfiles/windows/configure-quest-hotspot.ps1".source =
      sourceRoot + "/scripts/windows/configure-quest-hotspot.ps1";
    ".local/share/dotfiles/windows/configure-obs.ps1".source =
      sourceRoot + "/scripts/windows/configure-obs.ps1";
    ".local/share/dotfiles/windows/obs-production-mode.lua".source =
      sourceRoot + "/scripts/windows/obs-production-mode.lua";
    ".local/share/dotfiles/windows/obs-production-frame-limit.vbs".source =
      sourceRoot + "/scripts/windows/obs-production-frame-limit.vbs";
    ".local/share/dotfiles/windows/configure-nvidia-video-effects.ps1".source =
      sourceRoot + "/scripts/windows/configure-nvidia-video-effects.ps1";
    ".local/share/dotfiles/windows/configure-amps.ps1".source =
      sourceRoot + "/scripts/windows/configure-amps.ps1";
    ".local/share/dotfiles/windows/configure-amps-endpoints.ps1".source =
      sourceRoot + "/scripts/windows/configure-amps-endpoints.ps1";
    ".local/share/dotfiles/windows/amps-migration.ps1".source =
      sourceRoot + "/scripts/windows/amps-migration.ps1";
    ".local/share/dotfiles/windows/amps-launch-context.ps1".source =
      sourceRoot + "/scripts/windows/amps-launch-context.ps1";
    ".local/share/dotfiles/windows/configure-wallpapers.ps1".source =
      sourceRoot + "/scripts/windows/configure-wallpapers.ps1";
    ".local/share/dotfiles/windows/configure-lg-display.ps1".source =
      sourceRoot + "/scripts/windows/configure-lg-display.ps1";
    ".local/share/dotfiles/windows/configure-sunshine-virtual-display.ps1".source =
      sourceRoot + "/scripts/windows/configure-sunshine-virtual-display.ps1";
    ".local/share/dotfiles/windows/configure-minecraft-vr.ps1".source =
      sourceRoot + "/scripts/windows/configure-minecraft-vr.ps1";
    ".local/share/dotfiles/windows/configure-minecraft-desktop.ps1".source =
      sourceRoot + "/scripts/windows/configure-minecraft-desktop.ps1";
    ".local/share/dotfiles/windows/configure-powerwash-simulator-2.ps1".source =
      sourceRoot + "/scripts/windows/configure-powerwash-simulator-2.ps1";
    ".local/share/dotfiles/windows/configure-flat2vr-mods.ps1".source =
      sourceRoot + "/scripts/windows/configure-flat2vr-mods.ps1";
    ".local/share/dotfiles/windows/PowerWashLauncher.cs".source =
      sourceRoot + "/scripts/windows/PowerWashLauncher.cs";
    ".local/share/dotfiles/windows/minecraft-graphics-assets.ps1".source =
      sourceRoot + "/scripts/windows/minecraft-graphics-assets.ps1";
    ".local/share/dotfiles/windows/install-user-fonts.ps1".source =
      sourceRoot + "/scripts/windows/install-user-fonts.ps1";
    ".local/share/dotfiles/windows/install-virtual-display.ps1".source =
      sourceRoot + "/scripts/windows/install-virtual-display.ps1";
    ".local/share/dotfiles/windows/keep-slack-active.ps1".source =
      sourceRoot + "/scripts/windows/keep-slack-active.ps1";
    ".local/share/dotfiles/windows/keep-slack-active-hidden.vbs".source =
      sourceRoot + "/scripts/windows/keep-slack-active-hidden.vbs";
    ".local/share/dotfiles/windows/codex-desktop.toml".source =
      sourceRoot + "/platforms/windows/codex-desktop.toml";
    ".local/share/dotfiles/windows/open-in-neovide.ps1".source =
      sourceRoot + "/scripts/windows/open-in-neovide.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.ps1".source =
      sourceRoot + "/scripts/windows/open-in-nvim.ps1";
    ".local/share/dotfiles/windows/open-in-nvim.sh".source =
      sourceRoot + "/scripts/windows/open-in-nvim.sh";
    ".local/share/dotfiles/windows/restore-sunshine-identity.ps1".source =
      sourceRoot + "/scripts/windows/restore-sunshine-identity.ps1";
    ".local/share/dotfiles/windows/set-sunshine-display-session.ps1".source =
      sourceRoot + "/scripts/windows/set-sunshine-display-session.ps1";
    ".local/share/dotfiles/windows/set-nvidia-frame-limit.ps1".source =
      sourceRoot + "/scripts/windows/set-nvidia-frame-limit.ps1";
    ".local/share/dotfiles/windows/apply-wsl-ssh-forward.ps1".source =
      sourceRoot + "/scripts/windows/apply-wsl-ssh-forward.ps1";
    ".local/share/dotfiles/windows/winget.json".source = sourceRoot + "/platforms/windows/winget.json";
    ".local/share/dotfiles/windows/vdd_settings.xml".source =
      sourceRoot + "/platforms/windows/vdd_settings.xml";
  };
}
