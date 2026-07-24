{
  config,
  lib,
  migrationPkgs ? toolPkgs,
  pkgs,
  toolPkgs ? pkgs,
  ...
}:
let
  cfg = config.dotfiles.migrationTools;
  source = toString cfg.source;
  codexPackage = if builtins.hasAttr "codex" migrationPkgs then migrationPkgs.codex else pkgs.codex;
  canonicalTmuxSocket = "/run/chev-ttyd-rescue-tmux/tmux.sock";
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

  rescueWebStyle = ''
    @font-face {
      font-family: "BigBlueTerm437 Nerd Font";
      src: url(data:font/woff2;base64,CHEV_BIGBLUE_FONT_DATA) format("woff2");
      font-weight: 400;
      font-style: normal;
      font-display: block;
    }

    :root {
      --chev-viewport-left: 0px;
      --chev-viewport-top: 0px;
      --chev-viewport-width: 100vw;
      --chev-viewport-height: 100dvh;
    }

    html {
      position: fixed !important;
      inset: 0 !important;
      width: 100% !important;
      height: 100% !important;
      min-height: 0 !important;
      margin: 0 !important;
      overflow: hidden !important;
      overscroll-behavior: none;
      background: #1d2021;
    }

    body {
      position: fixed !important;
      top: var(--chev-viewport-top) !important;
      left: var(--chev-viewport-left) !important;
      right: auto !important;
      bottom: auto !important;
      box-sizing: border-box;
      width: var(--chev-viewport-width) !important;
      height: var(--chev-viewport-height) !important;
      min-height: 0 !important;
      max-height: var(--chev-viewport-height) !important;
      margin: 0 !important;
      padding:
        env(safe-area-inset-top)
        env(safe-area-inset-right)
        env(safe-area-inset-bottom)
        env(safe-area-inset-left);
      overflow: hidden !important;
      overscroll-behavior: none;
      background: #1d2021;
    }

    #terminal-container {
      box-sizing: border-box !important;
      width: 100% !important;
      height: 100% !important;
      min-height: 0 !important;
      max-height: 100% !important;
      margin: 0 !important;
      overflow: hidden !important;
    }

    #terminal-container .terminal {
      box-sizing: border-box !important;
      width: 100% !important;
      height: 100% !important;
      min-height: 0 !important;
      padding: 5px !important;
    }

    .xterm {
      height: 100% !important;
      font-family: "BigBlueTerm437 Nerd Font", monospace;
    }

    .xterm-viewport {
      touch-action: pan-y;
      overscroll-behavior: contain;
      -webkit-overflow-scrolling: touch;
    }
  '';

  rescueWebScript = ''
    (() => {
      "use strict";

      let fitFrame = 0;
      let wheelRemainder = 0;

      const fitTerminal = () => {
        if (fitFrame) {
          window.cancelAnimationFrame(fitFrame);
        }

        fitFrame = window.requestAnimationFrame(() => {
          fitFrame = 0;
          if (window.term && typeof window.term.fit === "function") {
            window.term.fit();
          }
        });
      };

      const syncVisualViewport = () => {
        const viewport = window.visualViewport;
        const root = document.documentElement;
        const left = viewport ? viewport.offsetLeft : 0;
        const top = viewport ? viewport.offsetTop : 0;
        const width = viewport ? viewport.width : window.innerWidth;
        const height = viewport ? viewport.height : window.innerHeight;

        root.style.setProperty("--chev-viewport-left", Math.round(left) + "px");
        root.style.setProperty("--chev-viewport-top", Math.round(top) + "px");
        root.style.setProperty("--chev-viewport-width", Math.floor(width) + "px");
        root.style.setProperty("--chev-viewport-height", Math.floor(height) + "px");
        fitTerminal();
      };

      const scrollTerminal = (event) => {
        const target = event.target;
        if (!(target instanceof Element) || !target.closest(".xterm")) {
          return;
        }

        // xterm turns wheel input into Up/Down when the active buffer has no
        // scrollback. Stop that at the capture phase, but retain real xterm
        // scrollback whenever it exists.
        event.preventDefault();
        event.stopImmediatePropagation();

        const terminal = window.term;
        if (!terminal || !terminal.buffer || !terminal.buffer.active) {
          return;
        }

        if (!(terminal.buffer.active.baseY > 0)) {
          wheelRemainder = 0;
          return;
        }

        let lines = event.deltaY;
        if (event.deltaMode === WheelEvent.DOM_DELTA_PIXEL) {
          const screen = document.querySelector(".xterm-screen");
          const measuredRowHeight =
            screen && terminal.rows > 0 ? screen.clientHeight / terminal.rows : 0;
          const fallbackRowHeight =
            terminal.options.fontSize * terminal.options.lineHeight;
          lines /= Math.max(measuredRowHeight || fallbackRowHeight, 1);
        } else if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) {
          lines *= terminal.rows;
        }

        wheelRemainder += lines;
        const wholeLines =
          wheelRemainder < 0
            ? Math.ceil(wheelRemainder)
            : Math.floor(wheelRemainder);
        if (wholeLines !== 0) {
          wheelRemainder -= wholeLines;
          terminal.scrollLines(wholeLines);
        }
      };

      document.addEventListener("wheel", scrollTerminal, {
        capture: true,
        passive: false,
      });
      window.addEventListener("resize", syncVisualViewport);

      if (window.visualViewport) {
        window.visualViewport.addEventListener("resize", syncVisualViewport);
        window.visualViewport.addEventListener("scroll", syncVisualViewport);
      }

      if (document.fonts && document.fonts.ready) {
        document.fonts.ready.then(fitTerminal);
      }

      syncVisualViewport();
    })();
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

  canonicalTmuxClient = pkgs.writeShellApplication {
    name = "tmux";
    text = ''
      # Preserve the server selected by an existing pane. This lets the one
      # pre-migration local server be detached cleanly without redirecting its
      # management commands elsewhere.
      if [[ -n "''${TMUX:-}" ]]; then
        exec ${pkgs.tmux}/bin/tmux "$@"
      fi

      explicit_socket=false
      OPTIND=1
      while getopts ':2CDhlNuVvc:f:L:S:T:' option; do
        case "$option" in
          L | S)
            explicit_socket=true
            ;;
          *)
            ;;
        esac
      done

      if [[ "$explicit_socket" == true ]]; then
        exec ${pkgs.tmux}/bin/tmux "$@"
      fi

      exec ${pkgs.tmux}/bin/tmux -S ${lib.escapeShellArg canonicalTmuxSocket} "$@"
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
        description = "Run a system-owned tmux server independently of graphical and user sessions.";
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
        assertion =
          !(cfg.rescue.enable || cfg.rescue.durableTmux)
          || builtins.hasAttr cfg.rescue.user config.users.users;
        message = "The ttyd rescue and durable tmux user must be declared in users.users.";
      }
    ];

    environment.systemPackages = [
      resumeMigration
      checkpointMigration
      (if cfg.rescue.durableTmux then canonicalTmuxClient else pkgs.tmux)
      rebootWindows
      recoverWindowsFallback
      exportMachineManifest
      validateMachineManifest
    ]
    ++ lib.optionals cfg.installCommand [
      codexPackage
      installChevDesktop
    ]
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

    systemd.services.chev-ttyd-rescue-tmux = lib.mkIf cfg.rescue.durableTmux {
      description = "Canonical durable tmux server";
      wantedBy = [ "multi-user.target" ];
      # A generation switch may replace this unit's script or tmux package,
      # but its sessions are live user state. Pick up those changes on the next
      # boot instead of terminating every shell during routine activation.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
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
        RuntimeDirectoryPreserve = "yes";
        # The tmux server and its panes are the durable workload. Service
        # supervision may be refreshed without signaling those child
        # processes or unlinking their socket.
        KillMode = "process";
        Restart = "always";
        RestartSec = 1;
        ExecStart = pkgs.writeShellScript "chev-ttyd-rescue-tmux-start" ''
          set -eu
          tmux=${pkgs.tmux}/bin/tmux
          socket="$RUNTIME_DIRECTORY/tmux.sock"
          home=/home/${cfg.rescue.user}

          server_running() {
            "$tmux" -N -S "$socket" display-message -p '#{pid}' >/dev/null 2>&1
          }
          trap 'exit 0' INT TERM

          # Keep the server available without manufacturing an immortal user
          # session. exit-empty=off lets the final real session disappear while
          # preserving the canonical socket for the next client.
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
          styled_index="$index_path.styled"
          scripted_index="$index_path.scripted"
          generator_port=17681
          generator_log="$runtime_directory/index-generator.log"

          cleanup() {
            if [ -n "''${generator_pid:-}" ]; then
              ${pkgs.coreutils}/bin/kill "$generator_pid" 2>/dev/null || true
              wait "$generator_pid" 2>/dev/null || true
            fi
            ${pkgs.coreutils}/bin/rm -f \
              "$temporary_index" \
              "$marked_index" \
              "$styled_index" \
              "$scripted_index"
          }
          trap cleanup EXIT INT TERM

          replace_marker() {
            input_path="$1"
            marker="$2"
            replacement="$3"
            output_path="$4"

            ${pkgs.gawk}/bin/awk \
              -v RS="$marker" \
              -v replacement="$replacement" \
              '
                NR == 1 {
                  leading = $0
                  next
                }
                NR == 2 {
                  trailing = $0
                  next
                }
                { duplicate = 1 }
                END {
                  if (NR != 2 || duplicate) exit 1
                  printf "%s%s%s", leading, replacement, trailing
                }
              ' \
              "$input_path" >"$output_path"
          }

          ${pkgs.ttyd}/bin/ttyd \
            --interface 127.0.0.1 \
            --port "$generator_port" \
            ${pkgs.coreutils}/bin/sleep infinity >"$generator_log" 2>&1 &
          generator_pid=$!
          for attempt in $(${pkgs.coreutils}/bin/seq 1 25); do
            if ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 1 \
              "http://127.0.0.1:$generator_port/" \
              | ${pkgs.gnused}/bin/sed \
                -e 's|<meta charset="UTF-8">|<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>CHEV_RECOVERY_STYLE</style>|' \
                -e 's|<title>ttyd - Terminal</title>|<title>Hive Recovery Terminal</title>|' \
                -e 's|</body>|<script>CHEV_RECOVERY_SCRIPT</script></body>|' \
                >"$marked_index"; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          [ -s "$marked_index" ] \
            && ${pkgs.gnugrep}/bin/grep -Fq CHEV_RECOVERY_STYLE "$marked_index" \
            && ${pkgs.gnugrep}/bin/grep -Fq CHEV_RECOVERY_SCRIPT "$marked_index" || {
            printf '%s\\n' 'Unable to generate the mobile ttyd index.' >&2
            exit 1
          }

          replace_marker \
            "$marked_index" \
            CHEV_RECOVERY_STYLE \
            ${lib.escapeShellArg rescueWebStyle} \
            "$styled_index"
          replace_marker \
            "$styled_index" \
            CHEV_RECOVERY_SCRIPT \
            ${lib.escapeShellArg rescueWebScript} \
            "$scripted_index"

          ${pkgs.gnugrep}/bin/grep -Fq CHEV_BIGBLUE_FONT_DATA "$scripted_index" || {
            printf '%s\\n' 'The generated ttyd index is missing its webfont marker.' >&2
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
          ' "$scripted_index" >"$temporary_index"
          ${pkgs.gnugrep}/bin/grep -Fq -- '--chev-viewport-height' "$temporary_index" \
            && ${pkgs.gnugrep}/bin/grep -Fq 'stopImmediatePropagation' "$temporary_index" \
            && ! ${pkgs.gnugrep}/bin/grep -Fq CHEV_ "$temporary_index" || {
            printf '%s\\n' 'The generated ttyd index failed frontend validation.' >&2
            exit 1
          }
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
                "${pkgs.tmux}/bin/tmux -S ${canonicalTmuxSocket} new-session -A -s recovery"
              else
                "${pkgs.bashInteractive}/bin/bash --login"
            }
        ''}";
      };
    };
  };
}
