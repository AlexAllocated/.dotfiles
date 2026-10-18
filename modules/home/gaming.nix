{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.gaming;
  linuxWorkstation = pkgs.stdenv.hostPlatform.isLinux && config.dotfiles.profile == "nixos-desktop";
  haloEnabled = linuxWorkstation && cfg.haloCampaignEvolved.enable;
  fantasyGrounds = pkgs.callPackage ../../packages/fantasy-grounds.nix { };
  steamLibrary = cfg.steamLibrary;
  battleNetAppId = toString cfg.battleNet.appId;
  battleNetPrefix = "${config.xdg.dataHome}/Steam/steamapps/compatdata/${battleNetAppId}";
  battleNetExecutable = "${battleNetPrefix}/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe";
  battleNetForceClose = pkgs.callPackage ../../packages/battlenet-force-close.nix {
    prefix = "${battleNetPrefix}/pfx";
  };
  wineDisplaySync = pkgs.pkgsCross.mingwW64.callPackage ../../packages/wine-display-sync.nix { };
  wineSessionPython = pkgs.python3.withPackages (ps: [ ps.xlib ]);
  wineSessionScripts = pkgs.runCommand "wine-session-scripts" { } ''
    mkdir -p "$out"
    cp ${../../scripts/gaming/wine-session.py} "$out/wine-session.py"
    cp ${../../scripts/gaming/wine-display-topology.py} "$out/wine-display-topology.py"
  '';
  battleNetDisplayWatcher = pkgs.writeShellApplication {
    name = "battlenet-display-sync";
    runtimeInputs = [
      pkgs.coreutils
      gamingUmu
    ];
    text = ''
      export WINEPREFIX=${lib.escapeShellArg "${battleNetPrefix}/pfx"}
      export PROTONPATH=${lib.escapeShellArg cfg.battleNet.protonPath}
      export GAMEID=umu-battlenet STORE=battlenet PROTON_USE_XALIA=0
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/wine-display-sync"
      mkdir -p "$state_dir"
      exec >>"$state_dir/battlenet.log" 2>&1
      exec ${wineSessionPython}/bin/python3 ${wineSessionScripts}/wine-session.py --prefix "$WINEPREFIX" \
        --wait-for Battle.net.exe --supervise --display-plan "$state_dir/topology/battlenet.txt" \
        -- env PROTON_VERB=runinprefix WINELOADERNOEXEC=1 umu-run 'Z:${
          builtins.replaceStrings [ "/" ] [ "\\" ] "${wineDisplaySync}/bin/wine-display-sync.exe"
        }' --watch
    '';
  };
  gamingUmu = pkgs.umu-launcher.override {
    # Separate /tmp mounts create separate Wine servers for the same prefix,
    # bypassing Battle.net's single-instance handling on every launch.
    steam = pkgs.steam // {
      buildRuntimeEnv = args: pkgs.steam.buildRuntimeEnv (args // { privateTmp = false; });
    };
    # The FHS profile exports an IANA TZ name, which Windows CRTs misparse
    # (America/Denver becomes UTC+1). Clear it after the profile runs so Wine
    # derives local time and DST from the system's mounted /etc/localtime.
    extraProfile = ''
      unset TZ
      # A launch must not perform an opportunistic runtime download (once per
      # helper, too). Initial installation still works. Opt into maintenance
      # explicitly with UMU_RUNTIME_UPDATE=1 battlenet or guild-wars-2.
      export UMU_RUNTIME_UPDATE="''${UMU_RUNTIME_UPDATE:-0}"
    '';
  };
  guildWars2Prefix = "${config.xdg.dataHome}/guild-wars-2/pfx";
  guildWars2Installer = pkgs.fetchurl {
    name = "Gw2Setup-64.exe";
    url = "https://cloudfront.guildwars2.com/client/branches/Gw2Setup-64.exe";
    hash = "sha256-b/M2AMO7KQQdeLQFDguo4dWFICNteajjgjc/noB0ZTk=";
  };
  guildWars2Launcher = pkgs.writeShellApplication {
    name = "guild-wars-2";
    runtimeInputs = [
      pkgs.coreutils
      gamingUmu
    ];
    text = ''
      export WINEPREFIX=${lib.escapeShellArg guildWars2Prefix}
      export PROTONPATH=${lib.escapeShellArg (toString pkgs.proton-ge-bin.steamcompattool)}
      export GAMEID=umu-1284210
      export STORE=none
      export PROTON_VERB=run
      executable="$WINEPREFIX/drive_c/Program Files/Guild Wars 2/Gw2-64.exe"
      if [[ ! -f "$executable" ]]; then
        # The ArenaNet bootstrapper updates itself, so run a writable copy.
        # Keep the installer's default C:\Program Files\Guild Wars 2 location.
        installer="$WINEPREFIX/drive_c/gw2-setup/Gw2Setup-64.exe"
        mkdir -p "$(dirname "$installer")"
        if [[ ! -f "$installer" ]]; then
          install -m 644 ${guildWars2Installer} "$installer"
        fi
        exec umu-run "$installer" "$@"
      fi
      cd "$(dirname "$executable")"
      exec umu-run 'C:\Program Files\Guild Wars 2\Gw2-64.exe' "$@"
    '';
  };
  wowDisplaySettings = pkgs.writeShellApplication {
    name = "wow-display-settings";
    runtimeInputs = [
      pkgs.python3
      pkgs.systemd
    ];
    text = ''
      exec python3 ${../../scripts/gaming/wow-display-settings.py} \
        ${lib.escapeShellArg "${battleNetPrefix}/pfx/drive_c/Program Files (x86)/World of Warcraft"} \
        --prefix ${lib.escapeShellArg "${battleNetPrefix}/pfx"} \
        --session-helper ${../../scripts/gaming/wine-session.py} "$@"
    '';
  };
  battleNetInstaller = pkgs.fetchurl {
    name = "Battle.net-Setup.exe";
    url = "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe";
    hash = "sha256-3l0y1Ope7VqeEgAn+2izcJdtv+zI8qj5EwWXfwuH/K8=";
  };
  battleNetDxvkConfig = pkgs.writeText "battlenet-dxvk.conf" ''
    [Diablo IV.exe]
    dxgi.maxDeviceMemory = ${toString cfg.battleNet.diabloReportedVramMiB}
  '';
  battleNetLauncher = pkgs.writeShellApplication {
    name = "battlenet";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.niri
      pkgs.python3
      pkgs.util-linux
      pkgs.systemd
      gamingUmu
    ];
    text = ''
      export WINEPREFIX=${lib.escapeShellArg "${battleNetPrefix}/pfx"}
      export PROTONPATH=${lib.escapeShellArg cfg.battleNet.protonPath}
      if [[ ! -f "$PROTONPATH/proton" ]]; then
        printf 'Battle.net Proton runtime is missing: %s\n' "$PROTONPATH" >&2
        exit 1
      fi
      ${lib.optionalString (cfg.battleNet.diabloReportedVramMiB != null) ''
        # This adjusts Diablo's cache sizing, not Vulkan allocation limits or
        # DXGI's dynamic budget. The executable section leaves other games alone.
        export DXVK_CONFIG_FILE=${battleNetDxvkConfig}
      ''}
      export GAMEID=umu-battlenet
      export STORE=battlenet
      # Xalia's Steam UI-navigation helper left live threads after its main
      # thread exited, keeping old launcher sessions alive. These games use
      # their own input; do not inject the optional Steam UI helper here.
      export PROTON_USE_XALIA=0
      # Reopening the launcher must reach its existing Wine session instead
      # of waiting for that session (including a running game) to exit.
      export PROTON_VERB=run
      mkdir -p "$WINEPREFIX"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/battlenet"
      mkdir -p "$state_dir"
      exec >>"$state_dir/launcher.log" 2>&1
      printf '\n[%s] Battle.net launch requested\n' "$(date --iso-8601=seconds)"
      # Serialize setup, not the lifetime of a game or the whole Wine session.
      exec 9>"$state_dir/startup.lock"
      if ! flock -w 45 9; then
        printf 'Another Battle.net startup is still in progress\n' >&2
        exit 1
      fi
      start_display_sync() {
        # Own this independently of a short-lived focus/URI launcher. Desktop
        # launch services may kill background children when that launcher exits.
        systemctl --user start battlenet-display-sync.service
      }
      executable=${lib.escapeShellArg battleNetExecutable}
      if [[ ! -f "$executable" ]]; then
        flock -u 9
        exec 9>&-
        exec umu-run ${battleNetInstaller}
      fi
      # Windows-form paths deliberately bypass UMU's Unix ShellExecute path,
      # so UMU cannot infer the native install directory from the executable.
      # Supply it explicitly and give the launcher a consistent working dir.
      STEAM_COMPAT_INSTALL_PATH="$(dirname "$executable")"
      export STEAM_COMPAT_INSTALL_PATH
      cd "$STEAM_COMPAT_INSTALL_PATH"
      # An explicit app-launcher request should focus the existing window.
      # Wine activation remains blocked by Niri's game focus-stealing rules.
      if (($# == 0)) && window_id=$(niri msg --json windows 2>/dev/null | jq -r '
        first(.[] | select(.title == "Battle.net" and
          ((.app_id // "" | ascii_downcase) |
           test("^steam_app_(battlenet|[0-9]+)$|^battle[.]net[.]exe$"))) | .id) // empty
      ') && [[ -n "$window_id" ]]; then
        if niri msg action focus-window --id "$window_id"; then
          start_display_sync
          exit 0
        fi
      fi
      ${lib.optionalString cfg.battleNet.disableBrowserHardwareAcceleration ''
        python3 ${../../scripts/gaming/battlenet-settings.py} --prefix "$WINEPREFIX" \
          --session-helper ${../../scripts/gaming/wine-session.py}
      ''}
      ${lib.getExe wowDisplaySettings}
      # Decide before reg.exe starts Wine. LogPixels is global to the prefix;
      # changing it while Battle.net/WoW are alive gives new processes a
      # different system DPI from the existing display/window cache.
      # Keep this shared gaming session at 100% even when launched on iPad.
      # A display-dependent baseline persists after returning to the LG and
      # enlarges WoW's UI despite native resolution and its 100% UI slider.
      dpi=""
      if requested_dpi=$(python3 ${../../scripts/nixos/wine-display-dpi.py} --prefix "$WINEPREFIX" --dpi 96); then
        dpi="$requested_dpi"
      fi
      # Windows paths avoid UMU's Unix-path ShellExecute helper, which can
      # hang when joining an already-running Wine session.
      # The SNI bridge handles docked icons. Suppress Wine's separate tray
      # window, including while the bridge is restarting.
      PROTON_VERB=runinprefix timeout --kill-after=5 30 umu-run 'C:\windows\system32\reg.exe' add \
        'HKCU\Software\Wine\Explorer' /v ShowSystray /t REG_DWORD /d 0 /f
      # Proton's emulated mode can retain the old resolution after a streaming
      # display changes, overflowing monitor_get_dpi's packed scaling ratio.
      # Use the driver's current mode instead. Current Proton Experimental
      # uses the normal boolean meaning: "N" disables modeset emulation.
      # The earlier inverted interpretation changed with the October runtime
      # update; validate changes with wine-modeset-policy-test.exe.
      PROTON_VERB=runinprefix timeout --kill-after=5 30 umu-run 'C:\windows\system32\reg.exe' add \
        'HKCU\Software\Wine\X11 Driver' /v EmulateModeset /t REG_SZ /d N /f
      if [[ -n "$dpi" ]]; then
        PROTON_VERB=runinprefix timeout --kill-after=5 30 umu-run 'C:\windows\system32\reg.exe' add \
          'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f
      fi
      start_display_sync
      # run waits for all non-system Wine processes, not just its executable.
      # Helpers above must use runinprefix; only the application uses run.
      flock -u 9
      exec 9>&-
      exec umu-run 'C:\Program Files (x86)\Battle.net\Battle.net.exe' "$@"
    '';
  };
  battleNetSchemes = [
    "x-scheme-handler/battlenet"
    "x-scheme-handler/blizzard"
    "x-scheme-handler/heroes"
  ];
  battleNetDiagnostics = pkgs.writeShellApplication {
    name = "battlenet-diagnostics";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.niri
      gamingUmu
    ];
    text = ''
      export WINEPREFIX=${lib.escapeShellArg "${battleNetPrefix}/pfx"}
      export PROTONPATH=${lib.escapeShellArg cfg.battleNet.protonPath}
      export GAMEID=umu-battlenet STORE=battlenet PROTON_VERB=runinprefix WINELOADERNOEXEC=1 PROTON_USE_XALIA=0
      printf 'Runtime: %s\n' "$(cat "$PROTONPATH/version")"
      niri msg --json outputs
      exec timeout --kill-after=5 20 umu-run 'Z:${
        builtins.replaceStrings [ "/" ] [ "\\" ] "${wineDisplaySync}/bin/wine-display-probe.exe"
      }'
    '';
  };
  battleNetUriHandler = pkgs.writeShellApplication {
    name = "battlenet-uri-handler";
    text = ''
      uri="''${1:-}"
      case "$uri" in
        battlenet://* | blizzard://* | heroes://*) ;;
        *)
          printf 'Refusing unsupported Battle.net URI: %s\n' "$uri" >&2
          exit 64
          ;;
      esac

      ${lib.optionalString cfg.battleNet.useUmu ''
        exec ${lib.getExe battleNetLauncher} "--uri=$uri"
      ''}

      executable=${lib.escapeShellArg battleNetExecutable}
      if [[ ! -f "$executable" ]]; then
        printf 'Battle.net is not installed in Steam prefix %s\n' ${lib.escapeShellArg battleNetPrefix} >&2
        exit 1
      fi

      exec ${lib.getExe' pkgs.protontricks "protontricks-launch"} \
        --appid ${battleNetAppId} \
        --no-term \
        "$executable" \
        "--uri=$uri"
    '';
  };
  haloPrefix = "${steamLibrary}/steamapps/compatdata/2806050/pfx";
  haloConfigRoot = "${haloPrefix}/drive_c/users/steamuser/AppData/Local/Meteorite/Saved/Config";
  haloSettings = pkgs.writeShellApplication {
    name = "halo-campaign-evolved-settings";
    runtimeInputs = [
      pkgs.bash
      pkgs.python3
    ];
    text = ''
      check_argument=()
      if [[ "''${1:-}" == "--check" ]]; then
        check_argument=(--check)
        shift
      fi
      if (($# != 0)); then
        printf 'usage: halo-campaign-evolved-settings [--check]\n' >&2
        exit 2
      fi

      shopt -s nullglob
      configs=(${lib.escapeShellArg haloConfigRoot}/*/HaloLocalGameUserSettings.ini)
      if ((''${#configs[@]} == 0)); then
        printf 'Halo: Campaign Evolved settings do not exist yet under %s\n' \
          ${lib.escapeShellArg haloConfigRoot}
        exit 0
      fi

      status=0
      for config_file in "''${configs[@]}"; do
        ${lib.getExe pkgs.python3} \
          ${../../scripts/gaming/halo-campaign-evolved-settings.py} \
          "''${check_argument[@]}" \
          "$config_file" || status=$?
      done
      exit "$status"
    '';
  };
  haloLauncher = pkgs.writeShellApplication {
    name = "halo-campaign-evolved";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gamemode
      pkgs.procps
      pkgs.steam
    ];
    text = ''
      ${lib.getExe haloSettings}

      if pgrep -u "$UID" -f '[H]aloCampaignEvolved[.]exe' >/dev/null; then
        printf 'Halo: Campaign Evolved is already running.\n' >&2
        exit 1
      fi

      ${lib.getExe pkgs.steam} -applaunch 2806050 >/dev/null 2>&1 &

      halo_pid=
      for _ in {1..360}; do
        halo_pid="$(pgrep -u "$UID" -f '[H]aloCampaignEvolved[.]exe' | head -n 1 || true)"
        [[ -n "$halo_pid" ]] && break
        sleep 0.5
      done

      if [[ -z "$halo_pid" ]]; then
        printf 'Halo did not start within three minutes; GameMode was not requested.\n' >&2
        exit 1
      fi

      gamemoded --request="$halo_pid"
      printf 'Halo started as PID %s with the declarative preset and GameMode.\n' "$halo_pid"
    '';
  };
  steamUiHealthcheck = pkgs.writeShellApplication {
    name = "steam-ui-healthcheck";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.dbus
      pkgs.gnugrep
      pkgs.jq
      pkgs.niri
      pkgs.procps
      pkgs.steam
      pkgs.systemd
    ];
    text = ''
      steam_service=steam-autostart.service

      steam_ui_is_visible() {
        busctl --user get-property \
          org.kde.StatusNotifierWatcher \
          /StatusNotifierWatcher \
          org.kde.StatusNotifierWatcher \
          RegisteredStatusNotifierItems 2>/dev/null \
          | grep -q '/steam"' \
          || niri msg --json windows 2>/dev/null \
            | jq -e 'any(.[]; .app_id == "steam")' >/dev/null
      }

      steam_game_is_running() {
        pgrep -u "$UID" -f '[r]eaper SteamLaunch AppId=' >/dev/null
      }

      systemctl --user is-active --quiet "$steam_service" || exit 0
      steam_ui_is_visible && exit 0

      # Never disrupt a running game just to repair the desktop UI. The next
      # timer pass after the game exits can recover a stale client instead.
      steam_game_is_running && exit 0

      # Give a healthy hidden client one chance to recreate its window before
      # treating a surviving main process as a wedged UI.
      timeout 10 steam steam://open/main >/dev/null 2>&1 || true
      sleep 5
      steam_ui_is_visible && exit 0
      steam_game_is_running && exit 0

      systemctl --user restart "$steam_service"
    '';
  };
  steamVrDefaults = pkgs.writeShellApplication {
    name = "steamvr-workstation-defaults";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      settings=${lib.escapeShellArg "${config.xdg.dataHome}/Steam/config/steamvr.vrsettings"}
      if [[ -f "$settings" ]]; then
        settings_dir="$(dirname "$settings")"
        temporary="$(mktemp --tmpdir="$settings_dir" .steamvr.vrsettings.XXXXXX)"
        trap 'rm -f "$temporary"' EXIT

        jq '.steamvr = (.steamvr // {}) | .steamvr.enableHomeApp = false' \
          "$settings" > "$temporary"
        chmod --reference="$settings" "$temporary"

        if ! cmp -s "$settings" "$temporary"; then
          mv "$temporary" "$settings"
          printf 'Disabled SteamVR Home.\n'
        else
          rm -f "$temporary"
        fi
        trap - EXIT
      fi

    '';
  };
in
{
  imports = [ ./core.nix ];

  options.dotfiles.gaming = {
    steamLibrary = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/Steam";
      description = "Steam library containing machine-local game installations and Proton prefixes.";
    };

    haloCampaignEvolved.enable = lib.mkEnableOption "the optimized Halo: Campaign Evolved preset";
    steamAutostart.enable = lib.mkEnableOption "silent Steam startup with the graphical session";
    curseforge.enable = lib.mkEnableOption "the official CurseForge addon manager";
    guildWars2.enable = lib.mkEnableOption "the standalone ArenaNet Guild Wars 2 launcher using UMU/GE-Proton";
    fantasyGrounds.enable = lib.mkEnableOption "the native Fantasy Grounds VTT installer and launcher";
    battleNet = {
      enable = lib.mkEnableOption "Battle.net browser callbacks for a Steam-managed Proton prefix";
      useUmu = lib.mkEnableOption "declarative Battle.net and Heroes launchers using UMU/GE-Proton";
      disableBrowserHardwareAcceleration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use Battle.net's software browser renderer to avoid black launcher windows under Wine; game GPU rendering is unchanged.";
      };
      protonPath = lib.mkOption {
        type = lib.types.str;
        default = toString pkgs.proton-ge-bin.steamcompattool;
        description = "Proton runtime directory for the shared Battle.net prefix. Missing runtimes fail rather than silently migrating the prefix to another version.";
      };
      diabloReportedVramMiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional adapter capacity reported only to Diablo IV to influence cache sizing. This is not a hard allocation cap and does not change the DXGI memory budget.";
      };
      appId = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2527490029;
        description = "Steam non-game shortcut ID whose Proton prefix contains Battle.net.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (linuxWorkstation && cfg.fantasyGrounds.enable) {
      home.packages = [ fantasyGrounds ];
      home.activation.fantasyGrounds = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe fantasyGrounds} --install-only
      '';
      xdg.desktopEntries.fantasy-grounds = {
        name = "Fantasy Grounds";
        comment = "Play or host a tabletop RPG with Fantasy Grounds VTT";
        exec = lib.getExe fantasyGrounds;
        icon = "${fantasyGrounds.bootstrap}/FantasyGroundsIcon.png";
        terminal = false;
        categories = [ "Game" ];
      };
      xdg.desktopEntries.fantasy-grounds-updater = {
        name = "Fantasy Grounds Updater";
        exec = "${lib.getExe fantasyGrounds} --update";
        icon = "${fantasyGrounds.bootstrap}/FantasyGroundsIcon.png";
        terminal = false;
        categories = [ "Game" ];
      };
    })

    (lib.mkIf (linuxWorkstation && cfg.guildWars2.enable) {
      home.packages = [ guildWars2Launcher ];
      xdg.desktopEntries.guild-wars-2 = {
        name = "Guild Wars 2";
        comment = "Install or play Guild Wars 2 with an ArenaNet account";
        exec = lib.getExe guildWars2Launcher;
        terminal = false;
        categories = [ "Game" ];
      };
    })

    (lib.mkIf (linuxWorkstation && cfg.curseforge.enable) {
      home.packages = [ (pkgs.callPackage ../../packages/curseforge.nix { }) ];
      xdg.mimeApps.defaultApplications = {
        "x-scheme-handler/curseforge" = [ "curseforge.desktop" ];
        "x-scheme-handler/cfauth" = [ "curseforge.desktop" ];
        "x-scheme-handler/curseforge-checkout" = [ "curseforge.desktop" ];
      };
    })

    (lib.mkIf haloEnabled {
      home.packages = [
        haloLauncher
        haloSettings
      ];

      home.activation.haloCampaignEvolvedSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe haloSettings}
      '';

      xdg.desktopEntries.halo-campaign-evolved-optimized = {
        name = "Halo: Campaign Evolved (Optimized)";
        genericName = "First-Person Shooter";
        comment = "Launch Halo with the declarative performance preset and GameMode";
        exec = lib.getExe haloLauncher;
        icon = "steam_icon_2806050";
        terminal = false;
        startupNotify = true;
        categories = [
          "Game"
          "ActionGame"
        ];
      };
    })

    (lib.mkIf (linuxWorkstation && cfg.steamAutostart.enable) {
      home.activation.steamVrDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe steamVrDefaults}
      '';

      systemd.user.services.steam-autostart = {
        Unit = {
          Description = "Start Steam silently with the graphical session";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStartPre = lib.getExe steamVrDefaults;
          ExecStart = "${lib.getExe pkgs.steam} -silent";
          # Steam exits successfully after forwarding to an existing client.
          # Restarting that helper repeatedly raises the existing Steam window.
          Restart = "on-failure";
          RestartSec = 10;
          Slice = "background.slice";
          # SteamVR's compositor promotes only its render/signal threads.
          # Permit that narrowly from this service instead of granting
          # CAP_SYS_NICE to the entire graphical session.
          LimitRTPRIO = 99;
          LimitNICE = -20;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      systemd.user.services.steam-ui-healthcheck = {
        Unit = {
          Description = "Recover a headless or wedged Steam desktop UI";
          After = [ "steam-autostart.service" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe steamUiHealthcheck;
          Slice = "background.slice";
        };
      };

      systemd.user.timers.steam-ui-healthcheck = {
        Unit.Description = "Periodically verify the Steam tray and window UI";
        Timer = {
          OnBootSec = "5m";
          OnUnitActiveSec = "2m";
          Unit = "steam-ui-healthcheck.service";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })

    (lib.mkIf (linuxWorkstation && cfg.battleNet.enable) {
      home.packages = [ battleNetUriHandler ];

      xdg.desktopEntries.battlenet-proton-handler = {
        name = "Battle.net Proton URI Handler";
        comment = "Return browser authentication to Battle.net running under Steam Proton";
        exec = "${lib.getExe battleNetUriHandler} %u";
        icon = "battlenet";
        terminal = false;
        noDisplay = true;
        mimeType = battleNetSchemes;
        categories = [ "Game" ];
      };

      xdg.mimeApps.associations.added = lib.genAttrs battleNetSchemes (_: [
        "battlenet-proton-handler.desktop"
      ]);
      xdg.mimeApps.defaultApplications = lib.genAttrs battleNetSchemes (_: [
        "battlenet-proton-handler.desktop"
      ]);
    })
    (lib.mkIf (linuxWorkstation && cfg.battleNet.enable && cfg.battleNet.useUmu) {
      systemd.user.services.battlenet-display-sync = {
        Unit = {
          Description = "Maintain Battle.net's Wine display aliases from XRandR";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
          OnFailure = [ "battlenet-display-sync-failed.service" ];
        };
        Service = {
          ExecStart = lib.getExe battleNetDisplayWatcher;
          KillMode = "control-group";
          Slice = "background.slice";
        };
      };
      home.packages = [
        battleNetLauncher
        battleNetForceClose
        battleNetDiagnostics
        wowDisplaySettings
      ];
      systemd.user.services.battlenet-display-sync-failed = {
        Unit.Description = "Report exhausted Battle.net display recovery";
        Service = {
          Type = "oneshot";
          ExecCondition = "${pkgs.systemd}/bin/systemctl --user is-active --quiet graphical-session.target";
          ExecStart = lib.escapeShellArgs [
            "${pkgs.libnotify}/bin/notify-send"
            "--app-name=Battle.net"
            "--urgency=critical"
            "Battle.net display synchronization stopped"
            "Monitor updates could not be restored. Run battlenet-diagnostics before using the tray force-quit action."
          ];
        };
      };
      home.activation.wowDisplaySettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe wowDisplaySettings}
      '';
      xdg.desktopEntries.battlenet = {
        name = "Battle.net";
        exec = "${lib.getExe battleNetLauncher}";
        terminal = false;
        categories = [ "Game" ];
      };
      xdg.desktopEntries.heroes-of-the-storm = {
        name = "Heroes of the Storm";
        exec = "${lib.getExe battleNetLauncher} --exec=\"launch Hero\"";
        terminal = false;
        categories = [ "Game" ];
      };
    })
  ];
}
