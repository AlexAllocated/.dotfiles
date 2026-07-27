{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
  nativeLinux = pkgs.stdenv.hostPlatform.isLinux && cfg.profile != "nixos-wsl";
  plasmaDesktop = cfg.profile == "nixos-desktop";
  terminalFont = pkgs.nerd-fonts.bigblue-terminal;
  canonicalTmuxSocket = "/run/chev-ttyd-rescue-tmux/tmux.sock";
  durableTmuxPackage = pkgs.tmux.overrideAttrs (oldAttrs: {
    # Upstream's systemd integration places every pane in a transient scope in
    # the caller's user manager. This workstation deliberately keeps one tmux
    # server across graphical logouts, so those scopes would make the daemon
    # survive while its shells are killed with the outgoing desktop session.
    configureFlags = (oldAttrs.configureFlags or [ ]) ++ [ "--disable-cgroups" ];
  });
  canonicalTmuxClient = pkgs.writeShellApplication {
    name = "tmux";
    text = ''
      # Commands inside an existing pane must continue to address that pane's
      # server. Outside tmux, use the workstation's system-owned server unless
      # the caller deliberately selected another server with -L or -S.
      if [[ -n "''${TMUX:-}" ]]; then
        exec ${durableTmuxPackage}/bin/tmux "$@"
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
        exec ${durableTmuxPackage}/bin/tmux "$@"
      fi

      exec ${durableTmuxPackage}/bin/tmux -S ${lib.escapeShellArg canonicalTmuxSocket} "$@"
    '';
  };
  desktopClipboardCopy = pkgs.writeShellApplication {
    name = "dotfiles-clipboard-copy";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      systemd
      wl-clipboard
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)}"
      export XDG_RUNTIME_DIR="$runtime_dir"
      if [[ -z "''${WAYLAND_DISPLAY:-}" || ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]]; then
        WAYLAND_DISPLAY="$(${lib.getExe' pkgs.systemd "systemctl"} --user show-environment \
          | ${lib.getExe pkgs.gnused} -n 's/^WAYLAND_DISPLAY=//p' \
          | ${lib.getExe' pkgs.coreutils "head"} -n 1)"
        export WAYLAND_DISPLAY
      fi
      exec ${lib.getExe' pkgs.wl-clipboard "wl-copy"} --type text/plain "$@"
    '';
  };
  desktopClipboardPaste = pkgs.writeShellApplication {
    name = "dotfiles-clipboard-paste";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      systemd
      wl-clipboard
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)}"
      export XDG_RUNTIME_DIR="$runtime_dir"
      if [[ -z "''${WAYLAND_DISPLAY:-}" || ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]]; then
        WAYLAND_DISPLAY="$(${lib.getExe' pkgs.systemd "systemctl"} --user show-environment \
          | ${lib.getExe pkgs.gnused} -n 's/^WAYLAND_DISPLAY=//p' \
          | ${lib.getExe' pkgs.coreutils "head"} -n 1)"
        export WAYLAND_DISPLAY
      fi
      exec ${lib.getExe' pkgs.wl-clipboard "wl-paste"} --no-newline "$@"
    '';
  };
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = lib.optionals nativeLinux [
      desktopClipboardCopy
      desktopClipboardPaste
      pkgs.wezterm
      terminalFont
    ];
    home.sessionVariables = lib.mkIf nativeLinux {
      TERMINAL = "wezterm";
    };

    # Wayland clipboard contents are owned by the process that copied them.
    # Retain both selections after short-lived helpers, tmux copy commands, or
    # applications exit so Noctalia history is not the only surviving copy.
    systemd.user.services.wl-clip-persist = lib.mkIf nativeLinux {
      Unit.Description = "Persist Wayland clipboard selections";
      Service = {
        ExecStart = "${lib.getExe pkgs.wl-clip-persist} --clipboard both --reconnect-tries INF";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = [ "default.target" ];
    };

    xdg.terminal-exec = lib.mkIf nativeLinux {
      enable = true;
      settings = {
        default = [ "org.wezfurlong.wezterm.desktop" ];
        KDE = [ "org.wezfurlong.wezterm.desktop" ];
      };
    };

    # Home Manager's package path joins the Plasma application search path on
    # the next NixOS system switch. Publish Alacritty's canonical desktop ID in
    # the user data directory too, so it is discoverable immediately after a
    # user-only activation during migration. The matching ID cleanly shadows
    # the packaged entry instead of creating a duplicate later.
    xdg.dataFile."applications/Alacritty.desktop" = lib.mkIf nativeLinux {
      text = ''
        [Desktop Entry]
        Type=Application
        TryExec=${lib.getExe pkgs.alacritty}
        Exec=${lib.getExe pkgs.alacritty}
        Icon=${pkgs.alacritty}/share/icons/hicolor/scalable/apps/Alacritty.svg
        Terminal=false
        Categories=System;TerminalEmulator;

        Name=Alacritty
        GenericName=Terminal
        Comment=A fast, cross-platform, OpenGL terminal emulator
        StartupNotify=true
        StartupWMClass=Alacritty
        Actions=New;

        [Desktop Action New]
        Name=New Terminal
        Exec=${lib.getExe pkgs.alacritty}
      '';
    };

    xdg.configFile."wezterm".source = sourceRoot + "/wezterm";
    home.file.".wezterm.lua".source = sourceRoot + "/.wezterm.lua";
    home.file.".local/bin/tmux-cheatsheet" = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        set -euo pipefail

        exec ${lib.getExe pkgs.bat} \
          --style=plain \
          --theme=gruvbox-dark \
          --paging=always \
          "${sourceRoot}/docs/tmux-cheatsheet.md"
      '';
    };

    xdg.dataFile."konsole/Alex-Gruvbox.profile" = lib.mkIf plasmaDesktop {
      source = sourceRoot + "/konsole/Alex-Gruvbox.profile";
    };
    xdg.dataFile."konsole/AlexGruvboxDarkHard.colorscheme" = lib.mkIf plasmaDesktop {
      source = sourceRoot + "/konsole/AlexGruvboxDarkHard.colorscheme";
    };

    # Tmux owns durable panes, windows, and sessions while the GUI terminal is
    # free to stay small and replaceable. Its stock C-b bindings intentionally
    # match upstream documentation and tutorials.
    programs.tmux = {
      enable = true;
      package = if plasmaDesktop then canonicalTmuxClient else pkgs.tmux;
      mouse = true;
      terminal = "tmux-256color";
      historyLimit = 50000;
      focusEvents = true;
      plugins = [
        {
          plugin = pkgs.tmuxPlugins.gruvbox;
          extraConfig = ''
            # Keep the statusline legible and consistent across every terminal
            # instead of depending on each terminal's 16-color palette.
            set -g @tmux-gruvbox 'dark256'
            set -g @tmux-gruvbox-statusbar-alpha 'false'
            set -g @tmux-gruvbox-left-status-a '#S'
            set -g @tmux-gruvbox-right-status-x '%a %b %d'
            set -g @tmux-gruvbox-right-status-y '%H:%M'
            set -g @tmux-gruvbox-right-status-z '#h'
          '';
        }
      ];
      extraConfig =
        builtins.readFile (sourceRoot + "/tmux/tmux.conf")
        + lib.optionalString nativeLinux ''
          # Keep the desktop clipboard authoritative even when this canonical
          # server also has SSH clients.
          set -s copy-command '${lib.getExe desktopClipboardCopy}'
        ''
        + lib.optionalString plasmaDesktop ''
          # Mouse reporting prevents WezTerm from reclaiming a right-click once
          # tmux receives it. Read the system clipboard and bracketed-paste it
          # directly into the pane that was clicked.
          bind-key -T root MouseDown3Pane run-shell -b \
            '${lib.getExe desktopClipboardPaste} | ${lib.getExe durableTmuxPackage} -S ${lib.escapeShellArg canonicalTmuxSocket} load-buffer -b dotfiles-system-clipboard - && ${lib.getExe durableTmuxPackage} -S ${lib.escapeShellArg canonicalTmuxSocket} paste-buffer -b dotfiles-system-clipboard -d -p -t "#{mouse_pane}"'
        '';
    };

    # The system-owned tmux process deliberately survives NixOS switches, so
    # apply new personal defaults in place without restarting it.
    home.activation.canonicalTmuxConfiguration = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        tmux=${lib.getExe durableTmuxPackage}
        socket=/run/chev-ttyd-rescue-tmux/tmux.sock

        if [[ -S "$socket" ]]; then
          run "$tmux" -S "$socket" source-file "$HOME/.config/tmux/tmux.conf"
          run "$tmux" -S "$socket" set-option -s exit-empty off
        fi
      ''
    );

    # Keep Alacritty installed as the fast, deliberately minimal alternative
    # even though WezTerm owns the native Linux terminal defaults.
    programs.alacritty = lib.mkIf nativeLinux {
      enable = true;
      settings = {
        general.live_config_reload = true;
        window = {
          decorations = "Full";
          decorations_theme_variant = "Dark";
          dynamic_padding = false;
          dynamic_title = true;
          # Let a little of the desktop show through without sacrificing the
          # contrast of the Gruvbox Dark background.
          opacity = 0.9;
          padding = {
            x = 0;
            y = 5;
          };
        };
        scrolling = {
          history = 10000;
          multiplier = 3;
        };
        font = {
          size = 14.0;
          normal = {
            family = "BigBlueTerm437 Nerd Font";
            style = "Regular";
          };
          bold = {
            family = "BigBlueTerm437 Nerd Font";
            style = "Regular";
          };
          italic = {
            family = "BigBlueTerm437 Nerd Font";
            style = "Regular";
          };
          bold_italic = {
            family = "BigBlueTerm437 Nerd Font";
            style = "Regular";
          };
        };
        colors = {
          draw_bold_text_with_bright_colors = true;
          primary = {
            background = "#1d2021";
            foreground = "#ebdbb2";
            bright_foreground = "#fbf1c7";
            dim_foreground = "#a89984";
          };
          cursor = {
            cursor = "#ebdbb2";
            text = "#1d2021";
          };
          selection = {
            background = "#504945";
            text = "CellForeground";
          };
          normal = {
            black = "#1d2021";
            red = "#cc241d";
            green = "#98971a";
            yellow = "#d79921";
            blue = "#458588";
            magenta = "#b16286";
            cyan = "#689d6a";
            white = "#a89984";
          };
          bright = {
            black = "#928374";
            red = "#fb4934";
            green = "#b8bb26";
            yellow = "#fabd2f";
            blue = "#83a598";
            magenta = "#d3869b";
            cyan = "#8ec07c";
            white = "#ebdbb2";
          };
        };
        cursor = {
          style = {
            shape = "Block";
            blinking = "On";
          };
          blink_interval = 500;
          blink_timeout = 0;
          unfocused_hollow = true;
        };
        selection.save_to_clipboard = false;
        terminal.osc52 = "OnlyCopy";
        mouse.hide_when_typing = true;
        bell.duration = 0;
      };
    };

    home.activation.weztermPlasmaDefault = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file kdeglobals \
          --group General \
          --key TerminalApplication \
          "wezterm start --cwd ."
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file kdeglobals \
          --group General \
          --key TerminalService \
          "org.wezfurlong.wezterm.desktop"
      ''
    );

    # Konsole's built-in profile is immutable. Add a managed profile instead,
    # and change only the default-profile key so any user-created profiles are
    # preserved alongside it.
    home.activation.konsoleDefaultProfile = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file konsolerc \
          --group "Desktop Entry" \
          --key DefaultProfile \
          "Alex-Gruvbox.profile"
      ''
    );

    # Remove the former no-border rule now that Plasma owns WezTerm's titlebar
    # and resize frame. Leaving the rule behind would make one-tab windows
    # chromeless and remove their edge-resize hitboxes.
    home.activation.weztermPlasmaDecorationCleanup = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        rules_file="''${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc"
        rule_id="wezterm-integrated-chrome"
        rules="$(${lib.getExe' pkgs.kdePackages.kconfig "kreadconfig6"} \
          --file "$rules_file" \
          --group General \
          --key rules \
          --default "")"

        filtered_rules=""
        old_ifs="$IFS"
        IFS=,
        for rule in $rules; do
          if [ "$rule" != "$rule_id" ]; then
            filtered_rules="''${filtered_rules:+$filtered_rules,}$rule"
          fi
        done
        IFS="$old_ifs"

        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group General --key rules "$filtered_rules"

        for key in \
          Description Enabled noborder noborderrule types \
          wmclass wmclasscomplete wmclassmatch; do
          run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
            --file "$rules_file" --group "$rule_id" --key "$key" --delete ""
        done

        ${lib.getExe' pkgs.systemd "busctl"} --user call \
          org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1 || true
      ''
    );
  };
}
