{
  inputs,
  lib,
  pkgs,
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

  systemd.tmpfiles.rules = [
    "d /data/games 0755 ${user} users -"
    "d /data/preserved 0755 ${user} users -"
  ];

  # Games are large and frequently patched. New files below this directory
  # inherit No_COW, avoiding needless copy-on-write fragmentation.
  systemd.services.linux-data-games-nocow = {
    description = "Keep the Linux games directory No_COW";
    requires = [ "data.mount" ];
    after = [
      "data.mount"
      "systemd-tmpfiles-setup.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.e2fsprogs}/bin/chattr +C /data/games";
    };
  };
}
