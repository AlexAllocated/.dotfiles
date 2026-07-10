{ lib, pkgs, ... }:
let
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs; };
in
{
  imports = [ ./core.nix ];
  config.home.packages = toolsets.foundation;
}
