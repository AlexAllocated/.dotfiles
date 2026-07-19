{
  config,
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

  hyprlandOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderHyprlandOutput cfg.outputs);
  niriOutputs = lib.concatStringsSep "\n" (lib.mapAttrsToList renderNiriOutput cfg.outputs);
  startPolkitAgent = "${lib.getExe' pkgs.systemd "systemctl"} --user start dotfiles-compositor-polkit.service";
in
{
  imports = [ ./core.nix ];

  options.dotfiles.compositors = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.dotfiles.profile == "nixos-desktop";
      description = "Configure the optional Hyprland and niri desktop sessions.";
    };

    outputs = lib.mkOption {
      default = { };
      description = "Portable output policy rendered into both compositor configurations.";
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
      noctalia-shell
      playerctl
      swaylock
    ];

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

        local start_polkit_agent = ${toLua startPolkitAgent}

        ${builtins.readFile (sourceRoot + "/wayland/hyprland.lua")}
      '';
    };

    xdg.configFile."niri/config.kdl".text = ''
      // Output policy is generated from dotfiles.compositors.outputs.
      ${niriOutputs}

      spawn-at-startup "noctalia-shell"
      spawn-at-startup ${builtins.toJSON (lib.getExe' pkgs.systemd "systemctl")} "--user" "start" "dotfiles-compositor-polkit.service"

      ${builtins.readFile (sourceRoot + "/wayland/niri.kdl")}
    '';

    # Noctalia starts directly from each compositor as its upstream v4 docs
    # recommend. Only the authentication agent is service-managed, and it is
    # deliberately not enabled globally so Plasma retains its own agent.
    home.sessionVariables.NOCTALIA_PAM_SERVICE = "login";
    home.activation.noctaliaInitialSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings_dir=${lib.escapeShellArg "${config.xdg.configHome}/noctalia"}
      settings_file="$settings_dir/settings.json"

      if [[ ! -e "$settings_file" ]]; then
        (
          run ${lib.getExe' pkgs.coreutils "mkdir"} -p "$settings_dir"
          settings_tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} "$settings_dir/.settings.json.XXXXXX")"
          trap '${lib.getExe' pkgs.coreutils "rm"} -f -- "$settings_tmp"' EXIT

          settings_schema="$(${lib.getExe pkgs.gnused} -n \
            's/^[[:space:]]*readonly property int settingsVersion: \([0-9][0-9]*\)[[:space:]]*$/\1/p' \
            ${pkgs.noctalia-shell}/share/noctalia-shell/Commons/Settings.qml)"
          if [[ ! "$settings_schema" =~ ^[0-9]+$ ]]; then
            echo "Could not determine Noctalia's settings schema version" >&2
            exit 1
          fi

          ${lib.getExe pkgs.jq} --argjson settingsVersion "$settings_schema" '
            .settingsVersion = $settingsVersion
            | .colorSchemes.predefinedScheme = "Gruvbox"
            | .colorSchemes.darkMode = true
            | .general.lockOnSuspend = false
            | .sessionMenu.powerOptions |= map(
                if .action == "lock" or .action == "suspend" or .action == "hibernate"
                then .enabled = false
                else .
                end
              )
          ' ${pkgs.noctalia-shell}/share/noctalia-shell/Assets/settings-default.json > "$settings_tmp"

          run ${lib.getExe' pkgs.coreutils "chmod"} 0600 "$settings_tmp"
          run ${lib.getExe' pkgs.coreutils "mv"} -T "$settings_tmp" "$settings_file"
          trap - EXIT
        )
      fi
    '';

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
