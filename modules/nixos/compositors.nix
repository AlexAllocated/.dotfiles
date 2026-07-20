{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.compositors;
  systemctl = lib.getExe' pkgs.systemd "systemctl";

  # Plasma ships its X11 and Wayland launchers in one derivation. Present a
  # small filtered package to SDDM so the chooser stays Wayland-only without
  # removing XWayland compatibility from applications running inside it.
  plasmaWaylandSession =
    pkgs.runCommand "plasma-wayland-session-only"
      {
        passthru.providedSessions = [ "plasma" ];
      }
      ''
        mkdir -p "$out/share/wayland-sessions"
        ln -s -- \
          ${pkgs.kdePackages.plasma-workspace.sessions}/share/wayland-sessions/plasma.desktop \
          "$out/share/wayland-sessions/plasma.desktop"
      '';

  mkExperimentalLauncher =
    {
      id,
      shell,
      command,
      ...
    }:
    pkgs.writeShellScript "start-${id}" ''
      export DOTFILES_DESKTOP_SHELL=${lib.escapeShellArg shell}
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"

      # Mango does not stop its graphical targets on exit, and any compositor
      # can be killed before cleaning its socket variables. Clear all of that
      # state both before this session starts and after it exits so UWSM never
      # rejects Hyprland because an older session still appears active.
      clear_session_state() {
        ${systemctl} --user stop \
          dotfiles-desktop-shell.service \
          dotfiles-compositor-polkit.service \
          mango-session.target \
          graphical-session.target \
          graphical-session-pre.target >/dev/null 2>&1 || true
        ${systemctl} --user unset-environment \
          DOTFILES_DESKTOP_SHELL \
          HYPRLAND_INSTANCE_SIGNATURE \
          NIRI_SOCKET \
          MANGO_INSTANCE_SIGNATURE \
          WAYLAND_DISPLAY \
          DISPLAY \
          XDG_CURRENT_DESKTOP \
          XDG_SESSION_TYPE \
          XDG_SESSION_DESKTOP >/dev/null 2>&1 || true
      }

      clear_session_state
      ${systemctl} --user set-environment \
        DOTFILES_DESKTOP_SHELL=${lib.escapeShellArg shell}

      compositor_pid=""
      cleanup() {
        if [[ "$compositor_pid" =~ ^[0-9]+$ ]] \
          && kill -0 "$compositor_pid" 2>/dev/null; then
          kill -TERM "$compositor_pid" 2>/dev/null || true
          wait "$compositor_pid" 2>/dev/null || true
        fi
        clear_session_state
      }

      terminate_compositor() {
        # Bash defers a TERM trap while it waits for a foreground process.
        # Supervise the compositor in the background so desktop-switch can
        # forward the handoff request instead of deadlocking in this wrapper.
        trap - HUP INT TERM
        if [[ "$compositor_pid" =~ ^[0-9]+$ ]] \
          && kill -0 "$compositor_pid" 2>/dev/null; then
          kill -TERM "$compositor_pid" 2>/dev/null || true
          for _attempt in {1..100}; do
            kill -0 "$compositor_pid" 2>/dev/null || break
            sleep 0.05
          done
          if kill -0 "$compositor_pid" 2>/dev/null; then
            kill -KILL "$compositor_pid" 2>/dev/null || true
          fi
          wait "$compositor_pid" 2>/dev/null || true
        fi
        exit 143
      }

      trap cleanup EXIT
      trap terminate_compositor HUP INT TERM

      ${command} &
      compositor_pid=$!
      wait "$compositor_pid"
    '';

  mkExperimentalSession =
    spec:
    let
      launcher = mkExperimentalLauncher spec;
    in
    pkgs.writeTextFile {
      name = "${spec.id}-wayland-session";
      destination = "/share/wayland-sessions/${spec.id}.desktop";
      text = ''
        [Desktop Entry]
        Name=${spec.name}
        Comment=Experimental Wayland session managed by Alex's dotfiles
        Exec=${launcher}
        TryExec=${launcher}
        DesktopNames=${spec.desktopNames}
        Type=Application
      '';
      derivationArgs.passthru.providedSessions = [ spec.id ];
    };

  hyprlandCommand = "/run/current-system/sw/bin/uwsm start -e -D Hyprland -F -- /run/current-system/sw/bin/start-hyprland";
  niriCommand = "/run/current-system/sw/bin/niri-session";
  mangoCommand = "/run/current-system/sw/bin/mango";

  experimentalSessionSpecs = [
    {
      id = "hyprland-noctalia";
      name = "Hyprland + Noctalia";
      desktopNames = "Hyprland";
      shell = "noctalia";
      command = hyprlandCommand;
    }
    {
      id = "hyprland-dms";
      name = "Hyprland + DMS";
      desktopNames = "Hyprland";
      shell = "dms";
      command = hyprlandCommand;
    }
    {
      id = "niri-noctalia";
      name = "Niri + Noctalia";
      desktopNames = "niri";
      shell = "noctalia";
      command = niriCommand;
    }
    {
      id = "niri-dms";
      name = "Niri + DMS";
      desktopNames = "niri";
      shell = "dms";
      command = niriCommand;
    }
    {
      id = "mango-noctalia";
      name = "Mango + Noctalia";
      desktopNames = "mango;wlroots";
      shell = "noctalia";
      command = mangoCommand;
    }
    {
      id = "mango-dms";
      name = "Mango + DMS";
      desktopNames = "mango;wlroots";
      shell = "dms";
      command = mangoCommand;
    }
  ];
  experimentalSessions = map mkExperimentalSession experimentalSessionSpecs;
  experimentalLaunchers = builtins.listToAttrs (
    map (spec: lib.nameValuePair spec.id (mkExperimentalLauncher spec)) experimentalSessionSpecs
  );

  desktopTargets = {
    plasma = {
      label = "KDE Plasma";
      command = lib.getExe' pkgs.kdePackages.plasma-workspace "startplasma-wayland";
    };
    niri-noctalia = {
      label = "Niri + Noctalia";
      command = experimentalLaunchers.niri-noctalia;
    };
    niri-dms = {
      label = "Niri + DMS";
      command = experimentalLaunchers.niri-dms;
    };
    hyprland-noctalia = {
      label = "Hyprland + Noctalia";
      command = experimentalLaunchers.hyprland-noctalia;
    };
    hyprland-dms = {
      label = "Hyprland + DMS";
      command = experimentalLaunchers.hyprland-dms;
    };
    mango-noctalia = {
      label = "Mango + Noctalia";
      command = experimentalLaunchers.mango-noctalia;
    };
    mango-dms = {
      label = "Mango + DMS";
      command = experimentalLaunchers.mango-dms;
    };
    cosmic = {
      label = "COSMIC";
      command = lib.getExe' pkgs.cosmic-session "start-cosmic";
    };
  };
  desktopTargetOrder = [
    "plasma"
    "niri-noctalia"
    "niri-dms"
    "hyprland-noctalia"
    "hyprland-dms"
    "mango-noctalia"
    "mango-dms"
    "cosmic"
  ];
  desktopTargetHelp = lib.concatMapStringsSep "\n" (
    target: "  ${target}\t${desktopTargets.${target}.label}"
  ) desktopTargetOrder;
  desktopTargetCase = lib.concatMapStringsSep "\n" (target: ''
    ${target})
      exec ${desktopTargets.${target}.command}
      ;;
  '') desktopTargetOrder;

  desktopSessionDispatcher = pkgs.writeShellApplication {
    name = "dotfiles-desktop-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
      pkgs.systemd
    ];
    text = ''
      state_root="''${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/desktop-switcher"
      selection_file="$state_root/selected"
      history_file="$state_root/launch-history"
      token_file="$state_root/current-launch"
      dispatcher_pid_file="$state_root/dispatcher-pid"
      switch_request_file="$state_root/switch-request"
      fallback_reason="$state_root/fallback-reason"
      mkdir -p "$state_root"
      rm -f "$switch_request_file"

      target=plasma
      if [[ -r "$selection_file" ]]; then
        target="$(<"$selection_file")"
      fi
      case "$target" in
        ${lib.concatStringsSep " | " desktopTargetOrder}) ;;
        *)
          printf 'Ignoring invalid desktop target %q; falling back to Plasma.\n' "$target" >&2
          target=plasma
          ;;
      esac

      now="$(date +%s)"
      recent_history="$(mktemp "$state_root/.launch-history.XXXXXX")"
      if [[ -r "$history_file" ]]; then
        awk -v cutoff="$((now - 120))" '$1 >= cutoff' "$history_file" >"$recent_history"
      fi
      mv -f "$recent_history" "$history_file"
      failures="$(awk -v target="$target" '$2 == target { count++ } END { print count + 0 }' "$history_file")"

      if ((failures >= 3)) && [[ "$target" != plasma ]]; then
        failed_target="$target"
        target=plasma
        printf '%s\n' "$target" >"$selection_file.tmp"
        mv -f "$selection_file.tmp" "$selection_file"
        printf '%s: %s failed three times within 120 seconds; selected Plasma.\n' \
          "$(date --iso-8601=seconds)" "$failed_target" >"$fallback_reason"
        : >"$history_file"
      fi

      token="$now-$$-$target"
      printf '%s\n' "$token" >"$token_file"
      printf '%s %s\n' "$now" "$target" >>"$history_file"
      export DOTFILES_DESKTOP_TARGET="$target"
      systemctl --user set-environment DOTFILES_DESKTOP_TARGET="$target"

      clear_stable_history() {
        sleep 90
        if [[ -r "$token_file" && "$(<"$token_file")" == "$token" ]]; then
          : >"$history_file"
          rm -f "$fallback_reason"
        fi
      }
      clear_stable_history &
      stability_pid=$!

      start_target() {
        case "$target" in
          ${desktopTargetCase}
        esac
      }
      start_target &
      desktop_pid=$!
      printf '%s\n' "$$" >"$dispatcher_pid_file.tmp"
      mv -f "$dispatcher_pid_file.tmp" "$dispatcher_pid_file"

      switch_requested=0

      # ShellCheck does not recognize invocation through the USR1 trap.
      # shellcheck disable=SC2329
      request_switch() {
        switch_requested=1
        kill -TERM "$desktop_pid" 2>/dev/null || true
      }

      recycle_user_manager() {
        manager_unit="user@$(id -u).service"
        manager_pid="$(systemctl show "$manager_unit" --property MainPID --value 2>/dev/null || true)"
        [[ "$manager_pid" =~ ^[0-9]+$ && "$manager_pid" != 0 ]] || manager_pid=""

        # SDDM relogs immediately, while this account intentionally lingers so
        # user services survive ordinary logouts. Stop the old manager before
        # returning to SDDM so the next desktop cannot inherit stale display,
        # compositor, DBus activation, or failed-unit state from the last one.
        systemctl --user exit >/dev/null 2>&1 || true

        for ((attempt = 0; attempt < 100; attempt++)); do
          manager_state="$(systemctl is-active "$manager_unit" 2>/dev/null || true)"
          [[ "$manager_state" == inactive || "$manager_state" == failed ]] && return
          sleep 0.05
        done

        # Electron applications can consume the full 90-second stop timeout.
        # A new SDDM session must not reuse a manager that is already shutting
        # down, so finish the old manager after a short graceful window.
        if [[ -n "$manager_pid" && -d "/proc/$manager_pid" ]]; then
          kill -KILL "$manager_pid" 2>/dev/null || true
        fi
        for ((attempt = 0; attempt < 200; attempt++)); do
          manager_state="$(systemctl is-active "$manager_unit" 2>/dev/null || true)"
          [[ "$manager_state" == inactive || "$manager_state" == failed ]] && return
          sleep 0.05
        done

        printf 'Timed out waiting for %s to stop; delaying SDDM relogin was unsuccessful.\n' \
          "$manager_unit" >&2
      }

      # ShellCheck does not recognize invocation through the EXIT trap.
      # shellcheck disable=SC2329
      cleanup() {
        kill "$stability_pid" "$desktop_pid" 2>/dev/null || true
        wait "$stability_pid" "$desktop_pid" 2>/dev/null || true
        if [[ -r "$dispatcher_pid_file" && "$(<"$dispatcher_pid_file")" == "$$" ]]; then
          rm -f "$dispatcher_pid_file"
        fi
        rm -f "$switch_request_file"
      }
      trap cleanup EXIT
      trap 'exit 143' HUP INT TERM
      trap request_switch USR1

      set +e
      wait "$desktop_pid"
      status=$?
      set -e
      recycle_user_manager
      if ((status != 0 && !switch_requested)); then
        printf 'Desktop %s exited with status %s; returning success so SDDM can apply recovery policy.\n' \
          "$target" "$status" >&2
      fi
      # SDDM only honors Relogin after a successful session helper exit. The
      # launch history above decides when rapid failures must fall back to
      # Plasma, so always return success after the desktop has ended.
      exit 0
    '';
  };

  desktopDispatcherSession = pkgs.writeTextFile {
    name = "dotfiles-desktop-wayland-session";
    destination = "/share/wayland-sessions/dotfiles-desktop.desktop";
    text = ''
      [Desktop Entry]
      Name=Dotfiles Desktop Switcher
      Comment=Launch the persistent desktop choice with automatic Plasma recovery
      Exec=${lib.getExe desktopSessionDispatcher}
      TryExec=${lib.getExe desktopSessionDispatcher}
      DesktopNames=dotfiles-desktop
      Type=Application
    '';
    derivationArgs.passthru.providedSessions = [ "dotfiles-desktop" ];
  };

  desktopSwitch = pkgs.writeShellApplication {
    name = "desktop-switch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.systemd
    ];
    text = ''
      state_root="''${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/desktop-switcher"
      selection_file="$state_root/selected"
      history_file="$state_root/launch-history"
      dispatcher_pid_file="$state_root/dispatcher-pid"
      switch_request_file="$state_root/switch-request"
      fallback_reason="$state_root/fallback-reason"

      usage() {
        cat <<'EOF'
      Usage:
        desktop-switch TARGET       switch immediately
        desktop-switch --next TARGET
                                    select TARGET without ending this session
        desktop-switch --restart    restart the selected desktop
        desktop-switch --status     show current and selected desktops
        desktop-switch --list       list targets

      Targets:
      ${desktopTargetHelp}

      Short aliases: niri, hyprland, mango

      Switching ends the current graphical login. Save application work first.
      Sunshine remains running; Moonlight may need one reconnect during handoff.
      EOF
      }

      canonicalize() {
        case "$1" in
          niri) printf '%s\n' niri-noctalia ;;
          hyprland) printf '%s\n' hyprland-noctalia ;;
          mango) printf '%s\n' mango-noctalia ;;
          ${lib.concatStringsSep " | " desktopTargetOrder}) printf '%s\n' "$1" ;;
          *) return 1 ;;
        esac
      }

      selected=plasma
      [[ ! -r "$selection_file" ]] || selected="$(<"$selection_file")"
      current="''${DOTFILES_DESKTOP_TARGET:-}"
      if [[ -z "$current" ]]; then
        current="$(systemctl --user show-environment \
          | sed -n 's/^DOTFILES_DESKTOP_TARGET=//p' \
          | head -n 1)"
      fi

      action="''${1:---list}"
      case "$action" in
        -h | --help | --list)
          usage
          exit 0
          ;;
        --status)
          printf 'Current:  %s\n' "''${current:-legacy session (not started by the switcher)}"
          printf 'Selected: %s\n' "$selected"
          if [[ -s "$fallback_reason" ]]; then
            printf 'Recovery: %s\n' "$(<"$fallback_reason")"
          fi
          exit 0
          ;;
        --next)
          [[ $# == 2 ]] || {
            usage >&2
            exit 64
          }
          target="$(canonicalize "$2")" || {
            printf 'Unknown desktop target: %s\n' "$2" >&2
            exit 64
          }
          immediate=0
          ;;
        --restart)
          target="$(canonicalize "''${current:-$selected}")" || target=plasma
          immediate=1
          ;;
        --*)
          printf 'Unknown option: %s\n' "$action" >&2
          exit 64
          ;;
        *)
          [[ $# == 1 ]] || {
            usage >&2
            exit 64
          }
          target="$(canonicalize "$action")" || {
            printf 'Unknown desktop target: %s\n' "$action" >&2
            exit 64
          }
          immediate=1
          ;;
      esac

      mkdir -p "$state_root"
      temporary="$(mktemp "$state_root/.selected.XXXXXX")"
      printf '%s\n' "$target" >"$temporary"
      mv -f "$temporary" "$selection_file"
      rm -f "$history_file" "$fallback_reason" "$state_root/current-launch"
      printf 'Selected desktop: %s\n' "$target"

      ((immediate)) || exit 0
      if [[ -z "$current" ]]; then
        printf '%s\n' \
          'The target is saved, but this graphical login predates the desktop dispatcher.' \
          'Reboot when convenient to arm fast switching; no session-ending action was taken.' >&2
        exit 2
      fi
      if [[ "$target" == "$current" && "$action" != --restart ]]; then
        printf '%s is already running. Use desktop-switch --restart to restart it.\n' "$target"
        exit 0
      fi

      dispatcher_pid=""
      if [[ -r "$dispatcher_pid_file" ]]; then
        dispatcher_pid="$(<"$dispatcher_pid_file")"
      fi
      if [[ ! "$dispatcher_pid" =~ ^[0-9]+$ ]] \
        || ! kill -0 "$dispatcher_pid" 2>/dev/null \
        || [[ ! -r "/proc/$dispatcher_pid/cmdline" ]] \
        || ! tr '\0' '\n' <"/proc/$dispatcher_pid/cmdline" | grep -q '/dotfiles-desktop-session'; then
        printf '%s\n' 'No live desktop dispatcher was found. The selection is saved for the next login.' >&2
        exit 1
      fi

      if [[ -r "$switch_request_file" ]]; then
        pending_pid=""
        pending_target=""
        read -r pending_pid pending_target <"$switch_request_file" || true
        if [[ "$pending_pid" == "$dispatcher_pid" ]] && kill -0 "$pending_pid" 2>/dev/null; then
          printf 'A handoff from this desktop is already in progress (requested target: %s).\n' \
            "''${pending_target:-unknown}"
          exit 0
        fi
      fi

      printf '%s %s\n' "$dispatcher_pid" "$target" >"$switch_request_file.tmp"
      mv -f "$switch_request_file.tmp" "$switch_request_file"
      printf 'Asking the desktop dispatcher to hand off cleanly to %s.\n' "$target"
      if ! kill -USR1 "$dispatcher_pid"; then
        rm -f "$switch_request_file"
        printf '%s\n' 'The dispatcher disappeared before it accepted the handoff; the selection remains saved.' >&2
        exit 1
      fi
    '';
  };
in
{
  options.dotfiles.compositors = {
    user = lib.mkOption {
      type = lib.types.strMatching "^[a-z_][a-z0-9_-]*$";
      default = "alex";
      description = "Local user whose graphical seat is managed by the desktop switcher.";
    };

    nvidiaVramWorkaround = lib.mkEnableOption ''
      niri's NVIDIA free-buffer-pool workaround
    '';
  };

  config = {
    programs = {
      hyprland = {
        enable = true;
        withUWSM = true;
        xwayland.enable = true;
      };

      niri = {
        enable = true;
        # Dolphin remains the desktop file manager; use the GTK portal instead
        # of pulling Nautilus into the workstation merely for file pickers.
        useNautilus = false;
      };

      mango = {
        enable = true;
        # The six explicitly named shell combinations below replace Mango's
        # generic upstream chooser entry.
        addLoginEntry = false;
      };

      dank-material-shell = {
        enable = true;
        systemd.enable = false;
      };

      noctalia = {
        enable = true;
        systemd.enable = false;
        recommendedServices.enable = true;
      };

      # This is an application-compatibility server inside Wayland sessions,
      # not a selectable X11 desktop session.
      xwayland.enable = true;
    };

    services.desktopManager.cosmic = {
      enable = true;
      xwayland.enable = true;
    };

    # The dispatcher remembers the selected target and is the one SDDM
    # session used for every automatic login. Relogin skips the greeter after
    # desktop-switch intentionally ends the current graphical session.
    services.displayManager.sddm.autoLogin.relogin = true;

    # Force the complete advertised list because ordinary module assignments
    # concatenate. That would re-add Plasma X11 and the generic compositor
    # entries supplied by their upstream modules.
    services.displayManager.sessionPackages = lib.mkForce (
      [
        desktopDispatcherSession
        plasmaWaylandSession
        pkgs.cosmic-session
      ]
      ++ experimentalSessions
    );

    # Niri discovers this on PATH and starts it on demand for Steam, Discord,
    # WezTerm, and other X11 applications.
    environment.systemPackages = [
      desktopSwitch
      pkgs.xwayland-satellite
    ];

    # NVIDIA recommends disabling its Wayland compositor free-buffer pool for
    # niri. Without this profile, an idle session can retain roughly 1 GiB of
    # otherwise-unused VRAM.
    environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json" =
      lib.mkIf cfg.nvidiaVramWorkaround {
        text = builtins.toJSON {
          rules = [
            {
              pattern = {
                feature = "procname";
                matches = "niri";
              };
              profile = "Limit Free Buffer Pool On Wayland Compositors";
            }
          ];
          profiles = [
            {
              name = "Limit Free Buffer Pool On Wayland Compositors";
              settings = [
                {
                  key = "GLVidHeapReuseRatio";
                  value = 0;
                }
              ];
            }
          ];
        };
      };
  };
}
