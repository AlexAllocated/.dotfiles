{
  config,
  lib,
  pkgs,
  ...
}:
let
  command = "${pkgs.bash}/bin/bash ${config.home.homeDirectory}/.local/bin/dotctl";
  environment = [
    "DOTFILES_ROOT="
    "PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.git
        pkgs.python3
        pkgs.curl
        pkgs.gh
        pkgs.nix
      ]
    }:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
  ];
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    # Units exist for inspection. No WantedBy: enable only after both host acceptances.
    systemd.user.services.dotfiles-refresh = {
      Unit.Description = "Refresh dotfiles status evidence";
      Service = {
        Type = "oneshot";
        ExecStart = "${command} schedule daily";
        WorkingDirectory = config.home.homeDirectory;
        Environment = environment;
      };
    };
    systemd.user.services.dotfiles-prepare = {
      Unit.Description = "Prepare reviewed dotfiles maintenance candidates";
      Service = {
        Type = "oneshot";
        ExecStart = "${command} schedule weekly";
        WorkingDirectory = config.home.homeDirectory;
        Environment = environment;
        TimeoutStartSec = "12h";
      };
    };
    systemd.user.timers.dotfiles-refresh = {
      Unit.Description = "Daily dotfiles status refresh";
      Timer = {
        OnCalendar = "*-*-* 09:00:00";
        Persistent = true;
      };
    };
    systemd.user.timers.dotfiles-prepare = {
      Unit.Description = "Weekly dotfiles preparation and catalog review";
      Timer = {
        OnCalendar = "Sun *-*-* 04:00:00";
        Persistent = true;
      };
    };
  };
}
