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
      TERMINAL = "alacritty";
    };

    xdg.terminal-exec = lib.mkIf nativeLinux {
      enable = true;
      settings = {
        default = [ "Alacritty.desktop" ];
        KDE = [ "Alacritty.desktop" ];
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

    # Alacritty is the native Linux default. WezTerm remains installed as the
    # portable, feature-rich alternative.
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

    home.activation.alacrittyPlasmaDefault = lib.mkIf plasmaDesktop (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file kdeglobals \
          --group General \
          --key TerminalApplication \
          "alacritty --working-directory ."
        run ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
          --file kdeglobals \
          --group General \
          --key TerminalService \
          "Alacritty.desktop"
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
