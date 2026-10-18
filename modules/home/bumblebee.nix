{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./core.nix ];

  options.dotfiles.bumblebee.enable = lib.mkEnableOption "Bumblebee Desktop" // {
    default = config.dotfiles.profile == "nixos-desktop";
  };

  config = lib.mkIf config.dotfiles.bumblebee.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "Bumblebee Desktop's pinned Linux preview requires x86_64-linux.";
      }
    ];
    home.packages = [ (pkgs.callPackage ../../packages/bumblebee-desktop.nix { }) ];
    # Credentials and mutable SQLite settings remain application-owned. Neither
    # installing nor activating this module starts a streaming session.
  };
}
