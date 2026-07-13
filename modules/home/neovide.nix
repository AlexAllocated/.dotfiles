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
in
{
  imports = [ ./core.nix ];

  config = lib.mkIf (cfg.profile != "nixos-wsl") {
    home.packages = lib.optionals nativeLinux [
      pkgs.neovide
      pkgs.nerd-fonts.bigblue-terminal
    ];

    xdg.configFile."neovide/config.toml".source = sourceRoot + "/neovide/config.toml";
  };
}
