{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.gaming;
  linuxWorkstation =
    pkgs.stdenv.hostPlatform.isLinux && config.dotfiles.profile == "nixos-desktop";
  haloEnabled = linuxWorkstation && cfg.haloCampaignEvolved.enable;
  steamLibrary = cfg.steamLibrary;
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
      xdg.configFile."autostart/steam.desktop" = {
        force = true;
        text = ''
          [Desktop Entry]
          Type=Application
          Name=Steam
          Comment=Start Steam silently so installed games stay current
          Exec=${lib.getExe pkgs.steam} -silent
          Icon=steam
          Terminal=false
          StartupNotify=false
          X-GNOME-Autostart-enabled=true
        '';
      };
    })
  ];
}
