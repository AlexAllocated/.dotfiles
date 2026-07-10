{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs; };
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = toolsets.editor;

    home.sessionVariables = {
      EDITOR = "nvim";
      NEOVIM_SRC_DIR = "${config.home.homeDirectory}/.cache/neovim";
    };

    xdg.configFile."nvim".source = sourceRoot + "/nvim";

    programs.zsh.shellAliases = {
      nv = "nvim";
      vi = "nvim";
      vim = "nvim";
    };
  };
}
