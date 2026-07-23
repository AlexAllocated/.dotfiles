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
    inputs.mango.nixosModules.mango
    inputs.noctalia.nixosModules.default
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/audio.nix
    ../../modules/nixos/compositors.nix
    ../../modules/nixos/migration-tools.nix
  ]
  ++ lib.optional (builtins.pathExists ./hardware-generated.nix) ./hardware-generated.nix;

  dotfiles = {
    compositors = {
      inherit user;
      nvidiaVramWorkaround = true;
    };
    desktop = {
      inherit user;
      userDescription = "Alex";
      sunshine.mode = "kms";
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

  # The dispatcher remembers Alex's chosen desktop across logins and boots.
  # It defaults—and automatically falls back—to the proven Plasma session.
  services.displayManager.defaultSession = "dotfiles-desktop";

  networking.networkmanager = {
    # Prevent NetworkManager from racing this declared profile with another
    # automatically generated DHCP profile for the same Ethernet interface.
    settings.main.no-auto-default = "*";
    ensureProfiles.profiles.chev-static-ethernet = {
      connection = {
        id = "chev-static-ethernet";
        type = "ethernet";
        interface-name = "eno1";
        autoconnect = true;
        autoconnect-priority = 100;
      };
      ipv4 = {
        method = "manual";
        addresses = "192.168.0.117/24";
        gateway = "192.168.0.1";
        dns = "8.8.8.8;4.4.4.4;";
        dns-search = "lan;";
      };
      ipv6.method = "auto";
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
      dotfiles.wallpaper.ipad.connector = config.dotfiles.desktop.ipadDisplay.connector;
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
        ${config.dotfiles.desktop.ipadDisplay.connector} = {
          # Sunshine enables this output only while Moonlight is connected.
          # Keeping it off otherwise prevents an invisible pointer/workspace
          # region while the iPad is not in use.
          enable = false;
          mode = "2732x2048@60";
          scale = 1.75;
          # Keep the invisible remote desktop beside, rather than on top of,
          # the LG and leave startup focus on the physical monitor.
          position = {
            x = 3440;
            y = 0;
          };
        };
      };

      # Plasma stores dragged launchers as filesystem URLs, which can embed
      # generation-specific Nix store paths. Keep the desired order as stable
      # desktop IDs so rebuilds and rollbacks cannot strand the taskbar icons.
      dotfiles.plasma.taskbarLaunchers = [
        "org.wezfurlong.wezterm.desktop"
        "Alacritty.desktop"
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
