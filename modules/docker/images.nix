{
  pkgs,
  toolPkgs ? pkgs,
  source,
  user ? "alex",
  fullName ? "Alex",
  userEmail ? "Alex@HiveTech.ai",
}:
let
  inherit (pkgs) lib;

  uid = 1000;
  gid = 1000;
  codexPackage = if builtins.hasAttr "codex" toolPkgs then toolPkgs.codex else pkgs.codex;
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  optionalPackage =
    packageSet: name:
    lib.optional (builtins.hasAttr name packageSet) (builtins.getAttr name packageSet);

  usersAndGroups = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    ${user}:x:${toString uid}:${toString gid}:${fullName}:/home/${user}:/bin/zsh
  '';

  groups = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    wheel:x:10:${user}
    users:x:${toString gid}:${user}
    ${user}:x:${toString gid}:
  '';

  shadows = pkgs.writeTextDir "etc/shadow" ''
    root:!:::::::
    ${user}:!:::::::
  '';

  gshadows = pkgs.writeTextDir "etc/gshadow" ''
    root:x::
    wheel:x::${user}
    users:x::${user}
    ${user}:x::
  '';

  sudoers = pkgs.writeTextDir "etc/sudoers" ''
    root ALL=(ALL:ALL) ALL
    ${user} ALL=(ALL:ALL) NOPASSWD: ALL
  '';

  nsswitch = pkgs.writeTextDir "etc/nsswitch.conf" ''
    passwd: files
    group: files
    shadow: files
    hosts: files dns
  '';

  profile = pkgs.writeTextDir "etc/profile" ''
    export USER=${user}
    export HOME=/home/${user}
    export SHELL=/bin/zsh
    export EDITOR=nvim
    export VISUAL=nvim
    export SSL_CERT_FILE=${caBundle}
    export CURL_CA_BUNDLE=${caBundle}
    export PATH=/home/${user}/.local/bin:/bin:/usr/bin
  '';

  gitConfig = pkgs.writeText "gitconfig" ''
    [user]
    	name = ${fullName}
    	email = ${userEmail}
    [core]
    	editor = nvim
    	pager = delta
    [init]
    	defaultBranch = main
    [pull]
    	rebase = false
    [credential "https://github.com"]
    	helper =
    	helper = !gh auth git-credential
  '';

  homeSkeleton = pkgs.runCommand "dotfiles-container-home" { } ''
    mkdir -p \
    	$out/home/${user}/.codex/rules \
    	$out/home/${user}/.config \
    	$out/home/${user}/.local/bin \
	$out/home/${user}/.dotfiles \
	$out/home/${user}/code \
    	$out/root \
    	$out/work

    cp -R ${source}/. $out/home/${user}/.dotfiles/
    chmod -R u+rwX $out/home/${user}/.dotfiles

    ln -s /home/${user}/.dotfiles/.zprofile $out/home/${user}/.zprofile
    ln -s /home/${user}/.dotfiles/.zshrc $out/home/${user}/.zshrc
    ln -s /home/${user}/.dotfiles/nvim $out/home/${user}/.config/nvim
    ln -s /home/${user}/.dotfiles/wezterm $out/home/${user}/.config/wezterm
    ln -s /home/${user}/.dotfiles/.wezterm.lua $out/home/${user}/.wezterm.lua
    ln -s /home/${user}/.dotfiles/codex/config.toml $out/home/${user}/.codex/config.toml
    ln -s /home/${user}/.dotfiles/codex/rules/default.rules $out/home/${user}/.codex/rules/default.rules
    ln -s /home/${user}/.dotfiles/scripts/dotctl $out/home/${user}/.local/bin/dotctl
    ln -s /home/${user}/.dotfiles/.p10k.zsh $out/home/${user}/.p10k.zsh
    ln -s /home/${user}/.dotfiles/.tool-versions $out/home/${user}/.tool-versions
    ln -s /home/${user}/.dotfiles/rustfmt.toml $out/home/${user}/rustfmt.toml

    cp ${gitConfig} $out/home/${user}/.gitconfig
  '';

  basePackages = with pkgs; [
    bashInteractive
    bat
    cacert
    coreutils
    curl
    delta
    eza
    fastfetch
    fd
    file
    findutils
    fzf
    gawk
    git
    gnugrep
    gnused
    gzip
    jq
    less
    ncurses
    neovim
    nodejs
    openssh
    procps
    ripgrep
    shadow
    sudo
    gnutar
    unzip
    wget
    which
    zoxide
    zsh
  ];

  pocketPackages =
    basePackages
    ++ (with pkgs; [
      gcc
      gnumake
      lazygit
      lua
      python3
      tree
      tree-sitter
    ])
    ++ lib.concatMap (optionalPackage pkgs) [
      "zsh-powerlevel10k"
      "zsh-vi-mode"
    ]
    ++ [
      codexPackage
    ];

  fullPackages =
    pocketPackages
    ++ (with pkgs; [
      cmake
      gh
      gnupg
      go
      helm
      k9s
      kubectl
      lynx
      mise
      ninja
      pkg-config
      rust-analyzer
      rustc
      cargo
      shellcheck
      stylua
    ])
    ++ lib.concatMap (optionalPackage pkgs) [
      "_1password-cli"
      "azure-cli"
      "docker-client"
      "dotnet-sdk"
      "google-cloud-sdk"
      "nil"
      "nix"
      "nixfmt"
      "stripe-cli"
      "tlrc"
      "wordnet"
    ];

  rootFor =
    name: packages:
    pkgs.buildEnv {
      name = "${name}-root";
      paths = [
        usersAndGroups
        groups
        shadows
        gshadows
        sudoers
        nsswitch
        profile
        homeSkeleton
      ]
      ++ packages;
      pathsToLink = [
        "/bin"
        "/etc"
        "/home"
        "/root"
        "/share"
        "/work"
      ];
      ignoreCollisions = true;
    };

  mkImage =
    {
      name,
      packages,
      description,
    }:
    pkgs.dockerTools.buildLayeredImage {
      name = "ghcr.io/alexallocated/${name}";
      tag = "latest";
      contents = [ (rootFor name packages) ];
      fakeRootCommands = ''
        mkdir -p ./tmp ./usr/bin ./bin
        chmod 1777 ./tmp
        if [ -L ./home/${user} ]; then
          homeTarget="$(readlink ./home/${user})"
          rm ./home/${user}
          mkdir -p ./home/${user}
          cp -a "$homeTarget/." ./home/${user}/
        fi
        chmod 0440 ./etc/sudoers
        chown -R ${toString uid}:${toString gid} ./home/${user} ./work
        chmod -R u+rwX ./home/${user}
        rm -f ./bin/sudo
        cp ${pkgs.sudo}/bin/sudo ./bin/sudo
        chmod 4755 ./bin/sudo
        cp ${pkgs.sudo}/bin/sudo ./usr/bin/sudo
        chmod 4755 ./usr/bin/sudo
        ln -sf bash ./bin/sh
        ln -sf /bin/env ./usr/bin/env
      '';
      config = {
        User = "${toString uid}:${toString gid}";
        WorkingDir = "/home/${user}/code";
        Cmd = [
          "/bin/zsh"
          "-l"
        ];
        Env = [
          "USER=${user}"
          "HOME=/home/${user}"
          "SHELL=/bin/zsh"
          "DOTFILES_ROOT=/home/${user}/.dotfiles"
          "DOTFILES_WORKSHOP=1"
          "EDITOR=nvim"
          "VISUAL=nvim"
          "SSL_CERT_FILE=${caBundle}"
          "CURL_CA_BUNDLE=${caBundle}"
          "PATH=/home/${user}/.local/bin:/bin:/usr/bin"
        ];
        Labels = {
          "org.opencontainers.image.title" = name;
          "org.opencontainers.image.description" = description;
          "org.opencontainers.image.source" = "https://github.com/AlexAllocated/.dotfiles";
        };
      };
    };
in
{
  docker-linux = mkImage {
    name = "dotfiles-linux";
    packages = fullPackages;
    description = "Full Linux tool environment from Alex's dotfiles.";
  };

  docker-pocket-knife = mkImage {
    name = "dotfiles-pocket-knife";
    packages = pocketPackages;
    description = "Slim repair shell with Git, Neovim, Codex, and core diagnostics.";
  };
}
