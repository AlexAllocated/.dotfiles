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
    legacyUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Previous WSL login whose home should be migrated to the managed user.";
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
    time.timeZone = "America/Denver";

    programs.zsh.enable = true;
    security.sudo.wheelNeedsPassword = false;

    services.openssh = {
      enable = true;
      openFirewall = false;
      authorizedKeysInHomedir = true;
      settings = {
        AuthenticationMethods = "publickey";
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ cfg.user ];
      };
    };

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

    system.activationScripts = {
      users.deps = lib.mkBefore [ "wslLegacyHomeMigration" ];
      wslLegacyHomeMigration.text = lib.optionalString (cfg.legacyUser != null) ''
        legacyHome=/home/${cfg.legacyUser}
        managedHome=/home/${cfg.user}

        if [ -L "$legacyHome" ]; then
          resolved="$(${pkgs.coreutils}/bin/readlink -f -- "$legacyHome" || true)"
          if [ "$resolved" != "$managedHome" ]; then
            echo "Refusing unexpected legacy WSL home link: $legacyHome -> $resolved" >&2
            exit 1
          fi
        elif [ -e "$legacyHome" ]; then
          if [ -e "$managedHome" ]; then
            echo "Refusing to merge two WSL homes: $legacyHome and $managedHome" >&2
            exit 1
          fi
          echo "Moving the legacy WSL home from $legacyHome to $managedHome"
          ${pkgs.coreutils}/bin/mv -- "$legacyHome" "$managedHome"
          ${pkgs.coreutils}/bin/ln -s -- "$managedHome" "$legacyHome"
        else
          ${pkgs.coreutils}/bin/ln -s -- "$managedHome" "$legacyHome"
        fi

        for relativePath in .nix-profile .nix-defexpr/channels; do
          linkPath="$managedHome/$relativePath"
          if [ -L "$linkPath" ]; then
            linkTarget="$(${pkgs.coreutils}/bin/readlink -- "$linkPath")"
            case "$linkTarget" in
              "$legacyHome"/*)
                canonicalTarget="$managedHome/''${linkTarget#"$legacyHome/"}"
                ${pkgs.coreutils}/bin/ln -sfn -- "$canonicalTarget" "$linkPath"
                ;;
            esac
          fi
        done
      '';
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

    # Windows owns the LAN listener while WSL's NAT address is ephemeral. The
    # elevated Windows task is installed by apply-wsl-ssh-forward.ps1. Asking
    # it to run here makes address changes self-healing without a polling loop.
    systemd.services.wsl-ssh-forward-refresh = {
      description = "Refresh the Windows SSH forward to NixOS-WSL";
      after = [ "sshd.service" ];
      wants = [ "sshd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.writeShellScript "refresh-windows-wsl-ssh-forward" ''
          set -eu
          task='Dotfiles NixOS-WSL SSH Forward'
          schtasks=/mnt/c/Windows/System32/schtasks.exe

          if [ ! -x "$schtasks" ]; then
            echo "Windows Task Scheduler is unavailable; skipping the SSH forward refresh." >&2
            exit 0
          fi
          if ! output="$($schtasks /Run /TN "$task" 2>&1)"; then
            echo "The Windows SSH-forward task is not installed yet; dotctl apply nixos-wsl will install it." >&2
            printf '%s\n' "$output" >&2
          fi
        ''}";
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
