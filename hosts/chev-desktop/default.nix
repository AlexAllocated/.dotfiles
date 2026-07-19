{
  config,
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
    ../../modules/nixos/compositors.nix
    ../../modules/nixos/migration-tools.nix
  ]
  ++ lib.optional (builtins.pathExists ./hardware-generated.nix) ./hardware-generated.nix;

  dotfiles = {
    compositors.nvidiaVramWorkaround = true;
    desktop = {
      inherit user;
      userDescription = "Alex";
    };
    migrationTools = {
      enable = true;
      source = self.outPath;
      rescue = {
        enable = true;
        user = user;
        autoStart = true;
        durableTmux = true;
        preventSleep = false;
      };
    };
  };

  # Plasma is the proven local and Sunshine recovery desktop. Installing
  # optional sessions must never change the unattended boot target.
  services.displayManager.defaultSession = "plasma";

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
      dotfiles.compositors.outputs = {
        DP-1 = {
          mode = "3440x1440@160";
          scale = 1;
          position = {
            x = 0;
            y = 0;
          };
          focusAtStartup = true;
        };
      }
      // lib.optionalAttrs (config.dotfiles.desktop.ipadDisplay.connector != null) {
        ${config.dotfiles.desktop.ipadDisplay.connector}.enable = false;
      };

      # Plasma stores dragged launchers as filesystem URLs, which can embed
      # generation-specific Nix store paths. Keep the desired order as stable
      # desktop IDs so rebuilds and rollbacks cannot strand the taskbar icons.
      dotfiles.plasma.taskbarLaunchers = [
        "Alacritty.desktop"
        "com.mitchellh.ghostty.desktop"
        "kitty.desktop"
        "org.kde.konsole.desktop"
        "org.wezfurlong.wezterm.desktop"
      ];
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
