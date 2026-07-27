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
let
  cfg = config.dotfiles.tracer;
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.mango.nixosModules.mango
    inputs.noctalia.nixosModules.default
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/audio.nix
    ../../modules/nixos/compositors.nix
    ../../modules/nixos/tracer-tools.nix
  ];

  options.dotfiles.tracer = {
    secureBoot.enable = lib.mkEnableOption "Lanzaboote after the initial systemd-boot installation and key enrollment";
    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Discovered Tracer Ethernet interface; null keeps the initial installation on DHCP.";
    };
    staticLan.enable = lib.mkEnableOption "Tracer's permanent 192.168.0.117 LAN profile";
    dataDisk.enable = lib.mkEnableOption "the migrated and TPM-enrolled Intel 2 TB data disk";
  };

  config = {
    assertions = [
      {
        assertion = !cfg.staticLan.enable || cfg.lanInterface != null;
        message = "Tracer's static LAN profile requires the discovered Ethernet interface name.";
      }
    ];

    dotfiles = {
      compositors = {
        inherit user;
        nvidiaVramWorkaround = true;
      };
      desktop = {
        inherit user;
        userDescription = "Alex";
        hostName = "tracer";
        cpuVendor = "amd";
        autoLogin = false;
        lanInterface = cfg.lanInterface;
        storage = {
          rootLabel = "TRACER_NIX";
          bootLabel = "TRACER_BOOT";
          efiDevice = "/dev/disk/by-partlabel/TRACER_ESP";
          swapSizeMiB = 16 * 1024;
          requireGeneratedEfiPartuuid = false;
        };
        sunshine = {
          mode = "kms";
          name = "TRACER";
        };
      };
      tracerTools = {
        enable = true;
        source = self.outPath;
      };
    };

    boot = {
      initrd = {
        systemd.enable = true;
        availableKernelModules = [
          "ahci"
          "nvme"
          "sd_mod"
          "usb_storage"
          "xhci_pci"
        ];
        luks.devices.tracer-root = {
          device = "/dev/disk/by-partlabel/TRACER_CRYPT";
          allowDiscards = true;
        };
      };
      loader = {
        systemd-boot.enable = lib.mkForce (!cfg.secureBoot.enable);
        efi.canTouchEfiVariables = true;
      };
      lanzaboote = {
        enable = cfg.secureBoot.enable;
        pkiBundle = "/etc/secureboot";
      };
    };

    environment.systemPackages = [ pkgs.sbctl ];

    # The secondary SSD is added only after the fresh installation is proven.
    # Missing bulk storage must not prevent the desktop from booting.
    environment.etc.crypttab = lib.mkIf cfg.dataDisk.enable {
      text = ''
        tracer-data /dev/disk/by-partlabel/TRACER_DATA_CRYPT none tpm2-device=auto,nofail,x-systemd.device-timeout=5s
      '';
    };
    fileSystems = {
      "/games" = {
        device = "/dev/disk/by-label/TRACER_NIX";
        fsType = "btrfs";
        options = [
          "subvol=@games"
          "compress=zstd:3"
          "noatime"
          "discard=async"
        ];
      };
    }
    // lib.optionalAttrs cfg.dataDisk.enable {
      "/data" = {
        device = "/dev/mapper/tracer-data";
        fsType = "btrfs";
        options = [
          "subvol=@data"
          "compress=zstd:3"
          "noatime"
          "discard=async"
          "nofail"
          "x-systemd.device-timeout=5s"
        ];
      };
    };

    virtualisation.docker.daemon.settings.data-root = "/data/docker";
    systemd.services.docker = {
      after = [ "data.mount" ];
      unitConfig.ConditionPathIsMountPoint = "/data";
    };

    networking = {
      firewall.allowedTCPPorts = [ 22 ];
      networkmanager = lib.mkIf cfg.staticLan.enable {
        settings.main.no-auto-default = "*";
        ensureProfiles.profiles.tracer-static-ethernet = {
          connection = {
            id = "tracer-static-ethernet";
            type = "ethernet";
            interface-name = cfg.lanInterface;
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
    };

    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      openFirewall = false;
      settings = {
        AllowAgentForwarding = false;
        AllowTcpForwarding = false;
        AllowUsers = [ user ];
        AuthenticationMethods = "publickey";
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
        X11Forwarding = false;
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
        dotfiles = {
          inherit profile;
          gaming = {
            steamLibrary = "/games/SteamLibrary";
            haloCampaignEvolved.enable = true;
          };
        };
      };
    };

    systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 ${user} users -" ];
    systemd.services.tracer-data-directories = {
      description = "Create Tracer bulk-storage directories after /data is mounted";
      wantedBy = [ "multi-user.target" ];
      after = [ "data.mount" ];
      unitConfig.ConditionPathIsMountPoint = "/data";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0710 -o root -g docker /data/docker
      '';
    };
  };
}
