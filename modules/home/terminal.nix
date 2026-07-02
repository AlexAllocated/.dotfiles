{ config, ... }:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
in
{
  imports = [ ./core.nix ];

  config = {
    xdg.configFile."wezterm".source = sourceRoot + "/wezterm";
    home.file.".wezterm.lua".source = sourceRoot + "/.wezterm.lua";
  };
}
