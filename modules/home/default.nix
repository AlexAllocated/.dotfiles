{ lib, ... }:
{
  imports = [
    ./core.nix
    ./foundation.nix
    ./development.nix
    ./shell.nix
    ./git.nix
    ./nvim.nix
    ./codex.nix
    ./cloud.nix
    ./terminal.nix
    ./windows.nix
  ];

  dotfiles.codex.manageConfig = lib.mkDefault true;
}
