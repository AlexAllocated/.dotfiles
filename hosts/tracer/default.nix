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
    ../../modules/nixos/durable-tmux.nix
    ../../modules/nixos/github-actions-runner.nix
    ../../modules/nixos/tracer-tools.nix
  ];

  options.dotfiles.tracer = {
    secureBoot.enable = lib.mkEnableOption "Lanzaboote after the initial systemd-boot installation and key enrollment";
    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Discovered Tracer Ethernet interface; null keeps the initial installation on DHCP.";
    };
    staticLan.enable = lib.mkEnableOption "Tracer's permanent 192.168.0.69 LAN profile";
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
      tracer = {
        lanInterface = "enp11s0";
        staticLan.enable = true;
      };
      compositors = {
        inherit user;
        nvidiaVramWorkaround = true;
      };
      desktop = {
        inherit user;
        userDescription = "Alex";
        hostName = "tracer";
        cpuVendor = "amd";
        autoLogin = true;
        lanInterface = cfg.lanInterface;
        # Keep the dedicated VR radio isolated from the workstation's own DNS
        # and upstream routing. If ath12k or hostapd fails, Ethernet must remain
        # a complete workstation network on its own.
        questAccessPoint.enable = true;
        storage = {
          rootLabel = "TRACER_NIX";
          bootLabel = "TRACER_BOOT";
          efiDevice = "/dev/disk/by-partlabel/TRACER_ESP";
          swapSizeMiB = 16 * 1024;
          requireGeneratedEfiPartuuid = false;
        };
        sunshine = {
          fallbackConnector = "DP-4";
          fallbackConnectorAliases = [ "DP-1" ];
          mode = "kms";
          name = "TRACER";
        };
        ipadDisplay = {
          connector = "DP-2";
          connectorAliases = [ "DP-5" ];
        };
      };
      tracerTools = {
        enable = true;
        source = self.outPath;
      };
      durableTmux = {
        enable = true;
        user = user;
      };
      githubActionsRunner = {
        enable = true;
        # Tracer is an interactive workstation first. A single bounded runner
        # avoids multiplying BuildKit workloads behind the Docker daemon.
        instances = 1;
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
          # The recovery passphrase remains enrolled, but normal boots use the
          # PCR-bound TPM2 token created with systemd-cryptenroll.
          crypttabExtraOpts = [ "tpm2-device=auto" ];
        };
      };
      loader = {
        # Unattended boots must enter the latest activated NixOS generation
        # immediately. Hold Space during systemd-boot startup to reveal the
        # generation menu when an explicit rollback is needed.
        timeout = lib.mkForce 0;
        systemd-boot.enable = lib.mkForce (!cfg.secureBoot.enable);
        efi.canTouchEfiVariables = true;
      };
      lanzaboote = {
        enable = cfg.secureBoot.enable;
        pkiBundle = "/etc/secureboot";
      };
    };

    environment.systemPackages = [
      pkgs.efibootmgr
      pkgs.sbctl
    ];

    # This firmware promoted Windows ahead of Linux after the first unattended
    # reboot. Keep only Linux in the normal UEFI order; Windows remains fully
    # available through systemd-boot, F11, and the one-shot reboot-windows
    # helper without being eligible as the automatic fallback.
    systemd.services.tracer-prefer-linux-boot = {
      description = "Keep Linux first in Tracer's UEFI boot order";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.coreutils
        pkgs.efibootmgr
        pkgs.gnused
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        mapfile -t linux_entries < <(
          efibootmgr | sed -nE \
            's/^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+Linux Boot Manager([[:space:]].*)?$/\1/p'
        )
        if ((''${#linux_entries[@]} != 1)); then
          printf 'Expected exactly one Linux Boot Manager entry, found %s; refusing to alter BootOrder.\n' \
            "''${#linux_entries[@]}" >&2
          exit 1
        fi
        current="$(efibootmgr | sed -nE 's/^BootOrder:[[:space:]]*//p')"
        if [[ "$current" != "''${linux_entries[0]}" ]]; then
          efibootmgr --bootorder "''${linux_entries[0]}"
        fi
      '';
    };

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

    virtualisation.docker = {
      enableOnBoot = true;
      daemon.settings = {
        data-root = "/var/lib/docker";
        # With the systemd cgroup driver, Docker otherwise creates containers
        # and BuildKit executors directly under system.slice. Put every Docker
        # workload below our bounded slice instead of limiting dockerd alone.
        cgroup-parent = "docker-workloads.slice";
      };
    };

    # Bound the complete Docker tree: dockerd, ordinary containers, local
    # BuildKit builds, and CI BuildKit builds. MemorySwapMax prevents a bad
    # build from preserving responsiveness by merely exhausting swap instead.
    systemd.slices.docker-workloads.sliceConfig = {
      CPUQuota = "2400%";
      CPUWeight = 20;
      IOWeight = 20;
      MemoryHigh = "40G";
      MemoryMax = "48G";
      MemorySwapMax = "8G";
      TasksMax = 4096;
    };

    # Keep the control plane in the same aggregate slice and make it a cheap
    # OOM target relative to the graphical session if something escapes.
    systemd.services.docker.serviceConfig = {
      Slice = "docker-workloads.slice";
      CPUWeight = 20;
      IOWeight = 20;
      Nice = 5;
      OOMScoreAdjust = 500;
      TasksMax = 4096;
    };

    networking = {
      # Do not make workstation name resolution depend on the router's DNS
      # proxy or on the dedicated Quest dnsmasq instance.
      nameservers = [
        "1.1.1.1"
        "8.8.8.8"
      ];
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
            addresses = "192.168.0.69/24";
            gateway = "192.168.0.1";
            dns = "1.1.1.1;8.8.8.8;";
            ignore-auto-dns = true;
            dns-search = "lan;";
          };
          ipv6 = {
            method = "auto";
            ignore-auto-dns = true;
          };
        };
      };
    };

    # Keep mDNS service discovery on the physical LAN. Docker creates bridge
    # and veth interfaces that would otherwise publish bogus Sunshine targets
    # and make Moonlight discovery unreliable.
    services.avahi = lib.mkIf (cfg.lanInterface != null) {
      allowInterfaces = [ cfg.lanInterface ];
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
          wallpaper = {
            connector = "DP-1";
            outputMatch = "LG Electronics LG ULTRAGEAR 101NTCZMT555";
            ipad = {
              connector = config.dotfiles.desktop.ipadDisplay.connector;
              outputMatch = "The Linux Foundation ipad2732 Linux #0";
            };
          };
          compositors.outputs = {
            "LG Electronics LG ULTRAGEAR 101NTCZMT555" = {
              mode = "3440x1440@160";
              scale = 1;
              variableRefreshRate = true;
              position = {
                x = 0;
                y = 0;
              };
              focusAtStartup = true;
            };
            "The Linux Foundation ipad2732 Linux #0" = {
              # Sunshine enables the dummy only while a remote client needs
              # it. The LG remains the sole startup output whenever it is on.
              enable = false;
              mode = "2732x2048@60";
              scale = 1.75;
              niriGaps = 24;
              position = {
                x = 3440;
                y = 0;
              };
            };
          };
          gaming = {
            steamLibrary = "/games/SteamLibrary";
            steamAutostart.enable = true;
            haloCampaignEvolved.enable = true;
            battleNet.enable = true;
          };
        };
      };
    };

    systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 ${user} users -" ];
  };
}
