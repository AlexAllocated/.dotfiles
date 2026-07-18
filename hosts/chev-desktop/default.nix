{
  inputs,
  lib,
  profile,
  self,
  toolPkgs,
  user,
  ...
}:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/migration-tools.nix
  ]
  ++ lib.optional (builtins.pathExists ./hardware-generated.nix) ./hardware-generated.nix;

  dotfiles = {
    desktop = {
      inherit user;
      userDescription = "Alex";
    };
    migrationTools = {
      enable = true;
      source = self.outPath;
      rescue.enable = false;
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = {
      inherit
        profile
        self
        toolPkgs
        user
        ;
      inputs = self.inputs;
    };
    users.${user} = {
      imports = [ ../../modules/home/default.nix ];
      home = {
        username = user;
        homeDirectory = "/home/${user}";
        stateVersion = "26.05";
      };
      dotfiles.profile = profile;
    };
  };
}
