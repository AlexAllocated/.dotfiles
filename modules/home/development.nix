{
  config,
  lib,
  pkgs,
  ...
}:
let
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs; };
  packages =
    if config.dotfiles.profile == "ubuntu-wsl" then
      lib.remove pkgs.nix toolsets.development
    else
      toolsets.development;
in
{
  imports = [ ./core.nix ];
  config.home.packages = packages;
}
