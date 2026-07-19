{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.desktop;
  obsStudio = pkgs.symlinkJoin {
    name = "obs-studio-nvidia-${pkgs.obs-studio.version}";
    paths = [ pkgs.obs-studio ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # OBS patches its plugins with NixOS's runtime GPU-driver path, but its
    # separate NVENC capability probe also dlopens libnvidia-encode.so.1.
    postBuild = ''
      wrapProgram $out/bin/obs-nvenc-test \
        --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    '';
    inherit (pkgs.obs-studio) meta passthru;
  };
  discordNvidia = pkgs.symlinkJoin {
    name = "discord-nvidia-${pkgs.discord.version}";
    paths = [ pkgs.discord ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # Discord probes CUDA/NVENC for hardware-accelerated screen sharing by
    # dlopening the NVIDIA driver libraries at runtime. Plasma auto-login has
    # no PAM password with which to unlock KWallet, so avoid its setup prompt.
    postBuild = ''
      wrapProgram $out/opt/Discord/Discord \
        --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib \
        --add-flags --password-store=basic
    '';
    inherit (pkgs.discord) meta passthru;
  };
  ipadEdidFirmware = pkgs.edid-generator.overrideAttrs (oldAttrs: {
    clean = true;
    modelines = ''
      Modeline "ipad2732" 365.61 2732 2780 2812 2892 2048 2051 2061 2107 +hsync -vsync ratio=4:3
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
        grep -Eq 'DTD 1:[[:space:]]+2732x2048' "$file.decode"
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
        export CHEV_IPAD_EDID=${ipadEdidFirmware}/lib/firmware/edid/ipad2732.bin
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
      connector=${lib.escapeShellArg ipadConnector}
      connected=0
      for status_file in /sys/class/drm/card*-"$connector"/status; do
        [[ -r "$status_file" ]] || continue
        if [[ "$(<"$status_file")" == "connected" ]]; then
          connected=1
          break
        fi
      done

      if ((connected == 0)); then
        printf 'The iPad dummy connector %s is disconnected; skipping Sunshine autostart.\n' "$connector"
        exit 1
      fi

      for attempt in $(${pkgs.coreutils}/bin/seq 1 30); do
        if ${ipadDisplayOn}/bin/ipad-display-on; then
          exit 0
        fi
        printf 'KScreen is not ready for the iPad dummy (attempt %s/30); retrying.\n' "$attempt" >&2
        sleep 1
      done
      printf '%s\n' 'Could not enable the connected iPad dummy before Sunshine encoder probing; skipping Sunshine autostart.' >&2
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
      kernelModules = [ "uhid" ];
      kernelParams = [
        "nvidia-drm.fbdev=1"
      ]
      ++ lib.optional (
        cfg.ipadDisplay.connector != null
      ) "drm.edid_firmware=${cfg.ipadDisplay.connector}:edid/ipad2732.bin";
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
              ${pkgs.coreutils}/bin/install -D -m 0644 "$fallback_backup" "$fallback_target"
            elif [[ -f "$fallback_absent" ]]; then
              ${pkgs.coreutils}/bin/rm -f -- "$fallback_target"
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

      usbmuxd.enable = true;

      sunshine = {
        enable = true;
        autoStart = true;
        openFirewall = true;
        settings = {
          sunshine_name = "CHEV-DESKTOP";
          capture = "kwin";
          # This Sunshine build has CUDA interop disabled. Its hybrid NVENC
          # path can probe successfully but fails every BGR0-to-NV12 frame
          # conversion at the iPad's custom 4:3 mode. Vulkan encoding is still
          # hardware accelerated on the RTX 3090 Ti and is the path already
          # proven by sustained 2732/2736x2048 Moonlight sessions.
          encoder = "vulkan";
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
    # prep command. Ensure a connected dummy is active first so a headless/sole
    # iPad session remains recoverable after reboot even while the LG is off.
    # ExecCondition cleanly skips autostart when the dummy is absent or cannot
    # be prepared; an ExecStartPre failure would enter a restart loop and can
    # block Plasma from stopping graphical-session.target during logout.
    systemd.user.services.sunshine.serviceConfig.ExecCondition = lib.mkIf (
      cfg.ipadDisplay.connector != null
    ) "${ipadDisplayEnsure}/bin/ipad-display-ensure";
    # The current capture backend and dummy-display preparation are both
    # Plasma-specific. Do not let an experimental compositor session churn
    # through KScreen retries and Sunshine's restart limit.
    systemd.user.services.sunshine.unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=KDE";
    # Sunshine's DualSense emulation uses UHID in addition to UInput. The
    # upstream udev rules also grant access to the virtual devices Sunshine
    # creates so their advanced controller features remain usable.
    services.udev.extraRules = ''
      KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{name}=="Sunshine PS5 (virtual) pad*", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Sunshine X-Box One (virtual) pad*", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Sunshine gamepad (virtual) motion sensors*", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Sunshine Nintendo (virtual) pad*", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="input", ATTRS{name}=="Sunshine PS5 (virtual) pad*", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    security.rtkit.enable = true;
    security.pam.loginLimits = [
      {
        domain = "@audio";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
    ];

    virtualisation.docker.enable = true;

    programs = {
      _1password.enable = true;
      _1password-gui = {
        enable = true;
        polkitPolicyOwners = [ "alex" ];
      };
      zsh.enable = true;
      firefox = {
        enable = true;
        policies.ExtensionSettings."{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
          installation_mode = "normal_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi";
          default_area = "navbar";
        };
      };
      gamemode.enable = true;
      gamescope.enable = true;
      nix-ld.enable = true;
      obs-studio = {
        enable = true;
        package = obsStudio;
        plugins = [ pkgs.obs-studio-plugins.droidcam-obs ];
      };
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
      age
      btrfs-progs
      ardour
      audacity
      curl
      discordNvidia
      flameshot
      gimp
      git
      gparted
      ipadDisplayOff
      ipadDisplayOn
      ipadDisplayPrepare
      kdePackages.kcalc
      kdePackages.kdenlive
      kdePackages.kdialog
      krita
      ksnip
      libimobiledevice
      libva-utils
      mangohud
      nvtopPackages.nvidia
      pciutils
      pulseaudio
      usbutils
      vim
      vulkan-tools
      wget
      wl-clipboard
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
