{
  lib,
  pkgs,
  toolPkgs ? pkgs,
}:
let
  optional =
    packageSet: name:
    lib.optional (builtins.hasAttr name packageSet) (builtins.getAttr name packageSet);
  optionalPkgs = packageSet: names: lib.concatMap (optional packageSet) names;
  codex = if builtins.hasAttr "codex" toolPkgs then toolPkgs.codex else pkgs.codex;
in
rec {
  foundation =
    (with pkgs; [
      bat
      curl
      eza
      fastfetch
      fd
      file
      fzf
      jq
      lynx
      openssh
      ripgrep
      rsync
      tree
      unzip
      wget
      zoxide
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [ procps ]);

  shell =
    (with pkgs; [ zsh ])
    ++ optionalPkgs pkgs [
      "zsh-powerlevel10k"
      "zsh-vi-mode"
    ];

  git = [
    pkgs.delta
    pkgs.git
    pkgs.lazygit
  ];

  editor = with pkgs; [
    fd
    gcc
    pkgs.git
    gnumake
    lua
    marksman
    neovim
    nodejs
    python3
    ripgrep
    stylua
    tree-sitter
  ];

  agent = [
    codex
    pkgs.bun
    pkgs.nodejs
  ];

  development =
    (with pkgs; [
      cargo
      cmake
      gcc
      gnumake
      gnugrep
      go
      gnupg
      lua
      mise
      ninja
      pkg-config
      pnpm
      python3
      rust-analyzer
      rustc
      shellcheck
      stylua
      uv
    ])
    ++ optionalPkgs pkgs [
      "docker-client"
      "dotnet-sdk"
      "nil"
      "nix"
      "nixfmt"
      "tlrc"
      "wordnet"
    ];

  cloud =
    (with pkgs; [
      gh
      (google-cloud-sdk.withExtraComponents [ google-cloud-sdk.components.gke-gcloud-auth-plugin ])
      k9s
      kubernetes-helm
      kubectl
    ])
    ++ optionalPkgs pkgs [
      "_1password-cli"
      "azure-cli"
      "stripe-cli"
    ];

  containerBase = with pkgs; [
    bashInteractive
    cacert
    coreutils
    findutils
    gawk
    gnused
    gzip
    less
    ncurses
    rsync
    shadow
    sudo
    gnutar
    which
  ];

  pocketKnife = lib.unique (
    containerBase
    ++ foundation
    ++ shell
    ++ [
      codex
      pkgs.bun
      pkgs.delta
      pkgs.fd
      pkgs.gitMinimal
      pkgs.lazygit
      pkgs.neovim
      pkgs.nodejs
      pkgs.ripgrep
    ]
  );
  workstation = lib.unique (
    containerBase ++ foundation ++ shell ++ git ++ editor ++ agent ++ development ++ cloud
  );
}
