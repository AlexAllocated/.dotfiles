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
        enable = false;
        user = user;
        durableTmux = true;
      };
    };
  };

  # The dispatcher remembers Alex's chosen desktop across logins and boots.
  # Niri + Noctalia is both the canonical session and automatic recovery path.
  services.displayManager.defaultSession = "dotfiles-desktop";

  # Build Raspberry Pi NixOS images locally without needing a separate ARM
  # builder. This registers qemu-aarch64 through binfmt for Nix builds.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Termius and other SSH clients enter through the fixed wired-LAN address.
  # Authentication is device-key-only; the user's public keys remain in the
  # standard machine-local ~/.ssh/authorized_keys rather than this repository.
  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    openFirewall = false;
    ports = [ 22 ];
    listenAddresses = [
      {
        addr = "192.168.0.117";
        port = 22;
      }
    ];
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = false;
      AllowUsers = [ user ];
      AuthenticationMethods = "publickey";
      ClientAliveCountMax = 3;
      ClientAliveInterval = 60;
      KbdInteractiveAuthentication = false;
      LogLevel = "VERBOSE";
      MaxAuthTries = 3;
      PasswordAuthentication = false;
      PermitEmptyPasswords = false;
      PermitRootLogin = "no";
      PermitTunnel = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
    };
  };

  systemd.services.sshd = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  networking.firewall.interfaces.br0.allowedTCPPorts = [ 22 ];

  networking.networkmanager = {
    # Bridge the router-facing and Pi-facing NICs so the Pi is a first-class
    # device on the home LAN while retaining this desktop's static address.
    settings.main.no-auto-default = "*";
    ensureProfiles.profiles = {
      home-lan-bridge = {
        connection = {
          id = "home-lan-bridge";
          type = "bridge";
          interface-name = "br0";
          autoconnect = true;
          autoconnect-priority = 100;
        };
        bridge.stp = false;
        ipv4 = {
          method = "manual";
          addresses = "192.168.0.117/24";
          gateway = "192.168.0.1";
          dns = "8.8.8.8;4.4.4.4;";
          dns-search = "lan;";
        };
        ipv6.method = "auto";
      };
      home-lan-uplink = {
        connection = {
          id = "home-lan-uplink";
          type = "ethernet";
          interface-name = "eno1";
          controller = "br0";
          port-type = "bridge";
          autoconnect = true;
          autoconnect-priority = 100;
        };
      };
      plex-pi-link = {
        connection = {
          id = "plex-pi-link";
          type = "ethernet";
          interface-name = "enp4s0";
          controller = "br0";
          port-type = "bridge";
          autoconnect = true;
          autoconnect-priority = 100;
        };
      };
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
      dotfiles.gaming = {
        steamLibrary = "/data/games/SteamLibrary";
        haloCampaignEvolved.enable = true;
      };
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
          niriGaps = 24;
          # Keep the invisible remote desktop beside, rather than on top of,
          # the LG and leave startup focus on the physical monitor.
          position = {
            x = 3440;
            y = 0;
          };
        };
      };
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

  # Keep container layers and named volumes off the constrained system SSD.
  # The one-time migration copies and verifies /var/lib/docker before this
  # data-root is activated; the existing 2 TB filesystem is not reformatted.
  virtualisation.docker.daemon.settings.data-root = "/data/docker";
  systemd.services.docker = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    unitConfig.ConditionPathIsMountPoint = "/data";
  };
}
