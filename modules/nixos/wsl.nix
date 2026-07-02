{
  lib,
  pkgs,
  user,
  fullName,
  ...
}:
{
  system.stateVersion = "26.05";
  networking.hostName = "nixos-wsl";
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      user
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  programs.zsh.enable = true;
  security.sudo.wheelNeedsPassword = false;

  users.users.${user} = {
    isNormalUser = true;
    description = fullName;
    home = "/home/${user}";
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
    ];
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    nano
    vim
    wget
  ];

  wsl = {
    enable = true;
    defaultUser = user;
    useWindowsDriver = true;
    startMenuLaunchers = true;
    interop = {
      register = true;
      includePath = true;
    };
    ssh-agent = {
      enable = true;
      users = [ user ];
    };
    wslConf = {
      automount = {
        enabled = true;
        root = "/mnt";
        options = "metadata,umask=22,fmask=11";
        mountFsTab = false;
      };
      boot.systemd = true;
      interop = {
        enabled = true;
        appendWindowsPath = true;
      };
      network = {
        generateHosts = true;
        generateResolvConf = true;
        hostname = "nixos-wsl";
      };
      user.default = user;
    };
  };
}
