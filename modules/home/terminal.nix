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
  };
}
