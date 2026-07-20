{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.plasma;
  enabled = pkgs.stdenv.hostPlatform.isLinux && cfg.enable;
  wallpaper = config.dotfiles.wallpaper;
  wallpaperTargets = [
    {
      url = "file://${wallpaper.installedPath}";
      width = wallpaper.logicalWidth;
      height = wallpaper.logicalHeight;
    }
  ]
  ++ lib.optional (wallpaper.ipad.connector != null) {
    url = "file://${wallpaper.ipad.installedPath}";
    width = wallpaper.ipad.logicalWidth;
    height = wallpaper.ipad.logicalHeight;
  };
  launchers = map (desktopId: "applications:${desktopId}") cfg.taskbarLaunchers;
  plasmaTaskbarScript = pkgs.writeText "dotfiles-plasma-taskbar.js" ''
    const desired = ${builtins.toJSON launchers};
    let found = 0;

    for (const panel of panels()) {
      for (const widget of panel.widgets()) {
        if (widget.type !== "org.kde.plasma.icontasks") {
          continue;
        }

        widget.currentConfigGroup = ["General"];
        widget.writeConfig("launchers", desired);
        widget.reloadConfig();
        found++;
      }
    }

    if (found === 0) {
      throw new Error("No Icons-Only Task Manager was found");
    }
    print("dotfiles-plasma-taskbar: applied=" + found);
  '';
  applyPlasmaTaskbar = pkgs.writeShellApplication {
    name = "dotfiles-apply-plasma-taskbar";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      attempt=0
      until busctl --user status org.kde.plasmashell >/dev/null 2>&1; do
        ((attempt += 1))
        if ((attempt >= 100)); then
          printf '%s\n' 'Plasma Shell did not appear on the user bus.' >&2
          exit 1
        fi
        sleep 0.1
      done

      script="$(<${plasmaTaskbarScript})"
      exec busctl --user call \
        org.kde.plasmashell \
        /PlasmaShell \
        org.kde.PlasmaShell \
        evaluateScript \
      s "$script"
    '';
  };
  plasmaWallpaperScript = pkgs.writeText "dotfiles-plasma-wallpaper.js" ''
    const targets = ${builtins.toJSON wallpaperTargets};
    let found = 0;

    for (const desktop of desktops()) {
      const geometry = screenGeometry(desktop.screen);
      const target = targets.find(
        candidate => candidate.width === geometry.width && candidate.height === geometry.height
      );
      if (target === undefined) {
        continue;
      }

      desktop.wallpaperPlugin = "org.kde.image";
      desktop.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
      desktop.writeConfig("Image", target.url);
      desktop.writeConfig("FillMode", "2");
      desktop.reloadConfig();
      found++;
    }

    print("dotfiles-plasma-wallpaper: applied=" + found);
  '';
  applyPlasmaWallpaper = pkgs.writeShellApplication {
    name = "dotfiles-apply-plasma-wallpaper";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      attempt=0
      until busctl --user status org.kde.plasmashell >/dev/null 2>&1; do
        ((attempt += 1))
        if ((attempt >= 100)); then
          printf '%s\n' 'Plasma Shell did not appear on the user bus.' >&2
          exit 1
        fi
        sleep 0.1
      done

      script="$(<${plasmaWallpaperScript})"
      exec busctl --user call \
        org.kde.plasmashell \
        /PlasmaShell \
        org.kde.PlasmaShell \
        evaluateScript \
        s "$script"
    '';
  };
in
{
  imports = [
    ./core.nix
    ./wallpaper.nix
  ];

  options.dotfiles.plasma = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.profile == "nixos-desktop";
      description = "Manage narrowly scoped Plasma workstation preferences.";
    };

    taskbarLaunchers = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "^[A-Za-z0-9._+-]+[.]desktop$");
      default = [ ];
      description = "Stable desktop-file IDs pinned to Plasma's Icons-Only Task Manager.";
    };
  };

  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        # This desktop is frequently used through Sunshine and other persistent
        # remote sessions. Keep the session and its display available while the
        # machine is idle, without weakening deliberate screen locking or the
        # lock that protects an explicitly suspended machine.
        home.activation.plasmaIdlePolicy = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          kwrite=${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"}

          # XWayland has one session-wide scale even though Wayland outputs can
          # scale independently. Keep legacy games at the LG's native 100%; the
          # iPad dummy retains its per-output 175% scale for native Wayland apps.
          run "$kwrite" --file kwinrc --group Xwayland \
            --key Scale --notify 1

          run "$kwrite" --file kscreenlockerrc --group Daemon \
            --key Autolock --type bool --notify false
          run "$kwrite" --file kscreenlockerrc --group Daemon \
            --key Lock --type bool --notify true
          run "$kwrite" --file kscreenlockerrc --group Daemon \
            --key RequirePassword --type bool --notify true
          run "$kwrite" --file kscreenlockerrc --group Daemon \
            --key LockOnResume --type bool --notify true

          run "$kwrite" --file powerdevilrc --group AC --group Display \
            --key DimDisplayWhenIdle --type bool --notify false
          run "$kwrite" --file powerdevilrc --group AC --group Display \
            --key TurnOffDisplayWhenIdle --type bool --notify false
          run "$kwrite" --file powerdevilrc --group AC --group SuspendAndShutdown \
            --key AutoSuspendAction --notify 0

          # PowerDevil registers its idle timeout when loading the profile and
          # does not reliably react to KConfig notifications alone. Reload the
          # running daemon so the no-suspend value takes effect immediately.
          busctl=${lib.getExe' pkgs.systemd "busctl"}
          if "$busctl" --user status org.kde.Solid.PowerManagement >/dev/null 2>&1; then
            run "$busctl" --user call \
              org.kde.Solid.PowerManagement \
              /org/kde/Solid/PowerManagement \
              org.kde.Solid.PowerManagement \
              reparseConfiguration
            run "$busctl" --user call \
              org.kde.Solid.PowerManagement \
              /org/kde/Solid/PowerManagement \
              org.kde.Solid.PowerManagement \
              refreshStatus
          fi
        '';
      }

      (lib.mkIf (cfg.taskbarLaunchers != [ ]) {
        home.packages = [ applyPlasmaTaskbar ];

        # Plasma otherwise records dragged launchers as file:// URLs, including
        # generation-specific /nix/store paths. Reconcile only the task manager's
        # launcher key through Plasma's live API; all other panel and widget state
        # remains mutable and owned by Plasma.
        systemd.user.services.dotfiles-plasma-taskbar = {
          Unit = {
            Description = "Reconcile Plasma taskbar launchers";
            PartOf = [ "plasma-workspace.target" ];
            After = [ "plasma-plasmashell.service" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe applyPlasmaTaskbar;
            Slice = "session.slice";
          };
          Install.WantedBy = [ "plasma-workspace.target" ];
        };

        # A running Plasma session should receive a newly activated launcher list
        # immediately. The user unit above remains the authoritative retry path on
        # every later Plasma login, including after a generation rollback.
        home.activation.plasmaTaskbarLaunchers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if ${lib.getExe' pkgs.systemd "busctl"} --user status org.kde.plasmashell >/dev/null 2>&1; then
            if ! run ${lib.getExe applyPlasmaTaskbar}; then
              echo 'Could not update the live Plasma taskbar; it will retry at the next Plasma login.' >&2
            fi
          fi
        '';
      })

      (lib.mkIf wallpaper.enable {
        home.packages = [ applyPlasmaWallpaper ];

        # Plasma's numeric screen index changes when the iPad dummy is the only
        # active output. Match the LG's logical geometry instead, and retry on
        # KWin output changes so hot-plugging the LG is handled as well.
        systemd.user.services.dotfiles-plasma-wallpaper = {
          Unit = {
            Description = "Set per-display Plasma wallpapers";
            PartOf = [ "plasma-workspace.target" ];
            After = [ "plasma-plasmashell.service" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe applyPlasmaWallpaper;
            Slice = "session.slice";
          };
          Install.WantedBy = [ "plasma-workspace.target" ];
        };

        systemd.user.paths.dotfiles-plasma-wallpaper = {
          Unit = {
            Description = "Watch Plasma output topology for per-display wallpapers";
            PartOf = [ "plasma-workspace.target" ];
          };
          Path.PathChanged = "%h/.config/kwinoutputconfig.json";
          Install.WantedBy = [ "plasma-workspace.target" ];
        };

        home.activation.plasmaWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if ${lib.getExe' pkgs.systemd "busctl"} --user status org.kde.plasmashell >/dev/null 2>&1; then
            if ! run ${lib.getExe applyPlasmaWallpaper}; then
              echo 'Could not update the live Plasma wallpaper; it will retry at the next Plasma login.' >&2
            fi
          fi
        '';
      })
    ]
  );
}
