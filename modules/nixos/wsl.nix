{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.wsl;
in
{
  options.dotfiles.wsl = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Linux user managed by the NixOS-WSL profile.";
    };
    userDescription = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Display name for the managed WSL user.";
    };
  };

  config = {
    system.stateVersion = "26.05";
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        cfg.user
      ];
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    # Let WSL inherit the Windows host name. NixOS-WSL currently has a WSL/user-session
    # startup bug when this distro starts while another WSL distro is already running.
    networking.hostName = "";

    programs.zsh.enable = true;
    security.sudo.wheelNeedsPassword = false;

    users.users.${cfg.user} = {
      isNormalUser = true;
      # Keep the conventional first-user UID for DrvFs ownership compatibility.
      uid = 1000;
      description = cfg.userDescription;
      home = "/home/${cfg.user}";
      createHome = true;
      shell = pkgs.zsh;
      extraGroups = [
        "wheel"
      ];
    };

    environment.systemPackages = with pkgs; [
      bubblewrap
      curl
      git
      kubectl
      nano
      vim
      wget
    ];

    # The ChatGPT desktop app currently launches its WSL Codex agent through
    # this conventional path, which NixOS does not provide by default.
    systemd.tmpfiles.rules = [
      "L+ /usr/bin/bash - - - - ${pkgs.bashInteractive}/bin/bash"
    ];

    wsl.extraBin = with pkgs; [
      { src = "${coreutils}/bin/install"; }
      { src = "${coreutils}/bin/mv"; }
      { src = "${coreutils}/bin/rm"; }
    ];

    systemd.services.wsl-interop-binfmt = {
      description = "Register WSL Windows executable interop";
      after = [ "systemd-binfmt.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/proc/sys/fs/binfmt_misc/register";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "register-wsl-interop-binfmt" ''
          set -eu

          if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then
            exit 0
          fi

          echo ':WSLInterop:M::MZ::/init:P' > /proc/sys/fs/binfmt_misc/register
        ''}";
      };
    };

    systemd.timers.wsl-interop-binfmt = {
      description = "Keep WSL Windows executable interop registered";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2s";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
        Unit = "wsl-interop-binfmt.service";
      };
    };

    wsl = {
      enable = true;
      defaultUser = cfg.user;
      useWindowsDriver = true;
      startMenuLaunchers = true;
      interop = {
        register = true;
        includePath = true;
      };
      ssh-agent = {
        enable = true;
        users = [ cfg.user ];
      };
      docker-desktop.enable = true;
      wslConf = {
        automount = {
          enabled = true;
          root = "/mnt";
          options = "metadata,umask=22,fmask=11";
          mountFsTab = false;
        };
        boot.systemd = true;
        interop = {
          enabled = true;
          appendWindowsPath = true;
        };
        network = {
          generateHosts = true;
          generateResolvConf = true;
          hostname = "";
        };
        user.default = cfg.user;
      };
    };
  };
}
