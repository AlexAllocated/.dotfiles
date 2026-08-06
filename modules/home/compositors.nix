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
  noctaliaPackage = config.programs.noctalia.package;
  dmsPackage = pkgs.dms-shell;
  noctaliaFocusPatch = pkgs.writeText "noctalia-focus-existing-windows.patch" (
    builtins.readFile ../../patches/noctalia-focus-existing-windows.patch
  );
  noctaliaWeztermNotificationsPatch = pkgs.writeText "noctalia-wezterm-notifications.patch" (
    builtins.readFile ../../patches/noctalia-wezterm-notifications.patch
  );
  noctaliaNixosNvmlPatch = pkgs.writeText "noctalia-nixos-nvml.patch" (
    builtins.readFile ../../patches/noctalia-nixos-nvml.patch
  );
  noctaliaHiddenAudioNodesPatch = pkgs.writeText "noctalia-hidden-audio-nodes.patch" (
    builtins.readFile ../../patches/noctalia-hidden-audio-nodes.patch
  );
  mullvadWidgetScript = pkgs.replaceVars ../../noctalia/plugins/mullvad/toggle.luau {
    mullvad = lib.getExe' pkgs.mullvad-vpn "mullvad";
    mullvadGui = lib.getExe' pkgs.mullvad-vpn "mullvad-vpn";
    sleep = lib.getExe' pkgs.coreutils "sleep";
  };
  noctaliaLocalPlugins = pkgs.runCommand "noctalia-local-plugins" { } ''
    mkdir -p "$out/mullvad"
    cp ${../../noctalia/plugins/mullvad/plugin.toml} "$out/mullvad/plugin.toml"
    cp ${mullvadWidgetScript} "$out/mullvad/toggle.luau"
  '';
  mangoPackage = import ../../lib/mango-package.nix { inherit inputs pkgs; };
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  wallpaper = config.dotfiles.wallpaper;
  wallpaperPaths = {
    ${wallpaper.connector} = wallpaper.installedPath;
  }
  // lib.optionalAttrs (wallpaper.ipad.connector != null) {
    ${wallpaper.ipad.connector} = wallpaper.ipad.installedPath;
  };
  noctaliaWallpaperMonitors = lib.mapAttrs (_: path: { inherit path; }) wallpaperPaths;
  renderNiriOutput =
    name: output:
    let
      layoutOverrides = lib.optional (output.niriGaps != null) "gaps ${toString output.niriGaps};";
      body = lib.concatStringsSep "\n" (
        (
          if !output.enable then
            [ "  off" ]
          else
            (
              lib.optional (output.mode != null) "  mode ${builtins.toJSON output.mode}"
              ++ [ "  scale ${toString output.scale}" ]
              ++ lib.optional output.focusAtStartup "  focus-at-startup"
              ++ lib.optional output.variableRefreshRate "  variable-refresh-rate"
              ++ lib.optional (output.position != null) (
                "  position x=${toString output.position.x} y=${toString output.position.y}"
              )
            )
        )
        ++ lib.optional (layoutOverrides != [ ]) (
          "  layout {\n${lib.concatMapStringsSep "\n" (line: "    ${line}") layoutOverrides}\n  }"
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

  niriOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderNiriOutput cfg.outputs);
  mangoOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderMangoOutput cfg.outputs);
  niriSharedConfig = builtins.readFile (sourceRoot + "/wayland/niri.kdl");
  niriConfigWithAltAliases = lib.concatMapStringsSep "\n" (
    line:
    let
      modBinding = builtins.match "([[:space:]]*)Mod\\+(.*)" line;
    in
    if modBinding == null then
      line
    else
      "${line}\n${builtins.elemAt modBinding 0}Alt+${builtins.elemAt modBinding 1}"
  ) (lib.splitString "\n" niriSharedConfig);

  desktopShellProcess = pkgs.writeShellApplication {
    name = "dotfiles-desktop-shell-process";
    runtimeInputs = [
      dmsPackage
      noctaliaPackage
      pkgs.procps
    ];
    text = ''
      case "''${DOTFILES_DESKTOP_SHELL:-noctalia}" in
        dms) exec dms run --session ;;
        noctalia)
          # KDE applications may DBus-activate kded6, which can seize the
          # StatusNotifierWatcher name while Noctalia is restarting and leave
          # the restored shell with an empty tray.
          pkill -x kded6 >/dev/null 2>&1 || true
          exec noctalia
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
        dms:settings) exec dms ipc call settings focusOrToggle ;;
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
        NIRI_SOCKET MANGO_INSTANCE_SIGNATURE; do
        if [[ -n "''${!variable+x}" ]]; then
          variables+=("$variable")
        fi
      done
      if (( ''${#variables[@]} )); then
        systemctl --user import-environment "''${variables[@]}"
      fi
      systemctl --user restart dotfiles-desktop-shell.service
      if [[ "''${XDG_CURRENT_DESKTOP:-}" == niri ]]; then
        systemctl --user restart dotfiles-niri-output-follow.service
      else
        systemctl --user stop dotfiles-niri-output-follow.service >/dev/null 2>&1 || true
      fi
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
        # DMS includes its own authentication agent.
        systemctl --user stop dotfiles-compositor-polkit.service >/dev/null 2>&1 || true
      fi
    '';
  };

  niriFollowPrimaryOutput = pkgs.writeShellApplication {
    name = "dotfiles-niri-follow-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.niri
      noctaliaPackage
    ];
    text = ''
      primary_selector=${lib.escapeShellArg wallpaper.outputMatch}
      fallback_selector=${
        lib.escapeShellArg (if wallpaper.ipad.outputMatch == null then "" else wallpaper.ipad.outputMatch)
      }
      primary_wallpaper=${lib.escapeShellArg wallpaper.installedPath}
      fallback_wallpaper=${lib.escapeShellArg wallpaper.ipad.installedPath}
      state_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset}/dotfiles-niri-output-follow"
      anchors_file="$state_dir/primary-workspace-anchors.json"
      last_state=unknown
      assigned_primary=""
      assigned_fallback=""
      mkdir -p -- "$state_dir"

      [[ -n "$fallback_selector" ]] || {
        printf '%s\n' 'No iPad fallback connector is configured; output following is disabled.' >&2
        exit 0
      }

      resolve_output() {
        local selector="$1" outputs="$2"
        jq -r --arg selector "$selector" '
          if .[$selector] != null then
            $selector
          else
            first(
              to_entries[]
              | select(
                  ([.value.make, .value.model, (.value.serial // "Unknown")] | join(" "))
                  == $selector
                )
              | .key
            ) // empty
          end
        ' <<<"$outputs"
      }

      focused_window_id() {
        niri msg --json focused-window 2>/dev/null | jq -r '.id // empty'
      }

      workspace_anchors() {
        local output="$1"
        local workspaces="$2"
        jq -c --arg output "$output" \
          '[.[] | select(.output == $output and .active_window_id != null) | .active_window_id]' \
          <<<"$workspaces"
      }

      normalize_anchored_workspace_columns() {
        local anchors="$1"
        local windows restore_focus anchor workspace_id window_id
        windows="$(niri msg --json windows 2>/dev/null)" || return 1
        restore_focus="$(focused_window_id || true)"

        while IFS= read -r anchor; do
          [[ "$anchor" =~ ^[0-9]+$ ]] || continue
          workspace_id="$(jq -r --argjson anchor "$anchor" \
            'first(.[] | select(.id == $anchor)).workspace_id // empty' <<<"$windows")"
          [[ "$workspace_id" =~ ^[0-9]+$ ]] || continue
          while IFS= read -r window_id; do
            [[ "$window_id" =~ ^[0-9]+$ ]] || continue
            niri msg action focus-window --id "$window_id" >/dev/null 2>&1 || continue
            # A zero proportional adjustment preserves the current visual width
            # while converting pixel-fixed columns to Niri's proportional sizing.
            niri msg action set-column-width '+0%' >/dev/null 2>&1 || true
          done < <(
            jq -r --argjson workspace_id "$workspace_id" '
              [
                .[]
                | select(.workspace_id == $workspace_id)
                | select(.is_floating == false and .layout.pos_in_scrolling_layout != null)
              ]
              | sort_by(.layout.pos_in_scrolling_layout[0])
              | unique_by(.layout.pos_in_scrolling_layout[0])
              | .[].id
            ' <<<"$windows"
          )
        done < <(jq -r '.[]' <<<"$anchors")

        if [[ "$restore_focus" =~ ^[0-9]+$ ]]; then
          niri msg action focus-window --id "$restore_focus" >/dev/null 2>&1 || true
        fi
      }

      move_anchored_workspaces() {
        local target="$1"
        local anchors="$2"
        local restore_focus anchor
        restore_focus="$(focused_window_id || true)"
        normalize_anchored_workspace_columns "$anchors" || true

        while IFS= read -r anchor; do
          [[ "$anchor" =~ ^[0-9]+$ ]] || continue
          niri msg action focus-window --id "$anchor" >/dev/null 2>&1 || continue
          niri msg action move-workspace-to-monitor "$target" >/dev/null 2>&1 || true
        done < <(jq -r '.[]' <<<"$anchors")

        if [[ "$restore_focus" =~ ^[0-9]+$ ]]; then
          niri msg action focus-window --id "$restore_focus" >/dev/null 2>&1 || true
        fi
      }

      while true; do
        outputs="$(niri msg --json outputs 2>/dev/null)" || {
          sleep 1
          continue
        }
        workspaces="$(niri msg --json workspaces 2>/dev/null)" || {
          sleep 1
          continue
        }

        primary="$(resolve_output "$primary_selector" "$outputs")"
        fallback="$(resolve_output "$fallback_selector" "$outputs")"

        if [[ -n "$primary" && "$assigned_primary" != "$primary" ]] \
          && noctalia msg wallpaper-set "$primary" "$primary_wallpaper" >/dev/null 2>&1; then
          assigned_primary="$primary"
        fi
        if [[ -n "$fallback" && "$assigned_fallback" != "$fallback" ]] \
          && noctalia msg wallpaper-set "$fallback" "$fallback_wallpaper" >/dev/null 2>&1; then
          assigned_fallback="$fallback"
        fi

        if [[ -n "$primary" ]] && jq -e --arg primary "$primary" \
          '.[$primary].current_mode != null and .[$primary].logical != null' \
          <<<"$outputs" >/dev/null; then
          current_state=on
        else
          current_state=off
        fi

        if [[ "$last_state" == off && "$current_state" == on ]]; then
          if [[ -s "$anchors_file" ]] && jq -e 'type == "array"' "$anchors_file" >/dev/null 2>&1; then
            anchors="$(<"$anchors_file")"
            move_anchored_workspaces "$primary" "$anchors"
          fi
        elif [[ "$last_state" == on && "$current_state" == off ]]; then
          # Niri normally evacuates workspaces itself when an output vanishes.
          # Repeating the move through one stable window ID per workspace also
          # covers monitors that remain logically present for part of their
          # physical power-down sequence.
          if [[ -n "$fallback" && -s "$anchors_file" ]]; then
            move_anchored_workspaces "$fallback" "$(<"$anchors_file")"
          fi
        fi

        if [[ "$current_state" == on ]]; then
          anchors="$(workspace_anchors "$primary" "$workspaces")"
          printf '%s\n' "$anchors" > "$anchors_file"
          chmod 0600 "$anchors_file"
        elif [[ "$last_state" == unknown && ! -s "$anchors_file" ]]; then
          # A headless boot has no prior ownership map. Treat the workspaces
          # initially created on the dummy as primary work so they return to
          # the LG if it is powered on later.
          anchors="$(workspace_anchors "$fallback" "$workspaces")"
          printf '%s\n' "$anchors" > "$anchors_file"
          chmod 0600 "$anchors_file"
        fi

        last_state="$current_state"
        sleep 1
      done
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

  mangoStarterConfig =
    lib.replaceStrings
      [
        "bind=Alt,space,spawn,rofi -show drun"
        "bind=Alt,Return,spawn,foot"
        "bind=SUPER,n,switch_layout"
        "bind=SUPER,m,quit"
      ]
      [
        "bind=Alt,space,spawn,dotfiles-shell-action launcher"
        "bind=Alt,Return,spawn,wezterm start"
        "bind=SUPER,n,spawn,${lib.getExe mangoCycleLayout}"
        "bind=SUPER,m,minimized,"
      ]
      (builtins.readFile "${inputs.mango}/assets/config.conf");

  mangoConfig = ''
    ${mangoStarterConfig}

    # Machine output policy generated from dotfiles.compositors.outputs.
    ${mangoOutputs}

    # Work around mangowm/mango#647. WezTerm can reject Mango's first tiled
    # configure on fractionally scaled Wayland outputs, leaving its buffer at
    # the initial 80x24 size inside a correctly sized tile. Advertising a
    # fake-maximized state makes WezTerm honor the compositor's dimensions
    # without changing Mango's layout.
    windowrule=force_fakemaximize:1,appid:org.wezfurlong.wezterm

    # Familiar aliases layered over Mango's complete upstream starter config.
    bind=SUPER,Return,spawn,wezterm start
    bind=SUPER,space,spawn,dotfiles-shell-action launcher
    bind=SUPER,a,spawn,dotfiles-shell-action control-center
    bind=SUPER,comma,spawn,dotfiles-shell-action settings
    bind=SUPER+SHIFT,e,spawn,dotfiles-shell-action session-menu
    bind=SUPER,e,spawn,nautilus --new-window
    bind=SUPER,b,spawn,google-chrome
    bind=SUPER,q,killclient,
    bind=SUPER,v,togglefloating,
    bind=SUPER,f,togglefullscreen,
    bind=CTRL+ALT,Delete,spawn,desktop-switch --restart

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
            variableRefreshRate = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether Niri should keep variable refresh rate enabled on this output.";
            };
            niriGaps = lib.mkOption {
              type = lib.types.nullOr lib.types.number;
              default = null;
              description = "Optional Niri gaps override in logical pixels for this output.";
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
      playerctl
      mangoCycleLayout
      shellAction
      startDesktopShell
      startPolkitAgent
      swaylock
    ];

    programs.noctalia = {
      enable = true;
      package =
        inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs
          (oldAttrs: {
            patches = (oldAttrs.patches or [ ]) ++ [
              noctaliaFocusPatch
              noctaliaHiddenAudioNodesPatch
              noctaliaNixosNvmlPatch
              noctaliaWeztermNotificationsPatch
            ];
          });
      systemd.enable = false;
      settings = {
        system.monitor.gpu_poll_seconds = 2.0;
        shell = {
          telemetry_enabled = false;
          # Noctalia sessions use the small compositor-specific service below.
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
        bar.default = {
          start = [
            "launcher"
            "wallpaper"
            "workspaces"
            "cpu_temperature"
            "gpu_temperature"
          ];
          center = [
            "clock"
            "weather"
          ];
          end = [
            "tray"
            "notifications"
            "clipboard"
            "alex/mullvad:toggle"
            "network"
            "bluetooth"
            "volume"
            "brightness"
            "battery"
            "control-center"
            "session"
          ];
        };
        widget = {
          network = {
            type = "network";
            show_label = false;
          };
          volume = {
            type = "volume";
            show_label = false;
          };
          tray = {
            type = "tray";
            drawer = true;
            drawer_columns = 3;
            pinned = [
              "chrome_status_icon_1"
              "flameshot"
              "lan-mouse-edge-toggle"
              "razer-profile-selector"
            ];
          };
          cpu_temperature = {
            type = "sysmon";
            stat = "cpu_temp";
            display = "text";
            glyph = "cpu-temperature";
          };
          gpu_temperature = {
            type = "sysmon";
            stat = "gpu_temp";
            display = "text";
            glyph = "gpu-usage";
          };
          weather = {
            type = "weather";
            show_condition = false;
            show_temperature = true;
          };
        };
        plugins = {
          source = [
            {
              name = "dotfiles";
              kind = "path";
              location = "${noctaliaLocalPlugins}";
              enabled = true;
            }
          ];
          enabled = [ "alex/mullvad" ];
          auto_update = false;
        };
        weather = {
          enabled = true;
          effects = false;
          refresh_minutes = 30;
          unit = "imperial";
        };
        location.auto_locate = true;
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
          default.path = wallpaper.installedPath;
          monitors = noctaliaWallpaperMonitors;
        };
      };
    };

    # DMS owns its mutable appearance settings. Preserve anything changed in
    # its UI while carrying over this workstation's no-idle-lock/no-suspend
    # policy and seeding the declarative wallpaper for every known output.
    home.activation.dmsWorkstationDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
        --argjson wallpapers ${lib.escapeShellArg (builtins.toJSON wallpaperPaths)} \
        --argjson fillModes ${
          lib.escapeShellArg (builtins.toJSON (lib.mapAttrs (_: _: "Fill") wallpaperPaths))
        } '
          .configVersion = (.configVersion // 3)
          | .perMonitorWallpaper = true
          | .monitorWallpapers = ((.monitorWallpapers // {}) + $wallpapers)
          | .monitorWallpaperFillModes = ((.monitorWallpaperFillModes // {}) + $fillModes)
        ' "$session_input" > "$session_tmp"
      run ${lib.getExe' pkgs.coreutils "chmod"} 0600 "$session_tmp"
      run ${lib.getExe' pkgs.coreutils "mv"} -T "$session_tmp" "$session_file"
      trap - EXIT
    '';

    # Flameshot 14 replaced the compositor-specific grim adapter with the
    # standard screenshot portal. Migrate the mutable per-user config without
    # taking ownership of the rest of Alex's Flameshot preferences.
    home.activation.flameshotPortalMigration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      config_file="$HOME/.config/flameshot/flameshot.ini"
      if [[ -f "$config_file" ]]; then
        $DRY_RUN_CMD ${lib.getExe pkgs.gnused} -i \
          -e '/^useGrimAdapter=/d' \
          -e '/^disabledGrimWarning=/d' \
          "$config_file"
      fi
    '';

    # Keep the official client installed as a fallback, but prevent its in-app
    # autostart toggle from launching it alongside Vesktop.
    xdg.configFile."autostart/discord.desktop" = {
      force = true;
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Discord (official fallback)
        Icon=discord
        Exec=/run/current-system/sw/bin/discord
        Terminal=false
        Hidden=true
        X-GNOME-Autostart-enabled=false
      '';
    };

    xdg.configFile."autostart/vesktop.desktop" = {
      force = true;
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Vesktop
        Comment=Discord client with improved Linux and Wayland support
        Icon=vesktop
        Exec=/run/current-system/sw/bin/vesktop --start-minimized
        Terminal=false
        X-GNOME-Autostart-enabled=true
      '';
    };

    xdg.configFile."niri/config.kdl".text = ''
      // Output policy is generated from dotfiles.compositors.outputs.
      ${niriOutputs}

      spawn-at-startup ${builtins.toJSON (lib.getExe startDesktopShell)}
      spawn-at-startup ${builtins.toJSON (lib.getExe startPolkitAgent)}

      // Every compositor Mod binding also accepts Alt. Explicit Super chords
      // keep their literal modifiers so multi-modifier bindings remain unique.
      ${niriConfigWithAltAliases}
    '';

    wayland.windowManager.mango = {
      enable = true;
      package = mangoPackage;
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
        # Noctalia 5.0 beta does not yet rebuild its device registry after
        # PipeWire or WirePlumber restarts. Refresh the shell with the audio
        # services so its output picker cannot retain dead pre-restart nodes.
        # Both audio services must also pull the shell back in after a fresh
        # start: PartOf propagates a restart, but a switch performs separate
        # stop and start transactions.
        PartOf = [
          "graphical-session.target"
          "pipewire.service"
          "wireplumber.service"
        ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
        After = [
          "graphical-session-pre.target"
          "pipewire.service"
          "wireplumber.service"
        ];
        Wants = [
          "pipewire.service"
          "wireplumber.service"
        ];
      };
      Service = {
        ExecStart = lib.getExe desktopShellProcess;
        # Applications launched from Noctalia remain in its cgroup. Only stop
        # the shell itself so those applications cannot block a shell restart.
        KillMode = "process";
        Restart = "on-failure";
        RestartSec = 1;
        Slice = "session.slice";
      };
      Install.WantedBy = [
        "pipewire.service"
        "wireplumber.service"
      ];
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

    systemd.user.services.flameshot = {
      Unit = {
        Description = "Flameshot screenshot service";
        PartOf = [ "graphical-session.target" ];
        After = [
          "graphical-session.target"
          "xdg-desktop-portal.service"
          "xdg-desktop-portal-gnome.service"
        ];
      };
      Service = {
        ExecStart = lib.getExe pkgs.flameshot;
        Restart = "on-failure";
        RestartSec = 1;
        Slice = "session.slice";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.dotfiles-niri-output-follow = {
      Unit = {
        Description = "Move Niri workspaces with the physical LG output";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = lib.getExe niriFollowPrimaryOutput;
        Restart = "on-failure";
        RestartSec = 1;
        Slice = "session.slice";
      };
    };

    assertions = lib.mapAttrsToList (name: output: {
      assertion =
        builtins.match "^[A-Za-z0-9 ._+#-]+$" name != null
        && (output.mode == null || builtins.match "^[0-9]+x[0-9]+(@[0-9.]+)?$" output.mode != null)
        && (output.niriGaps == null || output.niriGaps >= 0);
      message = "dotfiles.compositors.outputs.${name} has an unsafe output identity, mode, or Niri layout value";
    }) cfg.outputs;
  };
}
