{
  config,
  lib,
  pkgs,
  ...
}:
let
  toolsets = import ../../lib/toolsets.nix { inherit lib pkgs; };
in
{
  imports = [ ./core.nix ];

  config = {
    home.packages = toolsets.git;

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
        }
        // lib.optionalAttrs (config.dotfiles.profile == "nixos-wsl") {
          # 1Password owns the Windows OpenSSH agent pipe. Using ssh.exe at
          # Git's configuration layer also covers non-interactive callers such
          # as Codex Desktop, which may not inherit an interactive shell's
          # GIT_SSH_COMMAND environment variable.
          sshCommand = "ssh.exe -o StrictHostKeyChecking=accept-new";
        };
        alias = {
          st = "status -sb";
          ci = "commit";
          br = "branch";
          co = "checkout";
          df = "diff";
          ready = "rebase -i @{u}";
          lg = "log --pretty=format:'%Cred%h%Creset -%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset'";
          standup = "!git log --pretty=format:'%Cred%h%Creset -%Creset %s %Cgreen(%cD) %C(bold blue)<%an>%Creset' --since yesterday --author=\"$(git config user.name)\"";
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
