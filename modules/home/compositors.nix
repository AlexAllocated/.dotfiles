{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.compositors;
  enabled = pkgs.stdenv.hostPlatform.isLinux && cfg.enable;
  sourceRoot =
    if config.dotfiles.mutableSource != null then
      config.dotfiles.mutableSource
    else
      config.dotfiles.source;
  toLua = lib.generators.toLua { };

  noctaliaPackage = config.programs.noctalia.package;
  dmsPackage = config.programs.dank-material-shell.package;
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  wallpaper = config.dotfiles.wallpaper;

  renderHyprlandOutput =
    name: output:
    let
      value =
        if output.enable then
          {
            output = name;
            mode = if output.mode == null then "preferred" else output.mode;
            position =
              if output.position == null then
                "auto"
              else
                "${toString output.position.x}x${toString output.position.y}";
            scale = output.scale;
          }
        else
          {
            output = name;
            disabled = true;
          };
    in
    "hl.monitor(${toLua value})";

  renderNiriOutput =
    name: output:
    let
      body =
        if !output.enable then
          "  off"
        else
          lib.concatStringsSep "\n" (
            lib.optional (output.mode != null) "  mode ${builtins.toJSON output.mode}"
            ++ [ "  scale ${toString output.scale}" ]
            ++ lib.optional output.focusAtStartup "  focus-at-startup"
            ++ lib.optional (output.position != null) (
              "  position x=${toString output.position.x} y=${toString output.position.y}"
            )
          );
    in
    ''
      output ${builtins.toJSON name} {
      ${body}
      }
    '';

  renderMangoOutput =
    name: output:
    let
      exactName = "^${lib.escapeRegex name}$";
      modeParts = if output.mode == null then [ ] else lib.splitString "@" output.mode;
      resolutionParts =
        if output.mode == null then [ ] else lib.splitString "x" (builtins.head modeParts);
      modeArguments =
        lib.optionals (output.mode != null) [
          "width:${builtins.elemAt resolutionParts 0}"
          "height:${builtins.elemAt resolutionParts 1}"
        ]
        ++ lib.optional (builtins.length modeParts > 1) "refresh:${builtins.elemAt modeParts 1}";
      positionArguments = lib.optionals (output.position != null) [
        "x:${toString output.position.x}"
        "y:${toString output.position.y}"
      ];
      arguments = [
        "name:${exactName}"
      ]
      ++ (
        if output.enable then
          modeArguments
          ++ positionArguments
          ++ [
            "scale:${toString output.scale}"
            "vrr:0"
            "rr:0"
          ]
        else
          [ "disable:1" ]
      );
    in
    "monitorrule=${lib.concatStringsSep "," arguments}";

  hyprlandOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderHyprlandOutput cfg.outputs);
  niriOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderNiriOutput cfg.outputs);
  mangoOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderMangoOutput cfg.outputs);

  desktopShellProcess = pkgs.writeShellApplication {
    name = "dotfiles-desktop-shell-process";
    runtimeInputs = [
      dmsPackage
      noctaliaPackage
    ];
    text = ''
      case "''${DOTFILES_DESKTOP_SHELL:-noctalia}" in
        noctalia)
          exec noctalia
          ;;
        dms)
          exec dms run --session
          ;;
        *)
          printf 'Unknown desktop shell: %s\n' "$DOTFILES_DESKTOP_SHELL" >&2
          exit 64
          ;;
      esac
    '';
  };

  resolveDesktopShell = ''
    selected_shell="''${DOTFILES_DESKTOP_SHELL:-}"
    if [[ -z "$selected_shell" ]]; then
      selected_shell="$(${systemctl} --user show-environment \
        | ${lib.getExe pkgs.gnused} -n 's/^DOTFILES_DESKTOP_SHELL=//p' \
        | ${lib.getExe' pkgs.coreutils "head"} -n 1)"
    fi
    selected_shell="''${selected_shell:-noctalia}"
  '';

  shellAction = pkgs.writeShellApplication {
    name = "dotfiles-shell-action";
    runtimeInputs = [
      dmsPackage
      noctaliaPackage
      pkgs.systemd
    ];
    text = ''
      ${resolveDesktopShell}
      action="''${1:-}"

      case "$selected_shell:$action" in
        noctalia:launcher) exec noctalia msg panel-toggle launcher ;;
        noctalia:control-center) exec noctalia msg panel-toggle control-center ;;
        noctalia:notifications) exec noctalia msg panel-toggle control-center notifications ;;
        noctalia:settings) exec noctalia msg settings-toggle ;;
        noctalia:session-menu) exec noctalia msg panel-toggle session ;;
        noctalia:volume-up) exec noctalia msg volume-up 3 ;;
        noctalia:volume-down) exec noctalia msg volume-down 3 ;;
        noctalia:volume-mute) exec noctalia msg volume-mute ;;
        noctalia:mic-mute) exec noctalia msg mic-mute ;;

        dms:launcher) exec dms ipc call spotlight toggle ;;
        dms:control-center) exec dms ipc call control-center toggle ;;
        dms:notifications) exec dms ipc call notifications toggle ;;
        dms:settings) exec dms ipc call settings toggle ;;
        dms:session-menu) exec dms ipc call powermenu toggle ;;
        dms:volume-up) exec dms ipc call audio increment 3 ;;
        dms:volume-down) exec dms ipc call audio decrement 3 ;;
        dms:volume-mute) exec dms ipc call audio mute ;;
        dms:mic-mute) exec dms ipc call audio micmute ;;

        *)
          printf 'Unsupported desktop-shell action: %s (%s)\n' "$action" "$selected_shell" >&2
          exit 64
          ;;
      esac
    '';
  };

  startDesktopShell = pkgs.writeShellApplication {
    name = "dotfiles-start-desktop-shell";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      # The SDDM wrapper can select the shell before the compositor starts,
      # but WAYLAND_DISPLAY only exists now. Import the completed environment
      # before starting the service so it always targets this session's socket.
      variables=()
      for variable in \
        WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE \
        XDG_SESSION_DESKTOP DOTFILES_DESKTOP_SHELL \
        HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET MANGO_INSTANCE_SIGNATURE; do
        if [[ -n "''${!variable+x}" ]]; then
          variables+=("$variable")
        fi
      done
      if (( ''${#variables[@]} )); then
        systemctl --user import-environment "''${variables[@]}"
      fi
      systemctl --user restart dotfiles-desktop-shell.service
    '';
  };

  startPolkitAgent = pkgs.writeShellApplication {
    name = "dotfiles-start-compositor-polkit";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      ${resolveDesktopShell}
      if [[ "$selected_shell" == noctalia ]]; then
        systemctl --user start dotfiles-compositor-polkit.service
      else
        # DMS provides its own authentication agent.
        systemctl --user stop dotfiles-compositor-polkit.service \
          >/dev/null 2>&1 || true
      fi
    '';
  };

  mangoCycleLayout = pkgs.writeShellApplication {
    name = "dotfiles-mango-cycle-layout";
    runtimeInputs = with pkgs; [
      glib
      jq
      util-linux
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      lock_file="$runtime_dir/dotfiles-mango-layout.lock"
      notification_id_file="$runtime_dir/dotfiles-mango-layout-notification-id"

      # Serialize key repeats so the displayed name always matches the final
      # layout selected by Mango.
      exec 9>"$lock_file"
      flock 9

      mmsg dispatch switch_layout
      layout_index="$(
        mmsg get all-monitors \
          | jq -r '[.monitors[] | select(.active)][0].layout_index // empty'
      )"

      case "$layout_index" in
        0) layout_name="Tile" ;;
        1) layout_name="Scroller" ;;
        2) layout_name="Grid" ;;
        3) layout_name="Monocle" ;;
        4) layout_name="Deck" ;;
        5) layout_name="Center Tile" ;;
        6) layout_name="Right Tile" ;;
        7) layout_name="Vertical Scroller" ;;
        8) layout_name="Vertical Tile" ;;
        9) layout_name="Vertical Grid" ;;
        10) layout_name="Vertical Deck" ;;
        11) layout_name="Dwindle" ;;
        12) layout_name="Fair" ;;
        13) layout_name="Vertical Fair" ;;
        *) layout_name="Unknown" ;;
      esac

      notification_id=0
      if [[ -r "$notification_id_file" ]]; then
        read -r notification_id < "$notification_id_file"
        if [[ ! "$notification_id" =~ ^[0-9]+$ ]]; then
          notification_id=0
        fi
      fi

      notification_result="$(
        gdbus call --session \
          --dest org.freedesktop.Notifications \
          --object-path /org/freedesktop/Notifications \
          --method org.freedesktop.Notifications.Notify \
          Mango "$notification_id" preferences-system-windows \
          Layout "$layout_name" '[]' "{'transient': <true>}" 1200
      )"
      if [[ "$notification_result" =~ uint32[[:space:]]+([0-9]+) ]]; then
        printf '%s\n' "''${BASH_REMATCH[1]}" > "$notification_id_file"
      fi
    '';
  };

  stopHyprlandSession = "${lib.getExe pkgs.uwsm} stop";

  mangoStarterConfig =
    lib.replaceStrings
      [
        "bind=Alt,space,spawn,rofi -show drun"
        "bind=Alt,Return,spawn,foot"
        "bind=SUPER,n,switch_layout"
      ]
      [
        "bind=Alt,space,spawn,dotfiles-shell-action launcher"
        "bind=Alt,Return,spawn,alacritty"
        "bind=SUPER,n,spawn,${lib.getExe mangoCycleLayout}"
      ]
      (builtins.readFile "${inputs.mango}/assets/config.conf");

  mangoConfig = ''
    ${mangoStarterConfig}

    # Machine output policy generated from dotfiles.compositors.outputs.
    ${mangoOutputs}

    # Familiar aliases layered over Mango's complete upstream starter config.
    bind=SUPER,Return,spawn,alacritty
    bind=SUPER,space,spawn,dotfiles-shell-action launcher
    bind=SUPER,a,spawn,dotfiles-shell-action control-center
    bind=SUPER,comma,spawn,dotfiles-shell-action settings
    bind=SUPER+SHIFT,e,spawn,dotfiles-shell-action session-menu
    bind=SUPER,e,spawn,dolphin
    bind=SUPER,b,spawn,firefox
    bind=SUPER,q,killclient,
    bind=SUPER,v,togglefloating,
    bind=SUPER,f,togglefullscreen,
    bind=CTRL+ALT,Delete,quit

    bind=SUPER,h,focusdir,left
    bind=SUPER,j,focusdir,down
    bind=SUPER,k,focusdir,up
    bind=SUPER,l,focusdir,right
    bind=SUPER+SHIFT,h,exchange_client,left
    bind=SUPER+SHIFT,j,exchange_client,down
    bind=SUPER+SHIFT,k,exchange_client,up
    bind=SUPER+SHIFT,l,exchange_client,right

    bind=SUPER,1,view,1,0
    bind=SUPER,2,view,2,0
    bind=SUPER,3,view,3,0
    bind=SUPER,4,view,4,0
    bind=SUPER,5,view,5,0
    bind=SUPER,6,view,6,0
    bind=SUPER,7,view,7,0
    bind=SUPER,8,view,8,0
    bind=SUPER,9,view,9,0
    bind=SUPER+SHIFT,1,tag,1,0
    bind=SUPER+SHIFT,2,tag,2,0
    bind=SUPER+SHIFT,3,tag,3,0
    bind=SUPER+SHIFT,4,tag,4,0
    bind=SUPER+SHIFT,5,tag,5,0
    bind=SUPER+SHIFT,6,tag,6,0
    bind=SUPER+SHIFT,7,tag,7,0
    bind=SUPER+SHIFT,8,tag,8,0
    bind=SUPER+SHIFT,9,tag,9,0

    bind=NONE,XF86AudioRaiseVolume,spawn,dotfiles-shell-action volume-up
    bind=NONE,XF86AudioLowerVolume,spawn,dotfiles-shell-action volume-down
    bind=NONE,XF86AudioMute,spawn,dotfiles-shell-action volume-mute
    bind=NONE,XF86AudioMicMute,spawn,dotfiles-shell-action mic-mute
    bind=NONE,XF86AudioPlay,spawn,playerctl play-pause
    bind=NONE,XF86AudioPause,spawn,playerctl play-pause
    bind=NONE,XF86AudioPrev,spawn,playerctl previous
    bind=NONE,XF86AudioNext,spawn,playerctl next

    # Gruvbox Dark accents.
    rootcolor=0x1d2021ff
    bordercolor=0x504945ff
    focuscolor=0xd79921ff
    urgentcolor=0xcc241dff
    scratchpadcolor=0x458588ff
    globalcolor=0xb16286ff
    overlaycolor=0x689d6aff
    border_radius=10
  '';
in
{
  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.mango.hmModules.mango
    inputs.noctalia.homeModules.default
    ./core.nix
    ./wallpaper.nix
  ];

  options.dotfiles.compositors = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.profile == "nixos-desktop";
      description = "Configure optional Wayland compositor and desktop-shell experiments.";
    };

    outputs = lib.mkOption {
      default = { };
      description = "Portable output policy rendered into each compositor configuration.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this output should be enabled at session start.";
            };
            mode = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "3440x1440@160";
              description = "Compositor mode; null selects the output's preferred mode.";
            };
            scale = lib.mkOption {
              type = lib.types.number;
              default = 1;
              description = "Logical scale for the output.";
            };
            position = lib.mkOption {
              default = null;
              description = "Optional logical output position; null lets the compositor place it.";
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    x = lib.mkOption { type = lib.types.int; };
                    y = lib.mkOption { type = lib.types.int; };
                  };
                }
              );
            };
            focusAtStartup = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether niri should focus this output when the session starts.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf enabled {
    home.packages = with pkgs; [
      fuzzel
      hyprpolkitagent
      hyprshot
      playerctl
      mangoCycleLayout
      shellAction
      startDesktopShell
      startPolkitAgent
      swaylock
    ];

    programs.noctalia = {
      enable = true;
      systemd.enable = false;
      settings = {
        shell = {
          telemetry_enabled = false;
          # Noctalia sessions use the small compositor-specific service below;
          # DMS provides its own agent.
          polkit_agent = false;
          session.actions = [
            { action = "lock"; }
            { action = "logout"; }
            { action = "reboot"; }
            {
              action = "shutdown";
              variant = "destructive";
            }
          ];
        };
        theme = {
          mode = "dark";
          source = "builtin";
          builtin = "Gruvbox";
        };
        idle.behavior = {
          lock = {
            timeout = 600;
            action = "lock";
            enabled = false;
          };
          "screen-off" = {
            timeout = 660;
            action = "screen_off";
            enabled = false;
          };
        };
        wallpaper = {
          enabled = true;
          fill_mode = "crop";
          automation.enabled = false;
          monitors = {
            "${wallpaper.connector}".path = wallpaper.installedPath;
          };
        };
      };
    };

    programs.dank-material-shell = {
      enable = true;
      systemd.enable = false;
    };

    # Keep DMS's GUI settings mutable while enforcing the workstation's power
    # policy and seeding only the LG's wallpaper on every activation.
    home.activation.dmsNeverSleep = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings_dir=${lib.escapeShellArg "${config.xdg.configHome}/DankMaterialShell"}
      settings_file="$settings_dir/settings.json"
      run ${lib.getExe' pkgs.coreutils "mkdir"} -p "$settings_dir"

      if [[ -s "$settings_file" ]] \
        && ${lib.getExe pkgs.jq} -e 'type == "object"' "$settings_file" >/dev/null 2>&1; then
        settings_input="$settings_file"
      else
        settings_input=${pkgs.writeText "dms-empty-settings.json" "{}"}
      fi

      settings_tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} "$settings_dir/.settings.json.XXXXXX")"
      trap '${lib.getExe' pkgs.coreutils "rm"} -f -- "$settings_tmp"' EXIT
      ${lib.getExe pkgs.jq} '
        .powerMenuActions = ["reboot", "logout", "poweroff", "lock", "restart"]
        | .acMonitorTimeout = 0
        | .acLockTimeout = 0
        | .acSuspendTimeout = 0
        | .batteryMonitorTimeout = 0
        | .batteryLockTimeout = 0
        | .batterySuspendTimeout = 0
      ' "$settings_input" > "$settings_tmp"
      run ${lib.getExe' pkgs.coreutils "chmod"} 0600 "$settings_tmp"
      run ${lib.getExe' pkgs.coreutils "mv"} -T "$settings_tmp" "$settings_file"
      trap - EXIT

      session_dir=${lib.escapeShellArg "${config.xdg.stateHome}/DankMaterialShell"}
      session_file="$session_dir/session.json"
      run ${lib.getExe' pkgs.coreutils "mkdir"} -p "$session_dir"

      if [[ -s "$session_file" ]] \
        && ${lib.getExe pkgs.jq} -e 'type == "object"' "$session_file" >/dev/null 2>&1; then
        session_input="$session_file"
      else
        session_input=${pkgs.writeText "dms-empty-session.json" "{}"}
      fi

      session_tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} "$session_dir/.session.json.XXXXXX")"
      trap '${lib.getExe' pkgs.coreutils "rm"} -f -- "$session_tmp"' EXIT
      ${lib.getExe pkgs.jq} \
        --arg connector ${lib.escapeShellArg wallpaper.connector} \
        --arg wallpaper ${lib.escapeShellArg wallpaper.installedPath} '
          .configVersion = (.configVersion // 3)
          | .wallpaperPath = (.wallpaperPath // "")
          | .perMonitorWallpaper = true
          | .monitorWallpapers = ((.monitorWallpapers // {}) + {($connector): $wallpaper})
          | .monitorWallpaperFillModes =
              ((.monitorWallpaperFillModes // {}) + {($connector): "Fill"})
        ' "$session_input" > "$session_tmp"
      run ${lib.getExe' pkgs.coreutils "chmod"} 0600 "$session_tmp"
      run ${lib.getExe' pkgs.coreutils "mv"} -T "$session_tmp" "$session_file"
      trap - EXIT
    '';

    # UWSM owns the Hyprland systemd session. Home Manager owns only the
    # generated configuration, avoiding two competing graphical targets.
    wayland.windowManager.hyprland = {
      enable = true;
      package = null;
      portalPackage = null;
      configType = "lua";
      systemd.enable = false;
      extraConfig = ''
        ${hyprlandOutputs}

        local start_desktop_shell = ${toLua (lib.getExe startDesktopShell)}
        local start_polkit_agent = ${toLua (lib.getExe startPolkitAgent)}
        local shell_action = ${toLua (lib.getExe shellAction)}
        local stop_hyprland_session = ${toLua stopHyprlandSession}

        ${builtins.readFile (sourceRoot + "/wayland/hyprland.lua")}
      '';
    };

    xdg.configFile."niri/config.kdl".text = ''
      // Output policy is generated from dotfiles.compositors.outputs.
      ${niriOutputs}

      spawn-at-startup ${builtins.toJSON (lib.getExe startDesktopShell)}
      spawn-at-startup ${builtins.toJSON (lib.getExe startPolkitAgent)}

      ${builtins.readFile (sourceRoot + "/wayland/niri.kdl")}
    '';

    wayland.windowManager.mango = {
      enable = true;
      systemd = {
        enable = true;
        # Assigning this option replaces the module default, so repeat the
        # complete upstream list before adding our session selector.
        variables = [
          "DISPLAY"
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
          "XDG_SESSION_TYPE"
          "XDG_SESSION_DESKTOP"
          "NIXOS_OZONE_WL"
          "XCURSOR_THEME"
          "XCURSOR_SIZE"
          "MANGO_INSTANCE_SIGNATURE"
          "DOTFILES_DESKTOP_SHELL"
        ];
      };
      extraConfig = mangoConfig;
      autostart_sh = ''
        ${lib.getExe startDesktopShell}
        ${lib.getExe startPolkitAgent}
      '';
    };

    home.sessionVariables.NOCTALIA_PAM_SERVICE = "login";

    systemd.user.services.dotfiles-desktop-shell = {
      Unit = {
        Description = "Selected shell for experimental Wayland sessions";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session-pre.target" ];
      };
      Service = {
        ExecStart = lib.getExe desktopShellProcess;
        Restart = "on-failure";
        RestartSec = 1;
        Slice = "session.slice";
      };
    };

    systemd.user.services.dotfiles-compositor-polkit = {
      Unit = {
        Description = "Polkit agent for experimental compositor sessions";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
        Restart = "on-failure";
        RestartSec = 1;
        Slice = "session.slice";
      };
    };

    assertions = lib.mapAttrsToList (name: output: {
      assertion =
        builtins.match "^[A-Za-z0-9._-]+$" name != null
        && (output.mode == null || builtins.match "^[0-9]+x[0-9]+(@[0-9.]+)?$" output.mode != null);
      message = "dotfiles.compositors.outputs.${name} has an unsafe connector name or mode";
    }) cfg.outputs;
  };
}
