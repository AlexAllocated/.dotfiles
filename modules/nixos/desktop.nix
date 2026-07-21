{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.desktop;
  sunshineKms = cfg.sunshine.mode == "kms";
  sunshineConfig =
    (pkgs.formats.keyValue { }).generate "sunshine.conf"
      config.services.sunshine.settings;
  sunshineKmsConfig = (pkgs.formats.keyValue { }).generate "sunshine-kms.conf" (
    builtins.removeAttrs config.services.sunshine.settings [ "output_name" ]
  );
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
  razerQdHidSource = pkgs.fetchFromGitHub {
    owner = "AlexAllocated";
    repo = "razerqdhid";
    rev = "2fe504e10dd7f8ea7c6b5d4cfd04d946575b2b5d";
    hash = "sha256-5po6knQogtjHLauDo2pa0QVQQG9oCiX4OHseSESTriw=";
  };
  razerOnboardPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.hidapi ]);
  razerOnboard = pkgs.writeShellApplication {
    name = "razer-onboard";
    runtimeInputs = [ razerOnboardPython ];
    text = ''
      export PYTHONPATH=${razerQdHidSource}/public/py
      exec ${razerOnboardPython}/bin/python3 ${../../scripts/nixos/razer-onboard.py} "$@"
    '';
  };
  # nixpkgs is one Lan Mouse release behind. Version 0.11 adds the
  # authenticated peer protocol and the multi-client configuration used here.
  lanMouse = pkgs.lan-mouse.overrideAttrs (_oldAttrs: rec {
    version = "0.11.0";
    src = pkgs.fetchFromGitHub {
      owner = "feschber";
      repo = "lan-mouse";
      rev = "v${version}";
      hash = "sha256-6EqA9WfiukOymUT4FkNdMvzmFKByW0LLoI/9sv4TzBU=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-Lxs0qWvNAv4KCeJ+cDBYBzwlbJfQJshcxPRdg9w0szc=";
    };
    # Version 0.10 synthesized its version and removed build.rs. Version 0.11
    # uses that build script for feature detection and generated metadata.
    prePatch = "";
  });
  sunshinePackage =
    (pkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = pkgs.cudaPackages_12_9;
    }).overrideAttrs
      (oldAttrs: {
        # Linux KMS normally exposes volatile numeric plane indexes. Accept a
        # stable connector name instead and notify our display policy before
        # encoder probing and after the final streaming client disconnects.
        patches = (oldAttrs.patches or [ ]) ++ [
          ../../patches/sunshine-linux-kms-connector-and-stream-hook.patch
        ];
      });
  mkChromeWebApp =
    {
      name,
      desktopName,
      comment,
      url,
      iconUrl,
      iconHash,
      startupWMClass,
    }:
    let
      icon = pkgs.fetchurl {
        url = iconUrl;
        hash = iconHash;
      };
      launcher = pkgs.writeShellApplication {
        inherit name;
        text = ''
          exec ${lib.getExe pkgs.google-chrome} \
            --app=${lib.escapeShellArg url} \
            --class=${lib.escapeShellArg startupWMClass} \
            --name=${lib.escapeShellArg desktopName} \
            --no-default-browser-check \
            --no-first-run \
            --password-store=basic \
            "$@"
        '';
      };
      desktopItem = pkgs.makeDesktopItem {
        inherit
          name
          desktopName
          comment
          startupWMClass
          ;
        exec = "${launcher}/bin/${name} %U";
        icon = icon;
        categories = [ "Office" ];
        terminal = false;
      };
    in
    pkgs.symlinkJoin {
      name = "${name}-web-app";
      paths = [
        launcher
        desktopItem
      ];
    };
  linearWebApp = mkChromeWebApp {
    name = "linear";
    desktopName = "Linear";
    comment = "Plan and track product development";
    url = "https://linear.app/";
    iconUrl = "https://linear.app/favicon.ico";
    iconHash = "sha256-DgXIufWkobfvMIPVffAYQYXnSJePk8pb2UUJKA8OkY4=";
    startupWMClass = "Linear";
  };
  teamsWebApp = mkChromeWebApp {
    name = "teams";
    desktopName = "Microsoft Teams";
    comment = "Chat, meet, call, and collaborate";
    url = "https://teams.microsoft.com/";
    iconUrl = "https://teams.microsoft.com/favicon.ico";
    iconHash = "sha256-OX7d9E4b9+VXsLT1Fz2pXY/YMrby8Q1uQcF9xTnVqCI=";
    startupWMClass = "Microsoft Teams";
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
  ipadDisplaySessionOn = pkgs.writeShellApplication {
    name = "ipad-display-session-on";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.niri
      pkgs.systemd
      pkgs.wlr-randr
    ];
    text = ''
      connector=${lib.escapeShellArg ipadConnector}

      manager_variable() {
        systemctl --user show-environment \
          | sed -n "s/^$1=//p" \
          | head -n 1
      }

      import_manager_variable() {
        local name="$1" value
        value="$(manager_variable "$name")"
        [[ -z "$value" ]] || export "$name=$value"
      }

      for variable in \
        WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
        MANGO_INSTANCE_SIGNATURE; do
        import_manager_variable "$variable"
      done

      for attempt in $(seq 1 30); do
        desktop="$(manager_variable XDG_CURRENT_DESKTOP)"
        case "$desktop" in
          KDE)
            if ${ipadDisplayOn}/bin/ipad-display-on; then
              exit 0
            fi
            ;;
          niri)
            if niri msg output "$connector" on \
              && niri msg output "$connector" mode 2732x2048@60.001 \
              && niri msg output "$connector" scale 1.75 \
              && niri msg output "$connector" position set 3440 0; then
              exit 0
            fi
            ;;
          Mango | mango)
            if wlr-randr --output "$connector" --on \
              --mode 2732x2048@60.001Hz --scale 1.75 --pos 3440,0; then
              exit 0
            fi
            ;;
          *)
            # Unknown shells may still inherit an already active output from
            # SDDM. That is sufficient for KMS capture and avoids guessing at
            # an unsupported compositor's control protocol.
            for enabled_file in /sys/class/drm/card*-"$connector"/enabled; do
              [[ -r "$enabled_file" && "$(<"$enabled_file")" == enabled ]] && exit 0
            done
            ;;
        esac

        printf 'Graphical output control is not ready (%s, attempt %s/30); retrying.\n' \
          "''${desktop:-unknown}" "$attempt" >&2
        sleep 1
      done

      printf 'Could not enable the persistent Sunshine output %s in this graphical session.\n' "$connector" >&2
      exit 1
    '';
  };
  ipadDisplaySessionOff = pkgs.writeShellApplication {
    name = "ipad-display-session-off";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.niri
      pkgs.systemd
      pkgs.wlr-randr
    ];
    text = ''
      connector=${lib.escapeShellArg ipadConnector}

      manager_variable() {
        systemctl --user show-environment \
          | sed -n "s/^$1=//p" \
          | head -n 1
      }

      import_manager_variable() {
        local name="$1" value
        value="$(manager_variable "$name")"
        [[ -z "$value" ]] || export "$name=$value"
      }

      for variable in \
        WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
        MANGO_INSTANCE_SIGNATURE; do
        import_manager_variable "$variable"
      done

      desktop="$(manager_variable XDG_CURRENT_DESKTOP)"
      case "$desktop" in
        KDE)
          ${ipadDisplayOff}/bin/ipad-display-off
          ;;
        niri)
          niri msg output "$connector" off
          ;;
        Mango | mango)
          wlr-randr --output "$connector" --off
          ;;
        *)
          # SDDM and unknown compositors keep the dummy alive so Sunshine can
          # remain reachable at the greeter. There is no user desktop here in
          # which the pointer could disappear into the output.
          printf 'Leaving %s unchanged for graphical environment %s.\n' \
            "$connector" "''${desktop:-unknown}"
          ;;
      esac

      # Lan Mouse's layer-shell backend follows a newly enabled rightmost
      # output, but 0.11.0 does not move its capture edge back when that output
      # disappears. Recreate its capture surface after Sunshine removes the
      # iPad dummy so the physical LG edge controls the Mac again.
      systemctl --user try-restart lan-mouse.service || true
    '';
  };
  sunshineSessionRun = pkgs.writeShellApplication {
    name = "sunshine-session-run";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if (($# == 0)); then
        printf '%s\n' 'Usage: sunshine-session-run COMMAND [ARG...]' >&2
        exit 64
      fi

      # Sunshine is a system service so it survives compositor and greeter
      # handoffs. Launch graphical applications through Alex's lingering user
      # manager, which always contains the active session's imported Wayland
      # and desktop environment.
      unit="sunshine-app-$PPID-$(date +%s%N)"
      exec systemd-run --user --quiet --collect --service-type=exec \
        --unit="$unit" -- "$@"
    '';
  };
  sunshineKmsLauncher = pkgs.writeShellApplication {
    name = "sunshine-kms-launch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.systemd
    ];
    text = ''
      configured=${lib.escapeShellArg ipadConnector}
      fallback=${lib.escapeShellArg cfg.sunshine.fallbackConnector}
      runtime_config="''${RUNTIME_DIRECTORY:?systemd did not provide RUNTIME_DIRECTORY}/sunshine.conf"

      connector_directory() {
        local connector="$1"
        local directory
        for directory in /sys/class/drm/card*-"$connector"; do
          [[ -d "$directory" ]] || continue
          printf '%s\n' "$directory"
          return 0
        done
        return 1
      }

      connector_state() {
        local connector="$1"
        local directory
        directory="$(connector_directory "$connector")" || return 1
        [[ -r "$directory/enabled" && -r "$directory/status" ]] || return 1
        [[ "$(<"$directory/enabled")" == enabled && "$(<"$directory/status")" == connected ]]
      }

      active_session() {
        loginctl show-seat seat0 --property ActiveSession --value 2>/dev/null || true
      }

      import_graphical_environment() {
        unset \
          WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE \
          NIRI_SOCKET MANGO_INSTANCE_SIGNATURE
        while IFS= read -r entry; do
          case "$entry" in
            WAYLAND_DISPLAY=* | DISPLAY=* | XDG_CURRENT_DESKTOP=* | XDG_SESSION_DESKTOP=* | XDG_SESSION_TYPE=* | NIRI_SOCKET=* | MANGO_INSTANCE_SIGNATURE=*)
              export "''${entry?}"
              ;;
          esac
        done < <(systemctl --user show-environment)

        if [[ -n "''${WAYLAND_DISPLAY:-}" && ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
          unset WAYLAND_DISPLAY
        fi
      }

      import_graphical_environment
      selected=""
      # The persistent daemon validates its encoder before accepting clients,
      # so briefly bring up the dummy for that probe. The pre-probe stream hook
      # repeats this before each real stream; the last-client hook turns it off.
      if [[ -n "$configured" ]]; then
        ${ipadDisplaySessionOn}/bin/ipad-display-session-on || true
        for _ in $(seq 1 30); do
          if connector_state "$configured"; then
            selected="$configured"
            break
          fi
          sleep 1
        done
      fi

      if [[ -z "$selected" && -n "$fallback" ]] && connector_state "$fallback"; then
        selected="$fallback"
      fi
      if [[ -z "$selected" ]]; then
        for directory in /sys/class/drm/card*-*; do
          [[ -r "$directory/enabled" && "$(<"$directory/enabled")" == enabled ]] || continue
          [[ -r "$directory/status" && "$(<"$directory/status")" == connected ]] || continue
          selected="''${directory##*/}"
          selected="''${selected#card*-}"
          break
        done
      fi
      [[ -n "$selected" ]] || {
        printf '%s\n' 'No connected, enabled DRM output is available for Sunshine.' >&2
        exit 1
      }

      install -m 0600 -- ${sunshineKmsConfig} "$runtime_config"
      printf '\noutput_name = %s\n' "$selected" >>"$runtime_config"
      printf 'Starting persistent KMS Sunshine on stable connector %s.\n' "$selected"

      session="$(active_session)"
      ${lib.getExe config.services.sunshine.package} "$runtime_config" &
      sunshine_pid=$!
      cleanup() {
        kill "$sunshine_pid" 2>/dev/null || true
        wait "$sunshine_pid" 2>/dev/null || true
        if [[ "$selected" == "$configured" ]]; then
          ${ipadDisplaySessionOff}/bin/ipad-display-session-off || true
        fi
      }
      trap cleanup EXIT INT TERM

      # Encoder probing completes before Sunshine opens its HTTPS listener.
      # Once it is ready, remove the idle dummy from the compositor layout.
      for _ in $(seq 1 60); do
        kill -0 "$sunshine_pid" 2>/dev/null || break
        if ss -Hln sport = :47990 | grep -q .; then
          if [[ "$selected" == "$configured" ]]; then
            ${ipadDisplaySessionOff}/bin/ipad-display-session-off || true
          fi
          break
        fi
        sleep 1
      done

      while kill -0 "$sunshine_pid" 2>/dev/null; do
        sleep 2
        current_session="$(active_session)"
        if [[ "$current_session" != "$session" ]]; then
          printf 'Active seat session changed from %s to %s; refreshing KMS topology.\n' \
            "''${session:-none}" "''${current_session:-none}"
          exit 75
        fi
      done
      wait "$sunshine_pid"
    '';
  };
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

    sunshine = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "plasma"
          "kms"
        ];
        default = "plasma";
        description = "Run Sunshine per Plasma session or persistently below every graphical session with KMS capture.";
      };

      fallbackConnector = lib.mkOption {
        type = lib.types.strMatching "^[A-Za-z0-9._-]+$";
        default = "DP-1";
        description = "Local DRM output captured when the configured iPad dummy is unavailable.";
      };
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

    # This workstation is either running or shut down. Never allow desktop
    # idleness, a power-management daemon, or a manual suspend request to put
    # it into a partially reachable sleep state.
    systemd.sleep.settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };

    networking = {
      hostName = "chev-desktop";
      networkmanager.enable = true;
      # Lan Mouse is a TLS-authenticated, peer-to-peer software KVM. Limit
      # its discovery/input port to the wired home-LAN interface.
      firewall.interfaces.eno1.allowedUDPPorts = [ 4242 ];
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
      openrazer = {
        enable = true;
        users = [ cfg.user ];
        # This workstation intentionally never locks or sleeps. Do not leave
        # the keyboard, keypad, and mouse dark when a compositor changes its
        # notion of screensaver state during a remote desktop session.
        devicesOffOnScreensaver = false;
        syncEffectsEnabled = true;
        batteryNotifier = {
          enable = true;
          frequency = 600;
          percentage = 20;
        };
      };
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

      # Synapse profile mappings are reproduced with a compositor-independent
      # evdev/uinput layer, so they work in Plasma and every Wayland session.
      input-remapper.enable = true;

      sunshine = {
        enable = true;
        autoStart = !sunshineKms;
        openFirewall = true;
        # Keep CUDA interop available as a fallback without enabling CUDA
        # globally. The local KMS patch selects the iPad by stable connector
        # name and exposes pre-probe and final-client-disconnected hooks.
        package = sunshinePackage;
        settings = {
          sunshine_name = "CHEV-DESKTOP";
          capture = if sunshineKms then "kms" else "kwin";
          # Vulkan Video is hardware accelerated on the RTX 3090 Ti and has
          # already sustained the exact 2732x2048 iPad mode. Unlike NVENC's
          # Linux CUDA interop path, it does not stall Sunshine's PipeWire
          # consumer when a demanding game saturates the general GPU cores.
          encoder = "vulkan";
          file_state = "sunshine_state.json";
          credentials_file = "sunshine_state.json";
          cert = "credentials/cacert.pem";
          pkey = "credentials/cakey.pem";
          system_tray = !sunshineKms;
        }
        // lib.optionalAttrs (!sunshineKms && cfg.ipadDisplay.connector != null) {
          output_name = cfg.ipadDisplay.connector;
        };
        applications.apps = [
          (
            {
              name = "Desktop";
            }
            // lib.optionalAttrs (!sunshineKms && cfg.ipadDisplay.connector != null) {
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
              cmd =
                if sunshineKms then
                  "${sunshineSessionRun}/bin/sunshine-session-run ${pkgs.steam}/bin/steam steam://open/bigpicture"
                else
                  "${pkgs.steam}/bin/steam steam://open/bigpicture";
              auto-detach = "true";
            }
            // lib.optionalAttrs (!sunshineKms && cfg.ipadDisplay.connector != null) {
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

    # Upstream starts the privileged daemon but does not apply configured
    # autoload profiles. Do that after it owns its D-Bus name so mappings are
    # restored at boot regardless of which graphical session Alex chooses.
    systemd.services.input-remapper.serviceConfig.ExecStartPost = [
      "${lib.getExe' pkgs.util-linux "runuser"} -u ${cfg.user} -- ${lib.getExe' pkgs.input-remapper "input-remapper-control"} --command autoload --config-dir /home/${cfg.user}/.config/input-remapper-2"
    ];

    # The Phantom Green accepts the Basilisk V3 button protocol on interface
    # zero, which browsers cannot address through WebHID. Apply a volatile
    # Linux-only layer after boot and whenever either transport reconnects.
    # Its onboard Windows profile remains untouched.
    systemd.services.razer-basilisk-linux-bindings = {
      description = "Apply volatile Linux bindings to the Razer Basilisk Phantom Green";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${lib.getExe' pkgs.coreutils "sleep"} 1";
        ExecStart = "${lib.getExe razerOnboard} --attempts 20 apply-linux";
        TimeoutStartSec = 30;
      };
    };

    # Sunshine probes displays and encoders before it runs an application's
    # prep command. Ensure a connected dummy is active first so a headless/sole
    # iPad session remains recoverable after reboot even while the LG is off.
    # ExecCondition cleanly skips autostart when the dummy is absent or cannot
    # be prepared; an ExecStartPre failure would enter a restart loop and can
    # block Plasma from stopping graphical-session.target during logout.
    systemd.user.services.sunshine.serviceConfig.ExecCondition = lib.mkIf (
      !sunshineKms && cfg.ipadDisplay.connector != null
    ) "${ipadDisplayEnsure}/bin/ipad-display-ensure";
    # Keep the scheduling capability available for the compiled NVENC fallback
    # so its EGL context can request high GPU priority. Grant only that narrow
    # capability through a root-owned wrapper; CAP_SYS_ADMIN is neither needed
    # nor granted.
    security.wrappers.sunshine = lib.mkIf (!sunshineKms) {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_nice+p";
      source = lib.getExe config.services.sunshine.package;
    };
    systemd.user.services.sunshine.serviceConfig.ExecStart = lib.mkIf (!sunshineKms) (
      lib.mkForce "${config.security.wrapperDir}/sunshine ${sunshineConfig}"
    );
    # The current capture backend and dummy-display preparation are both
    # Plasma-specific. Do not let an experimental compositor session churn
    # through KScreen retries and Sunshine's restart limit.
    systemd.user.services.sunshine.unitConfig =
      if sunshineKms then
        {
          RefuseManualStart = true;
        }
      else
        {
          ConditionEnvironment = "XDG_CURRENT_DESKTOP=KDE";
        };

    # A single system-owned unit remains alive while SDDM and the selectable
    # Wayland compositors trade DRM master. It still runs as Alex and reuses
    # the existing ~/.config/sunshine pairing state; only the KMS capture and
    # scheduling capabilities are elevated. The web rescue terminal is kept
    # independent so a failed capture experiment cannot strand the machine.
    systemd.services.sunshine = lib.mkIf sunshineKms {
      description = "Persistent KMS game stream host for Moonlight";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "user@1000.service"
      ];
      after = [
        "display-manager.service"
        "network-online.target"
        "user@1000.service"
      ];
      startLimitIntervalSec = 500;
      startLimitBurst = 10;
      path = [
        pkgs.coreutils
        pkgs.systemd
      ];
      environment = {
        HOME = "/home/${cfg.user}";
        XDG_CONFIG_HOME = "/home/${cfg.user}/.config";
        XDG_RUNTIME_DIR = "/run/user/1000";
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
        PULSE_SERVER = "unix:/run/user/1000/pulse/native";
        XDG_SEAT = "seat0";
        SUNSHINE_STREAM_START_COMMAND = lib.getExe ipadDisplaySessionOn;
        SUNSHINE_STREAM_STOP_COMMAND = lib.getExe ipadDisplaySessionOff;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = "users";
        SupplementaryGroups = [
          "audio"
          "input"
          "uinput"
          "video"
        ];
        RuntimeDirectory = "sunshine";
        RuntimeDirectoryMode = "0700";
        ExecStart = lib.getExe sunshineKmsLauncher;
        Restart = "always";
        RestartSec = 5;
        UMask = "0077";
        AmbientCapabilities = [
          "CAP_SYS_ADMIN"
          "CAP_SYS_NICE"
        ];
        CapabilityBoundingSet = [
          "CAP_SYS_ADMIN"
          "CAP_SYS_NICE"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictRealtime = false;
      };
    };

    # Niri does not implement the InputCapture portal required by
    # Synergy/Deskflow server mode. Lan Mouse uses niri's supported
    # layer-shell and wlroots virtual-input protocols instead.
    systemd.user.services.lan-mouse = {
      description = "Share keyboard and mouse with LAN peers";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe lanMouse} daemon";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # KWin's direct-scanout overlays bypass the framebuffer KMS captures.
    # Disable them for both Plasma and SDDM while persistent capture is active.
    environment.sessionVariables.KWIN_USE_OVERLAYS = lib.mkIf sunshineKms "0";
    systemd.services.display-manager.environment.KWIN_USE_OVERLAYS = lib.mkIf sunshineKms "0";
    # Sunshine's DualSense emulation uses UHID in addition to UInput. The
    # upstream udev rules also grant access to the virtual devices Sunshine
    # creates so their advanced controller features remain usable.
    services.udev.extraRules = ''
      KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{name}=="Sunshine PS5 (virtual) pad*", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="1532", GROUP="openrazer", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1532", GROUP="openrazer", MODE="0660", TAG+="uaccess"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1532", ATTR{idProduct}=="00d[67]", TAG+="systemd", ENV{SYSTEMD_WANTS}+="razer-basilisk-linux-bindings.service"
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
      # Keep PipeWire and the user bus available to the persistent Sunshine
      # service even while SDDM owns the visible session.
      linger = sunshineKms;
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
      ipadDisplaySessionOff
      ipadDisplaySessionOn
      kdePackages.kcalc
      kdePackages.kdenlive
      kdePackages.kdialog
      krita
      ksnip
      lanMouse
      linearWebApp
      libimobiledevice
      libva-utils
      mangohud
      nvtopPackages.nvidia
      pciutils
      pulseaudio
      polychromatic
      razerOnboard
      slack
      teamsWebApp
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
      {
        assertion = builtins.match "^[A-Za-z0-9._-]+$" cfg.sunshine.fallbackConnector != null;
        message = "dotfiles.desktop.sunshine.fallbackConnector contains unsafe characters";
      }
    ];
  };
}
