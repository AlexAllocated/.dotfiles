{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.chatgptService;
  account = config.users.users.${cfg.user};
  app = import ../../packages/chatgpt-desktop.nix { inherit lib pkgs; };
in
{
  options.dotfiles.chatgptService = {
    enable = lib.mkEnableOption "system-supervised ChatGPT desktop recovery";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing desktop user whose ChatGPT app is supervised.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = account.uid != null && cfg.user != "root";
        message = "ChatGPT supervision requires a non-root desktop user with a fixed UID.";
      }
    ];

    systemd.services.chatgpt-desktop = {
      description = "Keep ChatGPT available whenever the desktop is running";
      wantedBy = [ "multi-user.target" ];
      after = [ "user@${toString account.uid}.service" ];
      restartIfChanged = false;
      environment = {
        HOME = account.home;
        XDG_RUNTIME_DIR = "/run/user/${toString account.uid}";
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${toString account.uid}/bus";
        PATH = lib.mkForce "/run/wrappers/bin:/etc/profiles/per-user/${cfg.user}/bin:${account.home}/.nix-profile/bin:/run/current-system/sw/bin";
      };
      serviceConfig = {
        User = cfg.user;
        WorkingDirectory = account.home;
        ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/nixos/chatgpt-supervisor.py} ${lib.getExe app}";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 20;
        UMask = "0077";
      };
    };
  };
}
