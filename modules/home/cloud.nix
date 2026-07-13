{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs; };
  nativeLinux = pkgs.stdenv.hostPlatform.isLinux && cfg.profile != "nixos-wsl";
in
{
  imports = [ ./core.nix ];

  config.home.packages = toolsets.cloud ++ lib.optionals nativeLinux [ pkgs._1password-gui ];
}
