{
  pkgs,
  user,
  inputs,
  self,
  toolPkgs,
  profile ? "macos",
  ...
}:
{
  system.stateVersion = 6;
  system.primaryUser = user;
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
    # Keep first macOS adoption non-destructive. Tighten this after every
    # Homebrew package that should remain installed is declared here.
    onActivation.cleanup = "none";
    brews = [
      "stripe-cli"
    ];
    casks = [
      "1password"
      "1password-cli"
      "codex-app"
      "font-bigblue-terminal-nerd-font"
      "gcloud-cli"
      "neovide"
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
      toolPkgs
      ;
    inherit profile;
  };
  home-manager.users.${user} = {
    imports = [ ../home/default.nix ];
    home.username = user;
    home.homeDirectory = "/Users/${user}";
    home.stateVersion = "26.05";
    dotfiles = {
      inherit profile;
    };
  };
}
