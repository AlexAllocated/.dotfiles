{
  pkgs,
  toolPkgs ? pkgs,
  source,
  user ? "dev",
  fullName ? "Dotfiles User",
}:
let
  inherit (pkgs) lib;
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs toolPkgs; };

  uid = 1000;
  gid = 1000;
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

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
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    export EDITOR=nvim
    export VISUAL=nvim
    export SSL_CERT_FILE=${caBundle}
    export CURL_CA_BUNDLE=${caBundle}
    export PATH=/home/${user}/.local/bin:/bin:/usr/bin
  '';

  homeSkeleton = pkgs.runCommand "dotfiles-container-home" { } ''
    mkdir -p \
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
    ln -s /home/${user}/.dotfiles/.gitconfig $out/home/${user}/.gitconfig
    ln -s /home/${user}/.dotfiles/nvim $out/home/${user}/.config/nvim
    ln -s /home/${user}/.dotfiles/wezterm $out/home/${user}/.config/wezterm
    ln -s /home/${user}/.dotfiles/.wezterm.lua $out/home/${user}/.wezterm.lua
    ln -s /home/${user}/.dotfiles/scripts/dotctl $out/home/${user}/.local/bin/dotctl
    ln -s /home/${user}/.dotfiles/.p10k.zsh $out/home/${user}/.p10k.zsh
    ln -s /home/${user}/.dotfiles/rustfmt.toml $out/home/${user}/rustfmt.toml
  '';

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
          "LANG=C.UTF-8"
          "LC_ALL=C.UTF-8"
          "DOTFILES_ROOT=/home/${user}/.dotfiles"
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
    packages = toolsets.workstation;
    description = "Full Linux tool environment from Alex's dotfiles.";
  };

  docker-pocket-knife = mkImage {
    name = "dotfiles-pocket-knife";
    packages = toolsets.pocketKnife;
    description = "Slim repair shell with Git, Neovim, Codex, and core diagnostics.";
  };
}
