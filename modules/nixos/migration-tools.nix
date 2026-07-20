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
  rescueWebFont =
    pkgs.runCommand "bigblue-terminal-webfont" { nativeBuildInputs = [ pkgs.woff2 ]; }
      ''
        cp \
          ${pkgs.nerd-fonts.bigblue-terminal}/share/fonts/truetype/NerdFonts/BigBlueTerm/BigBlueTerm437NerdFont-Regular.ttf \
          BigBlueTerm437NerdFont-Regular.ttf
        woff2_compress BigBlueTerm437NerdFont-Regular.ttf
        mkdir -p "$out"
        mv BigBlueTerm437NerdFont-Regular.woff2 "$out/bigblue.woff2"
      '';

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
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start the unauthenticated rescue terminal automatically on a private LAN address.";
      };
      durableTmux = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Attach web clients to a dedicated tmux session that survives browser disconnects.";
      };
      preventSleep = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Block system sleep while rescue access is enabled.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = codexPackage.version == "0.144.4";
        message = "The migration ISO is pinned to Codex 0.144.4; update and retest the capsule resume contract before changing it.";
      }
      {
        assertion = !cfg.rescue.enable || builtins.hasAttr cfg.rescue.user config.users.users;
        message = "The ttyd rescue user must be declared in users.users.";
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

    systemd.sleep.settings.Sleep = lib.mkIf (cfg.rescue.enable && cfg.rescue.preventSleep) {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };

    systemd.services.chev-recovery-sleep-inhibit =
      lib.mkIf (cfg.rescue.enable && cfg.rescue.preventSleep)
        {
          description = "Keep the live migration recovery environment awake";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep --who=chev-migration --why=Keep ttyd and Codex recovery sessions connected --mode=block ${pkgs.coreutils}/bin/sleep infinity";
            Restart = "always";
            RestartSec = 1;
          };
        };

    systemd.services.chev-ttyd-rescue-tmux = lib.mkIf (cfg.rescue.enable && cfg.rescue.durableTmux) {
      description = "Durable tmux server for ttyd recovery access";
      wantedBy = lib.optionals cfg.rescue.autoStart [ "multi-user.target" ];
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.tmux
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.rescue.user;
        Group = "users";
        RuntimeDirectory = "chev-ttyd-rescue-tmux";
        RuntimeDirectoryMode = "0750";
        Restart = "always";
        RestartSec = 1;
        ExecStart = pkgs.writeShellScript "chev-ttyd-rescue-tmux-start" ''
          set -eu
          tmux=${pkgs.tmux}/bin/tmux
          socket="$RUNTIME_DIRECTORY/tmux.sock"
          session=recovery
          home=/home/${cfg.rescue.user}

          cleanup() {
            "$tmux" -S "$socket" kill-server 2>/dev/null || true
          }
          trap cleanup EXIT
          trap 'exit 0' INT TERM

          # Keep supervising the named session. A user may intentionally kill
          # a tmux server while experimenting; the recovery endpoint must not
          # remain healthy-looking while its attach target is gone.
          while :; do
            if ! "$tmux" -S "$socket" has-session -t "=$session" 2>/dev/null; then
              "$tmux" -S "$socket" -f /dev/null new-session -d -s "$session" -c "$home"
              if [ -r "$home/.config/tmux/tmux.conf" ]; then
                if ! "$tmux" -S "$socket" source-file "$home/.config/tmux/tmux.conf"; then
                  printf '%s\n' 'The personal tmux config did not load cleanly; continuing with recovery-safe defaults.' >&2
                fi
              fi
              "$tmux" -S "$socket" set-option -g mouse off
              "$tmux" -S "$socket" set-option -g alternate-screen off
              "$tmux" -S "$socket" set-option -g history-limit 100000
              "$tmux" -S "$socket" rename-window -t "=$session:0" rescue
            fi

            while "$tmux" -S "$socket" has-session -t "=$session" 2>/dev/null; do
              ${pkgs.coreutils}/bin/sleep 1
            done
          done
        '';
        ExecStop = "${pkgs.tmux}/bin/tmux -S /run/chev-ttyd-rescue-tmux/tmux.sock kill-server";
      };
    };

    systemd.services.chev-ttyd-rescue = lib.mkIf cfg.rescue.enable {
      description = "Temporary ttyd migration rescue terminal";
      wantedBy = lib.optionals cfg.rescue.autoStart [ "multi-user.target" ];
      wants = lib.optionals cfg.rescue.autoStart [ "network-online.target" ];
      requires = lib.optionals cfg.rescue.durableTmux [ "chev-ttyd-rescue-tmux.service" ];
      after =
        lib.optionals cfg.rescue.autoStart [ "network-online.target" ]
        ++ lib.optionals cfg.rescue.durableTmux [ "chev-ttyd-rescue-tmux.service" ];
      unitConfig = lib.optionalAttrs (!cfg.rescue.autoStart) {
        ConditionPathExists = "/run/chev-rescue/address";
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.rescue.user;
        Group = "users";
        RuntimeDirectory = "chev-ttyd-rescue";
        RuntimeDirectoryMode = "0750";
        Restart = if cfg.rescue.autoStart then "always" else "no";
        RestartSec = 2;
        ExecStartPre = pkgs.writeShellScript "chev-ttyd-rescue-index" ''
          set -eu
          runtime_directory="''${RUNTIME_DIRECTORY:?systemd did not provide RUNTIME_DIRECTORY}"
          index_path="$runtime_directory/index.html"
          temporary_index="$index_path.tmp"
          marked_index="$index_path.marked"
          generator_port=17681
          generator_log="$runtime_directory/index-generator.log"

          cleanup() {
            if [ -n "''${generator_pid:-}" ]; then
              ${pkgs.coreutils}/bin/kill "$generator_pid" 2>/dev/null || true
              wait "$generator_pid" 2>/dev/null || true
            fi
            ${pkgs.coreutils}/bin/rm -f "$temporary_index" "$marked_index"
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
                -e 's|<meta charset="UTF-8">|<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>@font-face{font-family:"BigBlueTerm437 Nerd Font";src:url(data:font/woff2;base64,CHEV_BIGBLUE_FONT_DATA) format("woff2");font-weight:400;font-style:normal;font-display:block}html,body{position:fixed;inset:0;width:100%;height:100%;margin:0;overflow:hidden;overscroll-behavior:none;background:#1d2021}body{box-sizing:border-box;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}.xterm{font-family:"BigBlueTerm437 Nerd Font",monospace}.xterm-viewport{touch-action:pan-y;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}</style>|' \
                -e 's|<title>ttyd - Terminal</title>|<title>Hive Recovery Terminal</title>|' \
                >"$marked_index"; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          [ -s "$marked_index" ] && ${pkgs.gnugrep}/bin/grep -Fq CHEV_BIGBLUE_FONT_DATA "$marked_index" || {
            printf '%s\\n' 'Unable to generate the mobile ttyd index.' >&2
            exit 1
          }
          ${pkgs.gawk}/bin/awk -v RS=CHEV_BIGBLUE_FONT_DATA '
            NR == 1 {
              printf "%s", $0
              fflush()
              status = system("${pkgs.coreutils}/bin/base64 --wrap=0 ${rescueWebFont}/bigblue.woff2")
              if (status != 0) exit status
              next
            }
            { printf "%s", $0 }
          ' "$marked_index" >"$temporary_index"
          ${pkgs.coreutils}/bin/mv -f "$temporary_index" "$index_path"
        '';
        ExecStart = "${pkgs.writeShellScript "chev-ttyd-rescue" ''
          set -eu
          ${
            if cfg.rescue.autoStart then
              ''
                address=""
                while read -r candidate; do
                  case "$candidate" in
                    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*)
                      address="$candidate"
                      break
                      ;;
                  esac
                done < <(${pkgs.iproute2}/bin/ip -4 -o address show scope global | ${pkgs.gawk}/bin/awk '{ sub("/.*", "", $4); print $4 }')
                [ -n "$address" ] || {
                  printf '%s\n' 'No private IPv4 LAN address is active; retrying.' >&2
                  exit 1
                }
              ''
            else
              ''
                address="$(cat /run/chev-rescue/address)"
              ''
          }
          exec ${pkgs.ttyd}/bin/ttyd \
            --writable \
            --check-origin \
            --interface "$address" \
            --port 7681 \
            --index "$RUNTIME_DIRECTORY/index.html" \
            --max-clients 3 \
            --client-option fontSize=18 \
            --client-option 'fontFamily=BigBlueTerm437 Nerd Font' \
            --client-option lineHeight=1.15 \
            --client-option scrollback=100000 \
            --client-option cursorBlink=true \
            --client-option disableLeaveAlert=true \
            --client-option 'theme={"background":"#1d2021","foreground":"#ebdbb2","cursor":"#83a598","selectionBackground":"#504945"}' \
            --ping-interval 15 \
            ${
              if cfg.rescue.durableTmux then
                "${pkgs.tmux}/bin/tmux -S /run/chev-ttyd-rescue-tmux/tmux.sock attach-session -t =recovery"
              else
                "${pkgs.bashInteractive}/bin/bash --login"
            }
        ''}";
      };
    };
  };
}
