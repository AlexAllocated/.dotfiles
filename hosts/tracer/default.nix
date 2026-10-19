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
    ../../modules/nixos/audio-hardware.nix
    ../../modules/nixos/amps.nix
    ../../modules/nixos/compositors.nix
    ../../modules/nixos/durable-tmux.nix
    ../../modules/nixos/chatgpt-service.nix
    ../../modules/nixos/keyring-unlock.nix
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
    # Galactic Racer hangs during D3D12 startup on 595.71.05 (Proton #10228).
    # Pin the newer driver without moving the rest of the workstation's nixpkgs.
    # Hashes match nixpkgs' 615.78.08 new_feature driver definition.
    hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "615.78.08";
      sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
      sha256_aarch64 = "sha256-UHYBE1AYHoGgMfD9AS/jX+S+N8eCDWUft6qolK9Eejc=";
      openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
      settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
      persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
    };

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
        unifiedRazerProfiles = true;
        userDescription = "Alex";
        hostName = "tracer";
        xwaylandPrimaryOutput = "DP-1";
        xwaylandDpi = 96;
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
          mode = "adaptive";
          name = "TRACER";
        };
        ipadDisplay = {
          connector = null;
          connectorAliases = [ ];
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
      chatgptService = {
        enable = true;
        inherit user;
      };
      keyringUnlock = {
        enable = true;
        inherit user;
      };
      amps = {
        enable = true;
        inherit user;
      };
      githubActionsRunner = {
        enable = true;
        # Tracer is an interactive workstation first. A single bounded runner
        # avoids multiplying BuildKit workloads behind the Docker daemon.
        instances = 1;
      };
    };

    boot = {
      kernelModules = [ "xpad" ];
      initrd = {
        systemd.enable = true;
        availableKernelModules = [
          "ahci"
          "nvme"
          "sd_mod"
          "usb_storage"
          "xhci_pci"
        ];
      };
      loader = {
        timeout = lib.mkForce 10;
        systemd-boot.enable = lib.mkForce (!cfg.secureBoot.enable);
        efi.canTouchEfiVariables = true;
      };
      lanzaboote = {
        enable = cfg.secureBoot.enable;
        pkiBundle = "/etc/secureboot";
      };
    };

    environment.systemPackages = [
      (pkgs.callPackage ../../packages/iloader.nix {
        iloader = inputs.iloader.packages.${pkgs.stdenv.hostPlatform.system}.default;
      })
      pkgs.efibootmgr
      pkgs.sbctl
    ];

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
        desired="''${linux_entries[0]}"
        IFS=, read -ra existing_entries <<< "$current"
        for entry in "''${existing_entries[@]}"; do
          if [[ -n "$entry" && "''${entry^^}" != "''${linux_entries[0]^^}" ]]; then
            desired+=",$entry"
          fi
        done
        if [[ "$current" != "$desired" ]]; then
          efibootmgr --bootorder "$desired"
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

    security.sudo.extraRules = [
      {
        users = [ user ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

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

    services.displayManager.defaultSession = "dotfiles-desktop";

    # Match Sunshine's capture allocator even when booting with the LG off.
    # Kernel DRM numbering changes with probe order, so identify the driver.
    services.udev.extraRules = ''
      SUBSYSTEM=="drm", KERNEL=="renderD*", DRIVERS=="nvidia", SYMLINK+="dri/nvidia-render"
    '';

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
          bumblebeeResume.enable = true;
          wallpaper = {
            connector = "DP-1";
            outputMatch = "LG Electronics LG ULTRAGEAR 101NTCZMT555";
            ipad = {
              connector = config.dotfiles.desktop.ipadDisplay.connector;
              outputMatch = "The Linux Foundation ipad2732 Linux #0";
            };
          };
          compositors.niriRenderDrmDevice = "/dev/dri/nvidia-render";
          compositors.outputs = {
            "LG Electronics LG ULTRAGEAR 101NTCZMT555" = {
              mode = "3440x1440@160";
              scale = 1;
              variableRefreshRate = true;
              # Keep idle desktop updates out of VRR's low-framerate path.
              # Game rules opt in while a game is visible on this output.
              niriVrrOnDemand = true;
              position = {
                x = 0;
                y = 0;
              };
              focusAtStartup = true;
              niriDefaultColumnWidth = 0.5;
            };
            "Moonlight" = {
              scale = 1.75;
              niriDefaultColumnWidth = 1.0;
            };
          };
          gaming = {
            steamLibrary = "/games/SteamLibrary";
            steamAutostart.enable = true;
            haloCampaignEvolved.enable = true;
            battleNet.enable = true;
            battleNet.useUmu = true;
            # Keep the tested runtime immutable across Steam updates and Nix
            # rollbacks. The snapshot retains the migrated Wine 11 session.
            battleNet.protonPath = toString (pkgs.callPackage ../../packages/battlenet-proton.nix { });
            # Diablo sizes its cache too aggressively with the full 16 GB
            # reported. Preserve room for the desktop and active screen streams.
            battleNet.diabloReportedVramMiB = 8192;
            curseforge.enable = true;
            guildWars2.enable = true;
            fantasyGrounds.enable = true;
          };
        };
      };
    };

    systemd.tmpfiles.rules = [ "d /games/SteamLibrary 0755 ${user} users -" ];
  };
}
