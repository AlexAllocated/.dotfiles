{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.durableTmux;
  canonicalTmuxSocket = "/run/dotfiles-durable-tmux/tmux.sock";
  durableTmuxPackage = pkgs.tmux.overrideAttrs (oldAttrs: {
    # The system-owned server must not place panes in transient scopes owned
    # by a graphical user manager that is intentionally recycled on logout.
    configureFlags = (oldAttrs.configureFlags or [ ]) ++ [ "--disable-cgroups" ];
  });
  canonicalTmuxClient = pkgs.writeShellApplication {
    name = "tmux";
    text = ''
      # Preserve the server selected by an existing pane. Outside tmux, use
      # the workstation's canonical server unless one was explicitly chosen.
      if [[ -n "''${TMUX:-}" ]]; then
        exec ${durableTmuxPackage}/bin/tmux "$@"
      fi

      explicit_socket=false
      OPTIND=1
      while getopts ':2CDhlNuVvc:f:L:S:T:' option; do
        case "$option" in
          L | S) explicit_socket=true ;;
          *) ;;
        esac
      done

      if [[ "$explicit_socket" == true ]]; then
        exec ${durableTmuxPackage}/bin/tmux "$@"
      fi

      exec ${durableTmuxPackage}/bin/tmux -S ${lib.escapeShellArg canonicalTmuxSocket} "$@"
    '';
  };
in
{
  options.dotfiles.durableTmux = {
    enable = lib.mkEnableOption "the system-owned canonical tmux server";
    user = lib.mkOption {
      type = lib.types.str;
      default = "alex";
      description = "Local user that owns the durable tmux server and its panes.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "The durable tmux user must be declared in users.users.";
      }
    ];

    environment.systemPackages = [ canonicalTmuxClient ];

    systemd.services.dotfiles-durable-tmux = {
      description = "Canonical durable tmux server";
      wantedBy = [ "multi-user.target" ];
      # Its sessions are live user state. Routine switches must never replace
      # the server process underneath attached or detached shells.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      path = [
        pkgs.bash
        pkgs.coreutils
        durableTmuxPackage
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = "users";
        RuntimeDirectory = "dotfiles-durable-tmux";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes";
        KillMode = "process";
        Restart = "always";
        RestartSec = 1;
        ExecStart = pkgs.writeShellScript "dotfiles-durable-tmux-start" ''
          set -eu
          tmux=${durableTmuxPackage}/bin/tmux
          socket="$RUNTIME_DIRECTORY/tmux.sock"
          home=/home/${cfg.user}

          server_running() {
            "$tmux" -N -S "$socket" display-message -p '#{pid}' >/dev/null 2>&1
          }
          trap 'exit 0' INT TERM

          while :; do
            if ! server_running; then
              "$tmux" -S "$socket" -f /dev/null start-server \; set-option -s exit-empty off
            fi
            if [ -r "$home/.config/tmux/tmux.conf" ]; then
              if ! "$tmux" -S "$socket" source-file "$home/.config/tmux/tmux.conf"; then
                printf '%s\n' 'The personal tmux config did not load cleanly; continuing with durable defaults.' >&2
              fi
            fi
            "$tmux" -S "$socket" set-option -s exit-empty off

            while server_running; do
              ${pkgs.coreutils}/bin/sleep 1
            done
          done
        '';
      };
    };
  };
}
