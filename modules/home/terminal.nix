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
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = lib.optionals nativeLinux [ pkgs.wezterm ];
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

    xdg.configFile."wezterm".source = sourceRoot + "/wezterm";
    home.file.".wezterm.lua".source = sourceRoot + "/.wezterm.lua";

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
