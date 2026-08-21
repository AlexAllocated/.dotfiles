{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
  nativeLinux = pkgs.stdenv.hostPlatform.isLinux && !cfg.isWsl;
in
{
  imports = [ ./core.nix ];

  config = lib.mkIf (!cfg.isWsl) {
    home.packages = lib.optionals nativeLinux [
      pkgs.neovide
      pkgs.nerd-fonts.bigblue-terminal
    ];

    xdg.configFile."neovide/config.toml".source = sourceRoot + "/neovide/config.toml";
  };
}
