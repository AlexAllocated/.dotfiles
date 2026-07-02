{ lib, pkgs, ... }:
let
  optionalPackage = name: lib.optional (builtins.hasAttr name pkgs) (builtins.getAttr name pkgs);
  optionalPackages = lib.concatMap optionalPackage [
    "dotnet-sdk"
    "nil"
    "nixfmt"
    "tlrc"
    "wordnet"
  ];
in
{
  imports = [ ./core.nix ];

  config.home.packages =
    (with pkgs; [
      cmake
      curl
      fastfetch
      file
      gcc
      gnugrep
      gnumake
      gnupg
      go
      jq
      lua
      lynx
      mise
      ninja
      openssh
      pkg-config
      procps
      python3
      cargo
      rustc
      rust-analyzer
      shellcheck
      stylua
      tree
      tree-sitter
      unzip
      wget
    ])
    ++ optionalPackages
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
      with pkgs;
      [
        usbutils
        wl-clipboard
        xclip
      ]
    );
}
