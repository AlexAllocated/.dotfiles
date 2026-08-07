{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.desktop;
  workstationPackageOverlay = _final: prev: {
    firefox = prev.firefox.overrideAttrs (oldAttrs: {
      # The 2026-07-25 Nixpkgs Firefox wrapper stopped exporting these schema
      # roots. Firefox's native Wayland chrome then lost text and collapsed
      # popup menus even though the same binary rendered correctly when the
      # previous wrapper supplied them. Repair the runtime environment without
      # disabling native Wayland, fractional scaling, or GPU acceleration.
      # Firefox is constructed with buildCommand, so postFixup is not run.
      # Extend its native wrapper arguments instead; this also keeps .override
      # available for the NixOS Firefox module.
      makeWrapperArgs = (oldAttrs.makeWrapperArgs or [ ]) ++ [
        "--prefix"
        "XDG_DATA_DIRS"
        ":"
        (lib.concatStringsSep ":" [
          "${prev.gsettings-desktop-schemas}/share/gsettings-schemas/${prev.gsettings-desktop-schemas.name}"
          "${prev.gtk3}/share/gsettings-schemas/${prev.gtk3.name}"
        ])
      ];
    });
    flameshot = prev.flameshot.overrideAttrs (_oldAttrs: {
      # Version 13 spans one editor over global desktop coordinates and breaks
      # its toolbar on a fractionally scaled output with a nonzero origin. V14
      # captures one monitor at a time, normalizes child widgets to local
      # coordinates, and uses the portal rather than the legacy grim adapter.
      version = "14.0.0";
      src = prev.fetchFromGitHub {
        owner = "flameshot-org";
        repo = "flameshot";
        tag = "v14.0.0";
        hash = "sha256-GnJ3nOJyyqQbCTMrTYhnQfEOXqCy0x3IapX/PsaZ3VI=";
      };
      patches = [
        ../../patches/flameshot-v14-nix-dependencies.patch
        ../../patches/flameshot-v14-wayland-app-id.patch
        ../../patches/flameshot-v14-wayland-overlay.patch
        # Stable v14 predates this two-line upstream fix for outputs whose
        # logical origin is not (0, 0), such as the Sunshine iPad display.
        ../../patches/flameshot-v14-nonzero-origin.patch
      ];
    });
  };
  sunshineKms = cfg.sunshine.mode == "kms";
  steamVrCompositorLauncher = "/home/${cfg.user}/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher";
  steamVrCapabilityScript = ''
    target=${lib.escapeShellArg steamVrCompositorLauncher}
    if [ -x "$target" ]; then
      current="$(${pkgs.libcap}/bin/getcap "$target" || true)"
      case "$current" in
        *cap_sys_nice*) ;;
        *) ${pkgs.libcap}/bin/setcap cap_sys_nice=eip "$target" ;;
      esac
    fi
  '';
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
    # The plugin resolves that probe beside OBS's real executable, bypassing
    # a wrapper around only the helper, so the parent process must export the
    # driver path for the child to inherit as well.
    postBuild = ''
      wrapProgram $out/bin/obs \
        --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
      wrapProgram $out/bin/obs-nvenc-test \
        --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    '';
    inherit (pkgs.obs-studio) meta passthru;
  };
  discordNvidia = pkgs.symlinkJoin {
    name = "discord-nvidia-${pkgs.discord.version}";
    paths = [ pkgs.discord ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # Discord's native voice module loads libva itself before it advertises the
    # Linux VA-API encoder. Expose both libva and the NVIDIA driver, while
    # retaining CUDA/NVENC for hardware-accelerated screen sharing. Keep
    # Discord native on Wayland so its PipeWire source picker and frame
    # presentation do not fall through XWayland.
    # Graphical auto-login has no PAM password with which to unlock KWallet,
    # so avoid its setup prompt.
    postBuild = ''
      wrapProgram $out/opt/Discord/Discord \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.libva ]}:/run/opengl-driver/lib" \
        --set LIBVA_DRIVER_NAME nvidia \
        --set LIBVA_DRIVERS_PATH /run/opengl-driver/lib/dri \
        --set NVD_BACKEND direct \
        --suffix VK_ADD_DRIVER_FILES : /run/opengl-driver/share/vulkan/icd.d \
        --add-flags "--ozone-platform=wayland" \
        --add-flags "--enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer" \
        --add-flags "--enable-wayland-ime=true" \
        --add-flags --password-store=basic
    '';
    inherit (pkgs.discord) meta passthru;
  };
  vesktopWayland = pkgs.symlinkJoin {
    name = "vesktop-wayland-${pkgs.vesktop.version}";
    paths = [ pkgs.vesktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # Keep Vesktop on the browser-style WebRTC path that played incoming
    # streams smoothly and exposed Niri's PipeWire source picker.
    postBuild = ''
      wrapProgram $out/bin/vesktop \
        --set NIXOS_OZONE_WL 1 \
        --add-flags "--ozone-platform=wayland" \
        --add-flags "--enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer" \
        --add-flags "--enable-wayland-ime=true"
    '';
    inherit (pkgs.vesktop) meta passthru;
  };
  razerQdHidSource = pkgs.fetchFromGitHub {
    owner = "AlexAllocated";
    repo = "razerqdhid";
    rev = "2fe504e10dd7f8ea7c6b5d4cfd04d946575b2b5d";
    hash = "sha256-5po6knQogtjHLauDo2pa0QVQQG9oCiX4OHseSESTriw=";
  };
  razerOnboardPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.hidapi ]);
  openRazerHealthCheck = pkgs.writeShellScript "openrazer-health-check" ''
    for attempt in $(${pkgs.coreutils}/bin/seq 1 15); do
      if ${pkgs.coreutils}/bin/timeout 1 \
        ${pkgs.systemd}/bin/busctl --user call \
          org.razer /org/razer razer.devices getDevices \
          >/dev/null 2>&1; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    printf '%s\n' 'OpenRazer acquired D-Bus but did not become responsive; restarting it.' >&2
    exit 1
  '';
  razerProfileDirectory = ../../razer/input-remapper-2/presets + "/Razer Razer Basilisk V3 Pro 35K";
  razerProfileDirect = pkgs.writeShellApplication {
    name = "razer-profile-direct";
    runtimeInputs = [ razerOnboardPython ];
    text = ''
      export PYTHONPATH=${razerQdHidSource}/public/py
      exec ${razerOnboardPython}/bin/python3 ${../../scripts/nixos/razer-onboard.py} \
        --profiles-dir ${lib.escapeShellArg (toString razerProfileDirectory)} \
        --state-file /home/${cfg.user}/.local/state/razer-profile/current \
        "$@"
    '';
  };
  razerProfile = pkgs.writeShellApplication {
    name = "razer-profile";
    runtimeInputs = [
      pkgs.systemd
      razerProfileDirect
    ];
    text = ''
      needs_hardware=false
      for argument in "$@"; do
        case "$argument" in
          apply-profile|reapply-profile|reset-onboard|dump)
            needs_hardware=true
            ;;
        esac
      done

      openrazer_was_active=false
      polychromatic_tray_was_active=false
      polychromatic_tray_unit=polychromatic-tray.service
      user_systemctl=(systemctl --machine=${cfg.user}@.host --user)
      if [[ "$EUID" -eq 0 ]]; then
        user_busctl=(busctl --machine=${cfg.user}@.host --user)
      else
        user_busctl=(busctl --user)
      fi
      if [[ "$needs_hardware" == true ]] \
        && "''${user_systemctl[@]}" is-active --quiet openrazer-daemon.service 2>/dev/null; then
        if "''${user_systemctl[@]}" is-active --quiet "$polychromatic_tray_unit" 2>/dev/null; then
          polychromatic_tray_was_active=true
        fi
        "''${user_systemctl[@]}" stop openrazer-daemon.service
        openrazer_was_active=true
      fi

      restore_openrazer() {
        if [[ "$openrazer_was_active" == true ]]; then
          "''${user_systemctl[@]}" start openrazer-daemon.service || true
          # Polychromatic caches OpenRazer D-Bus device proxies. They remain
          # permanently stale if its XDG autostart tray survives the direct
          # HID profile transaction and daemon restart.
          if [[ "$polychromatic_tray_was_active" == true ]]; then
            for _ in {1..20}; do
              "''${user_busctl[@]}" status org.razer >/dev/null 2>&1 && break
              ${lib.getExe' pkgs.coreutils "sleep"} 0.1
            done
            "''${user_systemctl[@]}" restart "$polychromatic_tray_unit" || true
          fi
        fi
      }
      trap restore_openrazer EXIT

      razer-profile-direct "$@"
    '';
  };
  razerProfileSync = pkgs.writeShellApplication {
    name = "razer-profile-sync";
    runtimeInputs = [
      pkgs.coreutils
      razerProfile
    ];
    text = ''
      while ! razer-profile --attempts 3 reapply-profile; do
        printf '%s\n' \
          'Razer Basilisk is unavailable; keeping its selected profile pending and retrying in 30 seconds.' >&2
        sleep 30
      done
    '';
  };
  razerProfileTrayPython = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.pygobject3
  ]);
  razerProfileTray = pkgs.writeShellApplication {
    name = "razer-profile-tray";
    runtimeInputs = [
      pkgs.libnotify
      razerProfileTrayPython
    ];
    text = ''
      export GI_TYPELIB_PATH=${
        lib.makeSearchPath "lib/girepository-1.0" (
          map lib.getLib [
            pkgs.at-spi2-core
            pkgs.gdk-pixbuf
            pkgs.glib
            pkgs.gobject-introspection-unwrapped
            pkgs.gtk3
            pkgs.harfbuzz
            pkgs.libayatana-appindicator
            pkgs.pango
          ]
        )
      }
      export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share:${pkgs.gtk3}/share:''${XDG_DATA_DIRS:-}
      exec ${razerProfileTrayPython}/bin/python3 \
        ${../../scripts/nixos/razer-profile-tray.py} \
        --controller ${lib.getExe razerProfile} \
      "$@"
    '';
  };
  lanMouseTray = pkgs.writeShellApplication {
    name = "lan-mouse-tray";
    runtimeInputs = [
      pkgs.libnotify
      razerProfileTrayPython
    ];
    text = ''
      export GI_TYPELIB_PATH=${
        lib.makeSearchPath "lib/girepository-1.0" (
          map lib.getLib [
            pkgs.at-spi2-core
            pkgs.gdk-pixbuf
            pkgs.glib
            pkgs.gobject-introspection-unwrapped
            pkgs.gtk3
            pkgs.harfbuzz
            pkgs.libayatana-appindicator
            pkgs.pango
          ]
        )
      }
      export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share:${pkgs.gtk3}/share:''${XDG_DATA_DIRS:-}
      exec ${razerProfileTrayPython}/bin/python3 \
        ${../../scripts/nixos/lan-mouse-tray.py} \
        --controller ${lib.getExe lanMouse} \
        "$@"
    '';
  };
  migrateDockerDataRoot = pkgs.writeShellApplication {
    name = "migrate-docker-data-root";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      rsync
      systemd
      util-linux
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../../scripts/nixos/migrate-docker-data-root.sh} "$@"
    '';
  };
  finalizeDockerDataRoot = pkgs.writeShellApplication {
    name = "finalize-docker-data-root";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      findutils
      gawk
      util-linux
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../../scripts/nixos/finalize-docker-data-root.sh} "$@"
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
      categories ? [ "Office" ],
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
          categories
          ;
        exec = "${launcher}/bin/${name} %U";
        icon = icon;
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
  twitchWebApp = mkChromeWebApp {
    name = "twitch";
    desktopName = "Twitch";
    comment = "Watch live streams and chat";
    url = "https://www.twitch.tv/";
    iconUrl = "https://upload.wikimedia.org/wikipedia/commons/d/d3/Twitch_Glitch_Logo_Purple.svg";
    iconHash = "sha256-fRisDEuDaFX5E9UeiOl8s88uDeq+iyHvXHRKXb5A4Hg=";
    startupWMClass = "Twitch";
    categories = [
      "AudioVideo"
      "Video"
      "Network"
    ];
  };
  youtubeWebApp = mkChromeWebApp {
    name = "youtube";
    desktopName = "YouTube";
    comment = "Watch videos and live streams";
    url = "https://www.youtube.com/";
    iconUrl = "https://www.gstatic.com/youtube/img/branding/favicon/favicon_192x192_v2.png";
    iconHash = "sha256-Ngx9QctP6rxSmceeB9DlH3+RD5OBEiCl2Cond5Kz6TU=";
    startupWMClass = "YouTube";
    categories = [
      "AudioVideo"
      "Video"
      "Network"
    ];
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
  ipadConnectors = lib.unique (
    lib.optional (cfg.ipadDisplay.connector != null) cfg.ipadDisplay.connector
    ++ cfg.ipadDisplay.connectorAliases
  );
  ipadConnectorShellWords = lib.concatStringsSep " " (map lib.escapeShellArg ipadConnectors);
  sunshineFallbackConnectors = lib.unique (
    [ cfg.sunshine.fallbackConnector ] ++ cfg.sunshine.fallbackConnectorAliases
  );
  sunshineFallbackConnectorShellWords = lib.concatStringsSep " " (
    map lib.escapeShellArg sunshineFallbackConnectors
  );
  mkIpadTool =
    name: script: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        connector=${lib.escapeShellArg ipadConnector}
        for candidate in ${ipadConnectorShellWords}; do
          for status_file in /sys/class/drm/card*-"$candidate"/status; do
            [[ -r "$status_file" && "$(<"$status_file")" == connected ]] || continue
            connector="$candidate"
            break 2
          done
        done
        export DOTFILES_IPAD_CONNECTOR="$connector"
        export DOTFILES_IPAD_EDID=${ipadEdidFirmware}/lib/firmware/edid/ipad2732.bin
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
      for candidate in ${ipadConnectorShellWords}; do
        for status_file in /sys/class/drm/card*-"$candidate"/status; do
          [[ -r "$status_file" && "$(<"$status_file")" == connected ]] || continue
          connector="$candidate"
          break 2
        done
      done
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
      pkgs.jq
      pkgs.niri
      pkgs.systemd
      pkgs.wlr-randr
    ];
    text = ''
      connector=${lib.escapeShellArg ipadConnector}
      for candidate in ${ipadConnectorShellWords}; do
        for status_file in /sys/class/drm/card*-"$candidate"/status; do
          [[ -r "$status_file" && "$(<"$status_file")" == connected ]] || continue
          connector="$candidate"
          break 2
        done
      done
      state_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dotfiles-ipad-display"
      pending_off="$state_dir/disable-pending"
      mkdir -p -- "$state_dir"

      # A new stream supersedes any disconnect cleanup that was waiting for a
      # physical monitor to return.
      rm -f -- "$pending_off"

      drm_connector_ready() {
        local directory
        for directory in /sys/class/drm/card*-"$connector"; do
          [[ -r "$directory/enabled" && -r "$directory/status" ]] || continue
          [[ "$(<"$directory/enabled")" == enabled && "$(<"$directory/status")" == connected ]] \
            && return 0
        done
        return 1
      }

      session_output_ready() {
        local desktop="$1"
        drm_connector_ready || return 1

        case "$desktop" in
          niri)
            [[ -n "''${NIRI_SOCKET:-}" && -S "''${NIRI_SOCKET:-}" ]] || return 1
            niri msg --json outputs 2>/dev/null \
              | jq -e --arg connector "$connector" \
                '.[$connector] != null and .[$connector].current_mode != null' \
                >/dev/null
            ;;
          KDE | Mango | mango)
            return 0
            ;;
          *)
            return 1
            ;;
        esac
      }

      manager_variable() {
        systemctl --user show-environment 2>/dev/null \
          | sed -n "s/^$1=//p" \
          | head -n 1 \
          || true
      }

      import_manager_variable() {
        local name="$1" value
        value="$(manager_variable "$name")"
        [[ -z "$value" ]] || export "$name=$value"
      }

      refresh_graphical_environment() {
        unset \
          WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
          MANGO_INSTANCE_SIGNATURE
        for variable in \
          WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
          MANGO_INSTANCE_SIGNATURE; do
          import_manager_variable "$variable"
        done
      }

      for attempt in $(seq 1 30); do
        refresh_graphical_environment
        desktop="$(manager_variable XDG_CURRENT_DESKTOP)"
        if session_output_ready "$desktop"; then
          exit 0
        fi

        case "$desktop" in
          KDE)
            ${ipadDisplayOn}/bin/ipad-display-on || true
            ;;
          niri)
            # Store the complete output configuration before enabling it so
            # Niri submits one coherent modeset instead of reconnecting after
            # each property update.
            niri msg output "$connector" mode 2732x2048@60.001 \
              && niri msg output "$connector" scale 1.75 \
              && niri msg output "$connector" position set 3440 0 \
              && niri msg output "$connector" on \
              || true
            ;;
          Mango | mango)
            wlr-randr --output "$connector" --on \
              --mode 2732x2048@60.001Hz --scale 1.75 --pos 3440,0 \
              || true
            ;;
          *)
            # Do not treat an SDDM modeset as a ready graphical session. The
            # compositor must publish its environment and confirm the output
            # before Sunshine is allowed to acquire KMS resources.
            ;;
        esac

        # Compositor IPC only confirms that the request was accepted. Niri in
        # particular can report success before an NVIDIA atomic commit fails.
        # Sunshine must not probe KMS until both DRM and the active compositor
        # confirm that the output exists.
        if session_output_ready "$desktop"; then
          exit 0
        fi
        printf 'Graphical output is not active in the compositor yet (%s, attempt %s/30); retrying.\n' \
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
      for candidate in ${ipadConnectorShellWords}; do
        for status_file in /sys/class/drm/card*-"$candidate"/status; do
          [[ -r "$status_file" && "$(<"$status_file")" == connected ]] || continue
          connector="$candidate"
          break 2
        done
      done
      state_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dotfiles-ipad-display"
      pending_off="$state_dir/disable-pending"
      wait_for_output=0
      if [[ "''${1:-}" == --wait-for-output ]]; then
        wait_for_output=1
        shift
      fi
      (($# == 0)) || {
        printf 'Usage: ipad-display-session-off [--wait-for-output]\n' >&2
        exit 64
      }
      mkdir -p -- "$state_dir"

      connector_ready() {
        local wanted="$1" directory
        for directory in /sys/class/drm/card*-"$wanted"; do
          [[ -r "$directory/enabled" && -r "$directory/status" ]] || continue
          [[ "$(<"$directory/enabled")" == enabled && "$(<"$directory/status")" == connected ]] \
            && return 0
        done
        return 1
      }

      other_output_ready() {
        local directory
        for directory in /sys/class/drm/card*-*; do
          [[ "$directory" == *-"$connector" ]] && continue
          [[ -r "$directory/enabled" && -r "$directory/status" ]] || continue
          [[ "$(<"$directory/enabled")" == enabled && "$(<"$directory/status")" == connected ]] \
            && return 0
        done
        return 1
      }

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

      refresh_graphical_environment() {
        unset \
          WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
          MANGO_INSTANCE_SIGNATURE
        for variable in \
          WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
          MANGO_INSTANCE_SIGNATURE; do
          import_manager_variable "$variable"
        done
      }

      disable_connector() {
        local desktop
        refresh_graphical_environment
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
            # Wait for an actual user compositor rather than changing outputs
            # underneath SDDM or an incomplete desktop handoff.
            printf 'Deferring %s cleanup for graphical environment %s.\n' \
              "$connector" "''${desktop:-unknown}"
            return 1
            ;;
        esac

        # Lan Mouse's layer-shell backend follows a newly enabled rightmost
        # output, but 0.11.0 does not move its capture edge back when that
        # output disappears. Recreate its capture surface after cleanup.
        systemctl --user try-restart lan-mouse.service || true
      }

      if ((wait_for_output)); then
        while [[ -e "$pending_off" ]]; do
          if ! connector_ready "$connector"; then
            rm -f -- "$pending_off"
            exit 0
          fi
          if other_output_ready && disable_connector; then
            rm -f -- "$pending_off"
            printf 'Disabled deferred iPad dummy output %s.\n' "$connector"
            exit 0
          fi
          sleep 1
        done
        exit 0
      fi

      touch -- "$pending_off"
      if ! connector_ready "$connector"; then
        rm -f -- "$pending_off"
        exit 0
      fi
      if other_output_ready && disable_connector; then
        rm -f -- "$pending_off"
        exit 0
      fi

      # The physical monitor may still be off when Moonlight disconnects.
      # Keep the last DRM output alive, then finish cleanup asynchronously as
      # soon as a physical output returns. A later stream removes the marker
      # in ipad-display-session-on, which cancels this worker harmlessly.
      unit="dotfiles-ipad-display-off-$(date +%s%N)"
      systemd-run --user --quiet --collect --service-type=exec \
        --unit="$unit" -- "$0" --wait-for-output
      printf 'Keeping %s enabled until another DRM output becomes active.\n' "$connector"
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
      configured_candidates=( ${ipadConnectorShellWords} )
      fallback=${lib.escapeShellArg cfg.sunshine.fallbackConnector}
      fallback_candidates=( ${sunshineFallbackConnectorShellWords} )
      runtime_config="''${RUNTIME_DIRECTORY:?systemd did not provide RUNTIME_DIRECTORY}/sunshine.conf"
      session_record="$RUNTIME_DIRECTORY/seat-session"

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

      for candidate in "''${configured_candidates[@]}"; do
        directory="$(connector_directory "$candidate" || true)"
        [[ -n "$directory" && -r "$directory/status" && "$(<"$directory/status")" == connected ]] || continue
        configured="$candidate"
        break
      done

      for candidate in "''${fallback_candidates[@]}"; do
        directory="$(connector_directory "$candidate" || true)"
        [[ -n "$directory" && -r "$directory/status" && "$(<"$directory/status")" == connected ]] || continue
        fallback="$candidate"
        break
      done

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
      configured_ready=0
      # The persistent daemon validates its encoder before accepting clients,
      # so briefly bring up the dummy for that probe. The pre-probe stream hook
      # repeats this before each real stream; the last-client hook turns it off
      # only when another active display can keep the compositor out of a
      # headless DRM state.
      if [[ -n "$configured" ]]; then
        if ${ipadDisplaySessionOn}/bin/ipad-display-session-on \
          && connector_state "$configured"; then
          configured_ready=1
          selected="$configured"
        fi
      fi

      if [[ -z "$selected" && -n "$fallback" ]] && connector_state "$fallback"; then
        selected="$fallback"
      fi
      if [[ -z "$selected" ]]; then
        for directory in /sys/class/drm/card*-*; do
          [[ -r "$directory/enabled" && "$(<"$directory/enabled")" == enabled ]] || continue
          [[ -r "$directory/status" && "$(<"$directory/status")" == connected ]] || continue
          candidate="''${directory##*/}"
          candidate="''${candidate#card*-}"
          if [[ "$candidate" == "$configured" && "$configured_ready" != 1 ]]; then
            continue
          fi
          selected="$candidate"
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
      printf '%s\n' "$session" >"$session_record"
      chmod 0600 "$session_record"
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
      # Once it is ready, remove the idle dummy from the compositor layout when
      # another active display can safely remain.
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

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "chev-desktop";
      description = "Network hostname of this native NixOS workstation.";
    };

    cpuVendor = lib.mkOption {
      type = lib.types.enum [
        "amd"
        "intel"
      ];
      default = "intel";
      description = "CPU vendor whose redistributable microcode should be enabled.";
    };

    autoLogin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the primary user should be logged into the graphical session automatically.";
    };

    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "eno1";
      description = "Wired LAN interface receiving workstation-only firewall rules, or null until discovered.";
    };

    efiPartuuid = lib.mkOption {
      type = lib.types.str;
      default = "UNCONFIGURED-EFI-PARTUUID";
      description = "Windows ESP PARTUUID generated from the validated migration manifest.";
    };

    storage = {
      rootLabel = lib.mkOption {
        type = lib.types.str;
        default = "NIXROOT";
        description = "Btrfs label containing the workstation root subvolumes.";
      };
      bootLabel = lib.mkOption {
        type = lib.types.str;
        default = "NIXBOOT";
        description = "Filesystem label of the XBOOTLDR partition.";
      };
      efiDevice = lib.mkOption {
        type = lib.types.str;
        default = "/dev/disk/by-partuuid/${cfg.efiPartuuid}";
        description = "Stable device path for the EFI System Partition.";
      };
      swapSizeMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8 * 1024;
        description = "Encrypted Btrfs swapfile size in MiB.";
      };
      requireGeneratedEfiPartuuid = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Warn when the legacy Chev ESP PARTUUID has not been generated.";
      };
    };

    ipadDisplay.connector = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = "DRM connector verified as the known dummy adapter; never the LG display.";
    };

    ipadDisplay.connectorAliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional observed DRM connector names for the same dummy adapter.";
    };

    sunshine = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "CHEV-DESKTOP";
        description = "Name advertised to Sunshine clients.";
      };
      mode = lib.mkOption {
        type = lib.types.enum [
          "session"
          "kms"
        ];
        default = "session";
        description = "Run Sunshine inside the graphical session or persistently below every compositor with KMS capture.";
      };

      fallbackConnector = lib.mkOption {
        type = lib.types.strMatching "^[A-Za-z0-9._-]+$";
        default = "DP-1";
        description = "Local DRM output captured when the configured iPad dummy is unavailable.";
      };
      fallbackConnectorAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional observed DRM connector names for the physical Sunshine fallback display.";
      };
    };
  };

  config = {
    system.stateVersion = "26.05";
    nixpkgs.overlays = [ workstationPackageOverlay ];
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Do not let several internally parallel C++/Rust builds multiply into
      # hundreds of compiler processes. On this 32 GiB, 20-thread workstation,
      # two derivations with eight cores each leave enough memory for the live
      # desktop, Docker, and Nix evaluation without throttling non-Nix work.
      max-jobs = 2;
      cores = 8;
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
      hostName = cfg.hostName;
      networkmanager.enable = true;
      # Lan Mouse is a TLS-authenticated, peer-to-peer software KVM. Limit
      # its discovery/input port to the wired home-LAN interface.
      firewall.interfaces = lib.optionalAttrs (cfg.lanInterface != null) {
        ${cfg.lanInterface}.allowedUDPPorts = [ 4242 ];
      };
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
      ++ lib.optional (ipadConnectors != [ ]) (
        "drm.edid_firmware="
        + lib.concatStringsSep "," (map (connector: "${connector}:edid/ipad2732.bin") ipadConnectors)
      );
      supportedFilesystems = [ "ntfs" ];
      loader = {
        timeout = 8;
        efi = {
          canTouchEfiVariables = true;
          efiSysMountPoint = "/efi";
        };
        systemd-boot = {
          enable = true;
          # Keep the active generation plus two known-good rollback entries.
          configurationLimit = 3;
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
        device = "/dev/disk/by-label/${cfg.storage.rootLabel}";
        fsType = "btrfs";
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@root"
        ];
      };
      "/home" = {
        device = "/dev/disk/by-label/${cfg.storage.rootLabel}";
        fsType = "btrfs";
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@home"
        ];
      };
      "/nix" = {
        device = "/dev/disk/by-label/${cfg.storage.rootLabel}";
        fsType = "btrfs";
        neededForBoot = true;
        options = [
          "compress=zstd"
          "noatime"
          "subvol=@nix"
        ];
      };
      "/swap" = {
        device = "/dev/disk/by-label/${cfg.storage.rootLabel}";
        fsType = "btrfs";
        options = [
          "noatime"
          "subvol=@swap"
        ];
      };
      "/boot" = {
        device = "/dev/disk/by-label/${cfg.storage.bootLabel}";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
      "/efi" = {
        device = cfg.storage.efiDevice;
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
    };

    warnings =
      lib.optional
        (cfg.storage.requireGeneratedEfiPartuuid && cfg.efiPartuuid == "UNCONFIGURED-EFI-PARTUUID")
        ''
          chev-desktop is being evaluated without its generated ESP PARTUUID. The
          confirmation-gated installer writes hosts/chev-desktop/hardware-generated.nix
          from the validated machine manifest before nixos-install runs.
        '';

    swapDevices = [
      {
        device = "/swap/swapfile";
        size = cfg.storage.swapSizeMiB;
      }
    ];
    zramSwap = {
      enable = true;
      memoryPercent = 25;
    };

    hardware = {
      enableRedistributableFirmware = true;
      firmware = [ ipadEdidFirmware ];
      cpu = {
        amd.updateMicrocode = lib.mkDefault (
          cfg.cpuVendor == "amd" && config.hardware.enableRedistributableFirmware
        );
        intel.updateMicrocode = lib.mkDefault (
          cfg.cpuVendor == "intel" && config.hardware.enableRedistributableFirmware
        );
      };
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
        enable = cfg.autoLogin;
        user = cfg.user;
      };
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

      # Nautilus needs desktop-independent mount, trash, and network-location
      # services because there is no full GNOME or Plasma desktop to supply
      # them implicitly.
      gvfs.enable = true;
      udisks2.enable = true;
      usbmuxd.enable = true;

      mullvad-vpn = {
        enable = true;
        package = pkgs.mullvad-vpn;
        # This workstation uses a full-device tunnel. It does not need the
        # setuid split-tunnel escape hatch, and disabling it narrows the local
        # privilege surface.
        enableExcludeWrapper = false;
      };

      # Synapse profile mappings are reproduced with a compositor-independent
      # evdev/uinput layer, so they work in every Wayland session.
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
          sunshine_name = cfg.sunshine.name;
          capture = if sunshineKms then "kms" else "kwin";
          # Encode directly through the NVIDIA hardware encoder. Vulkan Video was a
          # workaround for the previous RTX 3090 host; on Tracer it produces visible
          # flicker while capturing the iPad dummy through KMS.
          encoder = "nvenc";
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
    systemd.services.input-remapper = {
      # A new workstation does not have the mutable profile directory until
      # Home Manager's first activation. Wait for it instead of failing the
      # boot-time autoload race and succeeding only on later boots.
      after = [ "home-manager-${cfg.user}.service" ];
      serviceConfig.ExecStartPost = [
        "${lib.getExe' pkgs.util-linux "runuser"} -u ${cfg.user} -- ${lib.getExe' pkgs.input-remapper "input-remapper-control"} --command autoload --config-dir /home/${cfg.user}/.config/input-remapper-2"
      ];
    };

    # Keep local SSH, Moonlight, Plex, and other LAN services reachable while
    # Mullvad owns the default internet route. Internet-bound traffic still
    # uses the full-device VPN tunnel.
    systemd.services.mullvad-allow-lan = {
      description = "Allow local network access through Mullvad";
      wantedBy = [ "multi-user.target" ];
      requires = [ "mullvad-daemon.service" ];
      after = [ "mullvad-daemon.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        for attempt in {1..20}; do
          if ${lib.getExe' pkgs.mullvad-vpn "mullvad"} lan set allow; then
            exit 0
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 1
        done
        exit 1
      '';
    };

    # The Phantom Green accepts the Basilisk V3 button protocol on interface
    # zero, which browsers cannot address through WebHID. Reapply the selected
    # recovered Synapse layout after boot and whenever either transport
    # reconnects; the tray selector writes the same direct hardware layer. A
    # powered-off wireless mouse leaves its receiver present but cannot answer
    # profile commands, so keep the work pending in an asynchronous service
    # instead of failing an otherwise successful NixOS activation.
    systemd.services.razer-basilisk-linux-bindings = {
      description = "Reapply the selected Razer Basilisk profile";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${lib.getExe' pkgs.coreutils "sleep"} 1";
        ExecStart = lib.getExe razerProfileSync;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.razer-profile-tray = {
      description = "Razer Basilisk profile tray selector";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = lib.getExe razerProfileTray;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.lan-mouse-tray = {
      description = "Lan Mouse right-edge tray toggle";
      wantedBy = [ "graphical-session.target" ];
      partOf = [
        "graphical-session.target"
        "lan-mouse.service"
      ];
      requires = [ "lan-mouse.service" ];
      after = [
        "graphical-session.target"
        "lan-mouse.service"
      ];
      serviceConfig = {
        ExecStart = lib.getExe lanMouseTray;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # Sunshine probes displays and encoders before it runs an application's
    # prep command. Ensure a connected dummy is active first so a headless/sole
    # iPad session remains recoverable after reboot even while the LG is off.
    # ExecCondition cleanly skips autostart when the dummy is absent or cannot
    # be prepared; an ExecStartPre failure would enter a restart loop and can
    # block the compositor from stopping graphical-session.target during logout.
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
    # Session-local capture and dummy-display preparation require a compatible
    # desktop backend. Keep that legacy mode gated to a KDE session.
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
        "avahi-daemon.service"
        "network-online.target"
        "user@1000.service"
      ];
      after = [
        "avahi-daemon.service"
        "display-manager.service"
        "network-online.target"
        "user@1000.service"
      ];
      # Sunshine does not re-register its Moonlight mDNS service after Avahi
      # disappears. Couple their restarts so discovery cannot silently remain
      # absent after a configuration activation or an Avahi recovery.
      partOf = [ "avahi-daemon.service" ];
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
        # Sunshine's long-lived KMS backend can retain DRM descriptors across
        # repeated streams. Keep the soft limit well above systemd's 1024-file
        # default while retaining the existing hard ceiling.
        LimitNOFILE = "65536:524288";
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

    # The Basilisk exposes several USB interfaces while the boot-time direct
    # profile transaction is still settling. Starting OpenRazer concurrently
    # can leave it owning org.razer while its device scan is permanently
    # wedged. Start after that short window and reject any daemon that cannot
    # answer a real device query, allowing Restart=always to recover it.
    systemd.user.services.openrazer-daemon.serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStartPost = openRazerHealthCheck;
      RestartSec = 1;
    };

    # Own Polychromatic as a normal user service instead of an unordered XDG
    # autostart process. Type=dbus plus ExecStartPost makes this wait for a
    # genuinely healthy OpenRazer daemon, and profile swaps can restart the
    # tray without retaining stale D-Bus device proxies.
    systemd.user.services.polychromatic-tray = {
      description = "Polychromatic Razer lighting tray";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      requires = [ "openrazer-daemon.service" ];
      after = [ "openrazer-daemon.service" ];
      serviceConfig = {
        Type = "exec";
        ExitType = "cgroup";
        ExecStart = "${pkgs.polychromatic}/bin/polychromatic-helper --autostart";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

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
        polkitPolicyOwners = [ cfg.user ];
      };
      zsh.enable = true;
      firefox = {
        enable = true;
        policies.DontCheckDefaultBrowser = true;
        policies.Preferences."ui.key.menuAccessKeyFocuses" = {
          Status = "locked";
          Value = false;
        };
        # Alt is a first-class compositor modifier in Niri. Disable Firefox's
        # menu access key entirely so neither bare Alt nor Alt+letter chords
        # can reveal or focus the hidden menu bar.
        policies.Preferences."ui.key.menuAccessKey" = {
          Status = "locked";
          Value = 0;
        };
        policies.ExtensionSettings."{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
          installation_mode = "normal_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi";
          default_area = "navbar";
        };
      };
      gamemode = {
        enable = true;
        settings.general = {
          desiredgov = "performance";
          disable_splitlock = 1;
        };
      };
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

    # SteamVR tries to run pkexec from inside Steam's pressure-vessel
    # container, where NixOS's setuid wrapper is intentionally unavailable.
    # Apply only the scheduler capability its compositor requests, and watch
    # the mutable Steam library so an update that replaces the binary is
    # repaired without another broken setup prompt.
    systemd.services.steamvr-compositor-capability = {
      description = "Grant SteamVR compositor realtime scheduling";
      unitConfig.ConditionFileIsExecutable = steamVrCompositorLauncher;
      serviceConfig = {
        Type = "oneshot";
        PrivateTmp = true;
      };
      script = steamVrCapabilityScript;
    };
    systemd.paths.steamvr-compositor-capability = {
      description = "Watch SteamVR compositor capability";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = steamVrCompositorLauncher;
        Unit = "steamvr-compositor-capability.service";
      };
    };
    system.activationScripts.steamvrCompositorCapability.text = steamVrCapabilityScript;

    users.users.${cfg.user} = {
      isNormalUser = true;
      uid = 1000;
      # Keep PipeWire and the user bus available to persistent Sunshine even
      # while the display manager owns the visible session.
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

    # GameMode's upstream helper policies default to denying every caller.
    # Permit only the declared desktop user to change the CPU governor and
    # split-lock mitigation through GameMode's exact, packaged helpers.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (
          subject.user == ${builtins.toJSON cfg.user}
          && (
            action.id == "com.feralinteractive.GameMode.governor-helper"
            || action.id == "com.feralinteractive.GameMode.procsys-helper"
          )
        ) {
          return polkit.Result.YES;
        }
      });
    '';

    environment.systemPackages = with pkgs; [
      age
      android-tools
      btrfs-progs
      ardour
      audacity
      curl
      davinci-resolve
      discordNvidia
      vesktopWayland
      file-roller
      flameshot
      finalizeDockerDataRoot
      gimp
      git
      google-chrome
      gparted
      ipadDisplayOff
      ipadDisplayOn
      ipadDisplayPrepare
      ipadDisplaySessionOff
      ipadDisplaySessionOn
      kdePackages.kdenlive
      gnome-calculator
      krita
      ksnip
      lanMouse
      linearWebApp
      libimobiledevice
      libva-utils
      loupe
      mangohud
      migrateDockerDataRoot
      nautilus
      nvtopPackages.nvidia
      papers
      pciutils
      plex-desktop
      pulseaudio
      polychromatic
      qbittorrent
      razerProfile
      slack
      spotify
      teamsWebApp
      twitchWebApp
      usbutils
      vim
      vlc
      vulkan-tools
      wget
      wl-clipboard
      youtubeWebApp
      zenity
    ];

    assertions = [
      {
        assertion = lib.all (
          connector: builtins.match "^[A-Za-z0-9._-]+$" connector != null
        ) ipadConnectors;
        message = "dotfiles.desktop.ipadDisplay connector names contain unsafe characters";
      }
      {
        assertion = lib.all (
          connector: builtins.match "^[A-Za-z0-9._-]+$" connector != null
        ) sunshineFallbackConnectors;
        message = "dotfiles.desktop.sunshine fallback connector names contain unsafe characters";
      }
    ];
  };
}
