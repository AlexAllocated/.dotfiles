{ lib, pkgs, ... }:
let
  optionalPackage = name: lib.optional (builtins.hasAttr name pkgs) (builtins.getAttr name pkgs);
in
{
  imports = [ ./core.nix ];

  config.home.packages =
    (with pkgs; [
      gh
      helm
      k9s
      kubectl
    ])
    ++ lib.concatMap optionalPackage [
      "_1password-cli"
      "azure-cli"
      "google-cloud-sdk"
      "stripe-cli"
    ];
}
