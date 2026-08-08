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
  steamLibrary = cfg.steamLibrary;
  battleNetAppId = toString cfg.battleNet.appId;
  battleNetPrefix = "${config.xdg.dataHome}/Steam/steamapps/compatdata/${battleNetAppId}";
  battleNetExecutable = "${battleNetPrefix}/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe";
  battleNetSchemes = [
    "x-scheme-handler/battlenet"
    "x-scheme-handler/blizzard"
    "x-scheme-handler/heroes"
  ];
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
    battleNet = {
      enable = lib.mkEnableOption "Battle.net browser callbacks for a Steam-managed Proton prefix";
      appId = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2527490029;
        description = "Steam non-game shortcut ID whose Proton prefix contains Battle.net.";
      };
    };
  };

  config = lib.mkMerge [
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
          Description = "Keep Steam running silently with the graphical session";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStartPre = lib.getExe steamVrDefaults;
          ExecStart = "${lib.getExe pkgs.steam} -silent";
          Restart = "always";
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
  ];
}
