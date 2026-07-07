{ config, pkgs, ... }:
let
  cfg = config.dotfiles;
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = with pkgs; [
      git
      lazygit
    ];

    programs.git = {
      enable = true;
      settings = {
        include.path = [
          "~/.config/git/identity"
          "~/.config/git/local"
        ];
        user = {
          useConfigOnly = true;
        };
        core = {
          editor = "nvim";
          pager = "delta";
        };
        alias = {
          st = "status -sb";
          ci = "commit";
          br = "branch";
          co = "checkout";
          df = "diff";
          ready = "rebase -i @{u}";
          lg = "log --pretty=format:'%Cred%h%Creset -%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset'";
          standup = "log --pretty=format:'%Cred%h%Creset -%Creset %s %Cgreen(%cD) %C(bold blue)<%an>%Creset' --since yesterday --author ${cfg.fullName}";
          purr = "pull --rebase";
          whoami = "!echo \"\${GIT_AUTHOR_NAME:-$(git config user.name)} (\${GIT_AUTHOR_EMAIL:-$(git config user.email)})\"";
        };
        delta = {
          navigate = true;
          side-by-side = true;
        };
        init.defaultBranch = "main";
        pull.rebase = false;
        safe.directory = "/neovim";
        credential = {
          "https://github.com".helper = [
            ""
            "!gh auth git-credential"
          ];
          "https://gist.github.com".helper = [
            ""
            "!gh auth git-credential"
          ];
        };
      };
    };
    programs.delta = {
      enable = true;
      enableGitIntegration = true;
    };
  };
}
