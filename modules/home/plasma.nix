{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.plasma;
  enabled = pkgs.stdenv.hostPlatform.isLinux && cfg.enable;
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
in
{
  imports = [ ./core.nix ];

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
    ]
  );
}
