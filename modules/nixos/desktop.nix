{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.desktop;
  ipadEdidFirmware = pkgs.edid-generator.overrideAttrs (oldAttrs: {
    clean = true;
    modelines = ''
      Modeline "ipad2736" 366.11 2736 2784 2816 2896 2048 2051 2061 2107 +hsync -vsync ratio=4:3
    '';
    doCheck = true;
    nativeCheckInputs = (oldAttrs.nativeCheckInputs or [ ]) ++ [
      pkgs.edid-decode
      pkgs.gnugrep
    ];
    # edid-generator's generic template describes an analog input. The dummy
    # adapter is digital, so make the input descriptor digital before
    # generating and checksumming the final 128-byte EDID.
    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace edid.S \
        --replace-fail $'video_parms:\t.byte\t0x6d' $'video_parms:\t.byte\t0x80' \
        --replace-fail $'std_xres:\t.byte\t(XPIX/8)-31' $'std_xres:\t.byte\t0x01' \
        --replace-fail $'std_vres:\t.byte\t(XY_RATIO<<6)+VFREQ-60' $'std_vres:\t.byte\t0x01'
    '';
    checkPhase = (oldAttrs.checkPhase or "") + ''
      for file in *.bin; do
        edid-decode --check "$file" > "$file.decode"
        grep -Fq 'Digital display' "$file.decode"
        grep -Eq 'DTD 1:[[:space:]]+2736x2048' "$file.decode"
        ! grep -Eq '688x516|Warnings:' "$file.decode"
      done
    '';
  });
  ipadConnector = if cfg.ipadDisplay.connector == null then "" else cfg.ipadDisplay.connector;
  mkIpadTool =
    name: script: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        export CHEV_IPAD_CONNECTOR=${lib.escapeShellArg ipadConnector}
        export CHEV_IPAD_EDID=${ipadEdidFirmware}/lib/firmware/edid/ipad2736.bin
        exec ${pkgs.bash}/bin/bash ${script} "$@"
      '';
    };
  ipadDisplayPrepare = mkIpadTool "ipad-display-prepare" ../../scripts/nixos/ipad-display-prepare.sh (
    with pkgs;
    [
      coreutils
      edid-decode
      gnugrep
      gnused
      udev
    ]
  );
  ipadDisplayOn = mkIpadTool "ipad-display-on" ../../scripts/nixos/ipad-display-on.sh [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.jq
    pkgs.kdePackages.libkscreen
  ];
  ipadDisplayEnsure = pkgs.writeShellApplication {
    name = "ipad-display-ensure";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for attempt in $(${pkgs.coreutils}/bin/seq 1 30); do
        if ${ipadDisplayOn}/bin/ipad-display-on; then
          exit 0
        fi
        printf 'KScreen is not ready for the iPad dummy (attempt %s/30); retrying.\n' "$attempt" >&2
        sleep 1
      done
      printf '%s\n' 'Could not enable the iPad dummy before Sunshine encoder probing; Sunshine will not start.' >&2
      exit 1
    '';
  };
  ipadDisplayOff = mkIpadTool "ipad-display-off" ../../scripts/nixos/ipad-display-off.sh [
    pkgs.coreutils
    pkgs.jq
    pkgs.kdePackages.libkscreen
  ];
in
{
  options.dotfiles.desktop = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "alex";
      description = "Primary user of the native NixOS workstation.";
    };

    userDescription = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Display name of the primary workstation user.";
    };

    efiPartuuid = lib.mkOption {
      type = lib.types.str;
      default = "UNCONFIGURED-EFI-PARTUUID";
      description = "Windows ESP PARTUUID generated from the validated migration manifest.";
    };

    ipadDisplay.connector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = "DRM connector verified as the FUN/EK1080 dummy adapter; never the LG display.";
    };
  };

  config = {
    system.stateVersion = "26.05";
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        cfg.user
      ];
      auto-optimise-store = true;
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    networking = {
      hostName = "chev-desktop";
      networkmanager.enable = true;
    };

    time.timeZone = "America/Denver";
    i18n.defaultLocale = "en_US.UTF-8";

    boot = {
      initrd.availableKernelModules = [
        "ahci"
        "nvme"
        "sd_mod"
        "usb_storage"
        "xhci_pci"
      ];
      kernelParams = [
        "nvidia-drm.fbdev=1"
      ]
      ++ lib.optional (
        cfg.ipadDisplay.connector != null
      ) "drm.edid_firmware=${cfg.ipadDisplay.connector}:edid/ipad2736.bin";
      supportedFilesystems = [ "ntfs" ];
      loader = {
        timeout = 8;
        efi = {
          canTouchEfiVariables = true;
          efiSysMountPoint = "/efi";
        };
        systemd-boot = {
          enable = true;
          configurationLimit = 10;
          xbootldrMountPoint = "/boot";
          extraInstallCommands = ''
            # EFI filesystems are case-insensitive, so EFI/NixOS collides with
            # the bootloader-managed EFI/nixos directory. Keep the Windows
            # recovery record in a directory systemd-boot does not own.
            fallback_backup=/efi/EFI/WindowsFallbackBackup/windows-fallback-original.efi
            fallback_absent=/efi/EFI/WindowsFallbackBackup/windows-fallback-original.absent
            fallback_target=/efi/EFI/BOOT/BOOTX64.EFI
            if [[ -f "$fallback_backup" ]]; then
              install -D -m 0644 "$fallback_backup" "$fallback_target"
            elif [[ -f "$fallback_absent" ]]; then
              rm -f -- "$fallback_target"
            else
              echo "Missing the installer-created Windows fallback record; refusing to alter EFI fallback state." >&2
              exit 1
            fi
          '';
        };
      };
    };

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/NIXROOT";
        fsType = "btrfs";
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@root"
        ];
      };
      "/home" = {
        device = "/dev/disk/by-label/NIXROOT";
        fsType = "btrfs";
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@home"
        ];
      };
      "/nix" = {
        device = "/dev/disk/by-label/NIXROOT";
        fsType = "btrfs";
        neededForBoot = true;
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@nix"
        ];
      };
      "/swap" = {
        device = "/dev/disk/by-label/NIXROOT";
        fsType = "btrfs";
        options = [
          "noatime"
          "subvol=@swap"
        ];
      };
      "/boot" = {
        device = "/dev/disk/by-label/NIXBOOT";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
      "/efi" = {
        device = "/dev/disk/by-partuuid/${cfg.efiPartuuid}";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
    };

    warnings = lib.optional (cfg.efiPartuuid == "UNCONFIGURED-EFI-PARTUUID") ''
      chev-desktop is being evaluated without its generated ESP PARTUUID. The
      confirmation-gated installer writes hosts/chev-desktop/hardware-generated.nix
      from the validated machine manifest before nixos-install runs.
    '';

    swapDevices = [
      {
        device = "/swap/swapfile";
        size = 8 * 1024;
      }
    ];
    zramSwap = {
      enable = true;
      memoryPercent = 25;
    };

    hardware = {
      enableRedistributableFirmware = true;
      firmware = [ ipadEdidFirmware ];
      cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
      graphics = {
        enable = true;
        enable32Bit = true;
        extraPackages = [ pkgs.nvidia-vaapi-driver ];
      };
      nvidia = {
        modesetting.enable = true;
        nvidiaSettings = true;
        open = true;
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        powerManagement.enable = true;
      };
    };
    services.xserver.videoDrivers = [ "nvidia" ];

    services = {
      xserver.enable = true;
      displayManager.sddm = {
        enable = true;
        wayland.enable = true;
      };
      displayManager.autoLogin = {
        enable = true;
        user = cfg.user;
      };
      desktopManager.plasma6.enable = true;

      pipewire = {
        enable = true;
        alsa = {
          enable = true;
          support32Bit = true;
        };
        jack.enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      sunshine = {
        enable = true;
        autoStart = true;
        openFirewall = true;
        settings = {
          sunshine_name = "CHEV-DESKTOP";
          capture = "kwin";
          encoder = "nvenc";
          file_state = "sunshine_state.json";
          credentials_file = "sunshine_state.json";
          cert = "credentials/cacert.pem";
          pkey = "credentials/cakey.pem";
        }
        // lib.optionalAttrs (cfg.ipadDisplay.connector != null) {
          output_name = cfg.ipadDisplay.connector;
        };
        applications.apps = [
          (
            {
              name = "Desktop";
            }
            // lib.optionalAttrs (cfg.ipadDisplay.connector != null) {
              prep-cmd = [
                {
                  do = "${ipadDisplayOn}/bin/ipad-display-on";
                }
              ];
            }
          )
          (
            {
              name = "Steam Big Picture";
              cmd = "${pkgs.steam}/bin/steam steam://open/bigpicture";
              auto-detach = "true";
            }
            // lib.optionalAttrs (cfg.ipadDisplay.connector != null) {
              prep-cmd = [
                {
                  do = "${ipadDisplayOn}/bin/ipad-display-on";
                }
              ];
            }
          )
        ];
      };

      wivrn = {
        enable = true;
        autoStart = false;
        highPriority = true;
        openFirewall = true;
        steam = {
          enable = true;
          importOXRRuntimes = true;
        };
      };
    };

    # Sunshine probes displays and encoders before it runs an application's
    # prep command. Ensure the dummy is active first so a headless/sole iPad
    # session remains recoverable after reboot even while the LG is off.
    systemd.user.services.sunshine.serviceConfig.ExecStartPre = lib.mkIf (
      cfg.ipadDisplay.connector != null
    ) "${ipadDisplayEnsure}/bin/ipad-display-ensure";

    security.rtkit.enable = true;

    virtualisation.docker.enable = true;

    programs = {
      zsh.enable = true;
      gamemode.enable = true;
      gamescope.enable = true;
      nix-ld.enable = true;
      steam = {
        enable = true;
        localNetworkGameTransfers.openFirewall = true;
        protontricks.enable = true;
        extraCompatPackages = [ pkgs.proton-ge-bin ];
      };
      alvr = {
        enable = true;
        openFirewall = true;
      };
    };

    users.users.${cfg.user} = {
      isNormalUser = true;
      uid = 1000;
      description = cfg.userDescription;
      home = "/home/${cfg.user}";
      createHome = true;
      shell = pkgs.zsh;
      extraGroups = [
        "audio"
        "input"
        "networkmanager"
        "docker"
        "uinput"
        "video"
        "wheel"
      ];
    };

    environment.systemPackages = with pkgs; [
      btrfs-progs
      ardour
      audacity
      curl
      flameshot
      gimp
      git
      gparted
      ipadDisplayOff
      ipadDisplayOn
      ipadDisplayPrepare
      kdePackages.kcalc
      kdePackages.kdenlive
      krita
      ksnip
      libva-utils
      nvtopPackages.nvidia
      obs-studio
      pciutils
      usbutils
      vim
      vulkan-tools
      wget
    ];

    assertions = [
      {
        assertion =
          cfg.ipadDisplay.connector == null
          || builtins.match "^[A-Za-z0-9._-]+$" cfg.ipadDisplay.connector != null;
        message = "dotfiles.desktop.ipadDisplay.connector contains unsafe characters";
      }
    ];
  };
}
