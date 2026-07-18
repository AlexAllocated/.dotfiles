{
  config,
  lib,
  pkgs,
  toolPkgs ? pkgs,
  ...
}:
let
  cfg = config.dotfiles.migrationTools;
  source = toString cfg.source;
  codexPackage = if builtins.hasAttr "codex" toolPkgs then toolPkgs.codex else pkgs.codex;

  mkTool =
    {
      name,
      script,
      runtimeInputs,
      environment ? "",
      arguments ? "",
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        ${environment}
        exec ${pkgs.bash}/bin/bash ${source}/${script} ${arguments} "$@"
      '';
    };

  resumeMigration = mkTool {
    name = "resume-migration";
    script = "scripts/nixos/resume-migration.sh";
    environment = ''
      export CHEV_DOTFILES_SOURCE=${lib.escapeShellArg source}
    '';
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      jq
      openssl
      python3
      rsync
      util-linux
      codexPackage
    ];
  };

  exportMachineManifest = mkTool {
    name = "export-machine-manifest";
    script = "scripts/nixos/machine-manifest.sh";
    arguments = "export";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      gnused
      util-linux
    ];
  };

  validateMachineManifest = mkTool {
    name = "validate-machine-manifest";
    script = "scripts/nixos/machine-manifest.sh";
    arguments = "validate";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      jq
      gnused
      util-linux
    ];
  };

  installChevDesktop = mkTool {
    name = "install-chev-desktop";
    script = "scripts/nixos/install-chev-desktop.sh";
    environment = ''
      export CHEV_DOTFILES_SOURCE=${lib.escapeShellArg source}
    '';
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      dosfstools
      findutils
      gawk
      git
      gnugrep
      jq
      nixos-install-tools
      python3
      rsync
      util-linux
      validateMachineManifest
    ];
  };

  rescueRemoteOn = mkTool {
    name = "rescue-remote-on";
    script = "scripts/nixos/rescue-remote-on.sh";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
      systemd
    ];
  };

  rescueRemoteOff = mkTool {
    name = "rescue-remote-off";
    script = "scripts/nixos/rescue-remote-off.sh";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
  };

  rebootWindows = mkTool {
    name = "reboot-windows";
    script = "scripts/nixos/reboot-windows.sh";
    runtimeInputs = with pkgs; [
      coreutils
      efibootmgr
      jq
      gnused
      systemd
    ];
  };

  recoverWindowsFallback = mkTool {
    name = "recover-windows-fallback";
    script = "scripts/nixos/recover-windows-fallback.sh";
    runtimeInputs = with pkgs; [
      coreutils
      dosfstools
      findutils
      gawk
      jq
      util-linux
      validateMachineManifest
    ];
  };
in
{
  options.dotfiles.migrationTools = {
    enable = lib.mkEnableOption "the chev-desktop migration and recovery commands";

    source = lib.mkOption {
      type = lib.types.path;
      default = ../..;
      description = "Immutable dotfiles source embedded in migration commands.";
    };

    installCommand = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to include the destructive, confirmation-gated installer command.";
    };

    rescue = {
      enable = lib.mkEnableOption "the manually activated ttyd rescue terminal";
      user = lib.mkOption {
        type = lib.types.str;
        default = "nixos";
        description = "Unprivileged user used by the ttyd rescue terminal.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = codexPackage.version == "0.144.4";
        message = "The migration ISO is pinned to Codex 0.144.4; update and retest the capsule resume contract before changing it.";
      }
    ];

    environment.systemPackages = [
      resumeMigration
      rebootWindows
      recoverWindowsFallback
      exportMachineManifest
      validateMachineManifest
    ]
    ++ lib.optional cfg.installCommand installChevDesktop
    ++ lib.optionals cfg.rescue.enable [
      rescueRemoteOn
      rescueRemoteOff
      pkgs.ttyd
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.rescue.enable [ 7681 ];

    systemd.services.chev-ttyd-rescue = lib.mkIf cfg.rescue.enable {
      description = "Temporary ttyd migration rescue terminal";
      unitConfig.ConditionPathExists = "/run/chev-rescue/address";
      serviceConfig = {
        Type = "simple";
        User = cfg.rescue.user;
        Group = "users";
        Restart = "no";
        ExecStart = "${pkgs.writeShellScript "chev-ttyd-rescue" ''
          set -eu
          address="$(cat /run/chev-rescue/address)"
          exec ${pkgs.ttyd}/bin/ttyd \
            --writable \
            --interface "$address" \
            --port 7681 \
            ${pkgs.bashInteractive}/bin/bash --login
        ''}";
      };
    };
  };
}
