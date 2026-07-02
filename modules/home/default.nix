{ lib, ... }:
{
  imports = [
    ./core.nix
    ./packages.nix
    ./shell.nix
    ./git.nix
    ./nvim.nix
    ./codex.nix
    ./cloud.nix
    ./terminal.nix
    ./windows.nix
  ];

  # Keep existing personal Codex state local unless a consumer explicitly opts
  # into the reusable sanitized config.
  dotfiles.codex.manageConfig = lib.mkDefault false;
}
