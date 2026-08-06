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
  workstation = cfg.profile == "nixos-desktop";
  terminalFont = pkgs.nerd-fonts.bigblue-terminal;
  canonicalTmuxSocket = "/run/dotfiles-durable-tmux/tmux.sock";
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
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = lib.optionals nativeLinux [
      pkgs.wezterm
      terminalFont
    ];
    home.sessionVariables = lib.mkIf nativeLinux {
      TERMINAL = "wezterm";
    };

    xdg.terminal-exec = lib.mkIf nativeLinux {
      enable = true;
      settings = {
        default = [ "org.wezfurlong.wezterm.desktop" ];
        KDE = [ "org.wezfurlong.wezterm.desktop" ];
      };
    };

    # Home Manager's package path joins the system application search path on
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

    # Tmux owns durable panes, windows, and sessions while the GUI terminal is
    # free to stay small and replaceable. Its stock C-b bindings intentionally
    # match upstream documentation and tutorials.
    programs.tmux = {
      enable = true;
      package = if workstation then canonicalTmuxClient else pkgs.tmux;
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
      extraConfig = builtins.readFile (sourceRoot + "/tmux/tmux.conf");
    };

    # The system-owned tmux process deliberately survives NixOS switches, so
    # apply new personal defaults in place without restarting it.
    home.activation.canonicalTmuxConfiguration = lib.mkIf workstation (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        tmux=${lib.getExe durableTmuxPackage}
        socket=/run/dotfiles-durable-tmux/tmux.sock

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

  };
}
