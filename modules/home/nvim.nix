{ config, pkgs, ... }:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = with pkgs; [
      fd
      gcc
      git
      gnumake
      lua
      neovim
      nodejs
      python3
      ripgrep
      stylua
      tree-sitter
    ];

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
