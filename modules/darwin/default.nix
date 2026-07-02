{
  pkgs,
  user,
  inputs,
  self,
  fullName,
  userEmail,
  profile ? "macos",
  ...
}:
{
  system.stateVersion = 6;
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.zsh.enable = true;

  users.users.${user} = {
    name = user;
    home = "/Users/${user}";
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    vim
  ];

  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";
    taps = [
      "stripe/stripe-cli"
    ];
    brews = [
      "stripe/stripe-cli/stripe"
    ];
    casks = [
      "1password-cli"
      "google-cloud-sdk"
      "wezterm"
    ];
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-backup";
  home-manager.extraSpecialArgs = {
    inherit
      inputs
      self
      user
      fullName
      userEmail
      ;
    inherit profile;
  };
  home-manager.users.${user} = {
    imports = [ ../home/default.nix ];
    home.username = user;
    home.homeDirectory = "/Users/${user}";
    dotfiles = {
      inherit
        fullName
        profile
        userEmail
        ;
      userName = user;
    };
  };
}
