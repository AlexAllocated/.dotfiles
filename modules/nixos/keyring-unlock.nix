{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.keyringUnlock;
  account = config.users.users.${cfg.user};
  python = pkgs.python3.withPackages (p: [ p.secretstorage ]);
  tool = pkgs.writeShellApplication {
    name = "keyring-tpm-enroll";
    runtimeInputs = [
      pkgs.zenity
      pkgs.dbus
      pkgs.gnome-keyring
      pkgs.systemd
      pkgs.coreutils
    ];
    text = ''
      exec ${python}/bin/python3 ${../../scripts/nixos/keyring-unlock.py} enroll
    '';
  };
in
{
  options.dotfiles.keyringUnlock = {
    enable = lib.mkEnableOption "TPM-sealed default keyring unlocking for unattended desktop login";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Desktop user whose existing default GNOME keyring is unlocked.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = account.uid != null && cfg.user != "root";
        message = "Keyring unlocking requires a non-root desktop user with a fixed UID.";
      }
    ];
    environment.systemPackages = [ tool ];
    systemd.services.tracer-keyring-unlock = {
      description = "Unlock the encrypted desktop keyring using Tracer's TPM";
      # The session launcher restarts this synchronously before any desktop
      # clients. A boot-target dependency would delay SDDM or miss later logins.
      after = [ "user@${toString account.uid}.service" ];
      unitConfig.ConditionPathExists = "/var/lib/tracer-keyring/keyring-password.cred";
      path = [ pkgs.systemd ];
      environment = {
        HOME = account.home;
        XDG_RUNTIME_DIR = "/run/user/${toString account.uid}";
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${toString account.uid}/bus";
      };
      serviceConfig = {
        User = cfg.user;
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${python}/bin/python3 ${../../scripts/nixos/keyring-unlock.py} unlock";
        LoadCredentialEncrypted = "keyring-password:/var/lib/tracer-keyring/keyring-password.cred";
        TimeoutStartSec = 20;
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
      };
    };
  };
}
