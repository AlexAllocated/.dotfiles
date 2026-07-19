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

    xdg.dataFile."applications/com.mitchellh.ghostty.desktop" = lib.mkIf nativeLinux {
      text = ''
        [Desktop Entry]
        Version=1.0
        Name=Ghostty
        Type=Application
        Comment=A terminal emulator
        TryExec=${lib.getExe pkgs.ghostty}
        Exec=${lib.getExe pkgs.ghostty} --gtk-single-instance=true
        Icon=${pkgs.ghostty}/share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png
        Categories=System;TerminalEmulator;
        Keywords=terminal;tty;pty;
        StartupNotify=true
        StartupWMClass=com.mitchellh.ghostty
        Terminal=false
        Actions=new-window;
        X-GNOME-UsesNotifications=true
        X-TerminalArgExec=-e
        X-TerminalArgTitle=--title=
        X-TerminalArgAppId=--class=
        X-TerminalArgDir=--working-directory=
        X-TerminalArgHold=--wait-after-command
        DBusActivatable=true
        X-KDE-Shortcuts=Ctrl+Alt+T

        [Desktop Action new-window]
        Name=New Window
        Exec=${lib.getExe pkgs.ghostty} --gtk-single-instance=true
      '';
    };

    xdg.dataFile."applications/kitty.desktop" = lib.mkIf nativeLinux {
      text = ''
        [Desktop Entry]
        Version=1.0
        Type=Application
        Name=kitty
        GenericName=Terminal emulator
        Comment=Fast, feature-rich, GPU based terminal
        TryExec=${lib.getExe pkgs.kitty}
        StartupNotify=true
        Exec=${lib.getExe pkgs.kitty}
        Icon=${pkgs.kitty}/share/icons/hicolor/scalable/apps/kitty.svg
        Categories=System;TerminalEmulator;
        X-TerminalArgExec=--
        X-TerminalArgTitle=--title
        X-TerminalArgAppId=--class
        X-TerminalArgDir=--working-directory
        X-TerminalArgHold=--hold
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
      mouse = true;
      terminal = "tmux-256color";
      historyLimit = 50000;
      focusEvents = true;
      extraConfig = builtins.readFile (sourceRoot + "/tmux/tmux.conf");
    };

    # Keep WezTerm as the portable default while making native Linux terminals
    # available for side-by-side evaluation. Their visuals intentionally mirror
    # the established WezTerm configuration.
    programs.alacritty = lib.mkIf nativeLinux {
      enable = true;
      settings = {
        general.live_config_reload = true;
        window = {
          decorations = "Full";
          decorations_theme_variant = "Dark";
          dynamic_padding = false;
          dynamic_title = true;
          opacity = 1.0;
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

    programs.ghostty = lib.mkIf nativeLinux {
      enable = true;
      systemd.enable = true;
      settings = {
        "font-family" = "BigBlueTerm437 Nerd Font";
        "font-size" = 14;
        theme = "Gruvbox Dark Hard";

        "background-opacity" = 1.0;
        "bold-is-bright" = true;
        "clipboard-paste-bracketed-safe" = true;
        "clipboard-paste-protection" = true;
        "clipboard-read" = "ask";
        "clipboard-trim-trailing-spaces" = true;
        "clipboard-write" = "allow";
        "confirm-close-surface" = "always";
        "copy-on-select" = false;
        "cursor-style" = "block";
        "cursor-style-blink" = true;
        "mouse-hide-while-typing" = true;
        "right-click-action" = "copy-or-paste";
        "scrollback-limit" = 10000000;
        scrollbar = "never";
        "shell-integration-features" = "no-cursor";
        "window-padding-balance" = false;
        "window-padding-x" = 0;
        "window-padding-y" = "10,0";
        "window-show-tab-bar" = "auto";

        # Ghostty owns one draggable client-side titlebar. Its separate tab bar
        # appears only after a second tab, so KWin must not add another frame.
        "window-decoration" = "client";
        "gtk-titlebar" = true;
        "gtk-titlebar-style" = "native";
        "gtk-tabs-location" = "top";
        "gtk-single-instance" = true;
      };
    };

    programs.kitty = lib.mkIf nativeLinux {
      enable = true;
      font = {
        name = "BigBlueTerm437 Nerd Font";
        package = terminalFont;
        size = 14;
      };
      themeFile = "gruvbox-dark-hard";
      shellIntegration.mode = "no-cursor";
      settings = {
        background_opacity = 1.0;
        clipboard_control = "write-clipboard write-primary read-clipboard-ask read-primary-ask";
        confirm_os_window_close = 1;
        copy_on_select = false;
        cursor_blink_interval = 0.5;
        cursor_shape = "block";
        enable_audio_bell = false;
        mouse_hide_wait = -1;
        paste_actions = "quote-urls-at-prompt,confirm";
        remember_window_size = true;
        scrollback_lines = 10000;
        scrollbar = "scrolled";
        strip_trailing_spaces = "smart";
        tab_bar_edge = "top";
        tab_bar_min_tabs = 2;
        tab_bar_style = "powerline";
        tab_powerline_style = "round";
        update_check_interval = 0;
        window_padding_width = "10 0 0";
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

    # WezTerm renders its window controls inside the tab bar. KWin can still
    # add server-side decorations on Wayland, so suppress its outer titlebar
    # for this application only.
    home.activation.weztermPlasmaIntegratedChrome = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        rules_file="''${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc"
        rule_id="wezterm-integrated-chrome"
        rules="$(${lib.getExe' pkgs.kdePackages.kconfig "kreadconfig6"} \
          --file "$rules_file" \
          --group General \
          --key rules \
          --default "")"

        case ",$rules," in
          *,"$rule_id",*) ;;
          *)
            rules="''${rules:+$rules,}$rule_id"
            ;;
        esac

        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group General --key rules "$rules"
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key Description \
          "Let WezTerm render its integrated window controls"
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key Enabled --type bool true
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key wmclass \
          "org.wezfurlong.wezterm"
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key wmclasscomplete \
          --type bool false
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key wmclassmatch 1
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key types 1
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key noborder --type bool true
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file "$rules_file" --group "$rule_id" --key noborderrule 2

        ${lib.getExe' pkgs.systemd "busctl"} --user call \
          org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1 || true
      ''
    );
  };
}
