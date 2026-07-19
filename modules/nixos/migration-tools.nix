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
      tmux
      util-linux
      codexPackage
    ];
  };

  checkpointMigration = mkTool {
    name = "checkpoint-migration";
    script = "scripts/nixos/checkpoint-migration.sh";
    environment = ''
      export CHEV_DOTFILES_SOURCE=${lib.escapeShellArg source}
    '';
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      python3
      util-linux
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
      codexPackage
      resumeMigration
      checkpointMigration
      pkgs.tmux
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

    systemd.sleep.settings.Sleep = lib.mkIf cfg.rescue.enable {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };

    systemd.services.chev-recovery-sleep-inhibit = lib.mkIf cfg.rescue.enable {
      description = "Keep the live migration recovery environment awake";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep --who=chev-migration --why=Keep ttyd and Codex recovery sessions connected --mode=block ${pkgs.coreutils}/bin/sleep infinity";
        Restart = "always";
        RestartSec = 1;
      };
    };

    systemd.services.chev-ttyd-rescue = lib.mkIf cfg.rescue.enable {
      description = "Temporary ttyd migration rescue terminal";
      unitConfig.ConditionPathExists = "/run/chev-rescue/address";
      serviceConfig = {
        Type = "simple";
        User = cfg.rescue.user;
        Group = "users";
        RuntimeDirectory = "chev-ttyd-rescue";
        RuntimeDirectoryMode = "0750";
        Restart = "no";
        ExecStartPre = pkgs.writeShellScript "chev-ttyd-rescue-index" ''
          set -eu
          runtime_directory="''${RUNTIME_DIRECTORY:?systemd did not provide RUNTIME_DIRECTORY}"
          index_path="$runtime_directory/index.html"
          temporary_index="$index_path.tmp"
          generator_port=17681
          generator_log="$runtime_directory/index-generator.log"

          cleanup() {
            if [ -n "''${generator_pid:-}" ]; then
              ${pkgs.coreutils}/bin/kill "$generator_pid" 2>/dev/null || true
              wait "$generator_pid" 2>/dev/null || true
            fi
            ${pkgs.coreutils}/bin/rm -f "$temporary_index"
          }
          trap cleanup EXIT INT TERM

          ${pkgs.ttyd}/bin/ttyd \
            --interface 127.0.0.1 \
            --port "$generator_port" \
            ${pkgs.coreutils}/bin/sleep infinity >"$generator_log" 2>&1 &
          generator_pid=$!
          for attempt in $(${pkgs.coreutils}/bin/seq 1 25); do
            if ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 1 \
              "http://127.0.0.1:$generator_port/" \
              | ${pkgs.gnused}/bin/sed \
                's#<meta charset="UTF-8">#<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">#' \
                >"$temporary_index"; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          [ -s "$temporary_index" ] || {
            printf '%s\\n' 'Unable to generate the mobile ttyd index.' >&2
            exit 1
          }
          ${pkgs.coreutils}/bin/mv -f "$temporary_index" "$index_path"
        '';
        ExecStart = "${pkgs.writeShellScript "chev-ttyd-rescue" ''
          set -eu
          address="$(cat /run/chev-rescue/address)"
          exec ${pkgs.ttyd}/bin/ttyd \
            --writable \
            --check-origin \
            --interface "$address" \
            --port 7681 \
            --index "$RUNTIME_DIRECTORY/index.html" \
            --client-option fontSize=18 \
            --client-option scrollback=100000 \
            --client-option cursorBlink=true \
            --ping-interval 15 \
            ${pkgs.bashInteractive}/bin/bash --login
        ''}";
      };
    };
  };
}
