{
  config,
  lib,
  pkgs,
  self,
  user,
  fullName,
  userEmail,
  profile ? "generic-linux",
  ...
}:
let
  cfg = config.dotfiles;
  repo = "${config.home.homeDirectory}/.dotfiles";
  isWsl = builtins.elem cfg.profile [
    "nixos-wsl"
    "wsl-ubuntu"
  ];
  optionalPackage = name: lib.optional (builtins.hasAttr name pkgs) (builtins.getAttr name pkgs);
  optionalPackages = lib.concatMap optionalPackage [
    "_1password-cli"
    "azure-cli"
    "dotnet-sdk"
    "google-cloud-sdk"
    "nil"
    "nixfmt"
    "stripe-cli"
    "tlrc"
    "wordnet"
    "zsh-powerlevel10k"
    "zsh-vi-mode"
  ];
  p10kTheme =
    if builtins.hasAttr "zsh-powerlevel10k" pkgs then
      "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
    else
      "";
  zshViMode =
    if builtins.hasAttr "zsh-vi-mode" pkgs then
      "${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
    else
      "";
in
{
  options.dotfiles.profile = lib.mkOption {
    type = lib.types.str;
    default = profile;
    description = "Named dotfiles target profile.";
  };

  config = {
    home.stateVersion = "26.05";
    programs.home-manager.enable = true;
    xdg.enable = true;

    home.sessionVariables =
      {
        EDITOR = "nvim";
        HOMEBREW_NO_ENV_HINTS = "1";
        MS_COG_SVC_SPEECH_SKIP_BINDGEN = "1";
        NEOVIM_SRC_DIR = "${config.home.homeDirectory}/.cache/neovim";
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };
    home.sessionPath = [
      "$HOME/.cache/.bun/bin"
      "$HOME/.bun/bin"
      "$HOME/.cargo/bin"
      "$HOME/bin"
      "$HOME/.local/bin"
      "$HOME/go/bin"
    ];

    home.packages =
      (with pkgs; [
        bun
        cmake
        curl
        fastfetch
        fd
        file
        gcc
        gh
        gnugrep
        gnumake
        gnupg
        go
        helm
        jq
        k9s
        lazygit
        lua
        lynx
        mise
        ninja
        neovim
        nodejs
        openssh
        pkg-config
        procps
        python3
        ripgrep
        cargo
        rustc
        rust-analyzer
        shellcheck
        stylua
        tree
        tree-sitter
        unzip
        wget
        zsh
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

    home.file.".p10k.zsh".source = ../../.p10k.zsh;
    home.file.".tool-versions".source = ../../.tool-versions;
    home.file."rustfmt.toml".source = ../../rustfmt.toml;
    home.file.".local/bin/bootstrap-env-from-1password" = {
      source = ../../bootstrap-env-from-1password;
      executable = true;
    };
    home.file.".local/bin/dotctl" = {
      source = ../../scripts/dotctl;
      executable = true;
    };

    xdg.configFile."mise/config.toml".text = ''
            [settings]
            python.compile = false
          '';

    programs.bat.enable = true;
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    programs.eza = {
      enable = true;
      icons = "always";
      git = true;
    };
    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
      defaultCommand = "fd --hidden --strip-cwd-prefix --exclude .git";
      fileWidgetCommand = "fd --hidden --strip-cwd-prefix --exclude .git";
      changeDirWidgetCommand = "fd --type=d --hidden --strip-cwd-prefix --exclude .git";
      fileWidgetOptions = [ "--preview 'bat -n --color=always --line-range :500 {}'" ];
      changeDirWidgetOptions = [ "--preview 'eza --tree --color=always {} | head -200'" ];
    };
    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.git = {
      enable = true;
      settings = {
        user = {
          name = fullName;
          email = userEmail;
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
          standup = "log --pretty=format:'%Cred%h%Creset -%Creset %s %Cgreen(%cD) %C(bold blue)<%an>%Creset' --since yesterday --author Alex";
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

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      history = {
        path = "${config.home.homeDirectory}/.zsh_history";
        save = 10000;
        size = 10000;
        share = true;
      };
      shellAliases = {
        cat = "bat --paging=never";
        ff = "fastfetch";
        help = "run-help";
        lg = "lazygit";
        ll = "eza --color=always --all --long --git --icons=always --no-time --no-permissions";
        nv = "nvim";
        vi = "nvim";
        vim = "nvim";
        updoot = "dotctl apply --update";
      };
      initContent = ''
                [[ -r "${../../wezterm-shell-integration.sh}" ]] && source "${../../wezterm-shell-integration.sh}"

                : "$NEOVIM_SRC_DIR"

                function chpwd {
                  echo "\x1b]1337;SetUserVar=panetitle=$(echo -n $(basename $(pwd)) | base64)\x07"
                }
                chpwd

                bindkey -v

                [[ -f "${p10kTheme}" ]] && source "${p10kTheme}"
                [[ -f "${zshViMode}" ]] && source "${zshViMode}"
                [[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

                prompt_customprefix() {
                  :
                }
                typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
                  customprefix
                  os_icon
                  dir
                  vcs
                  newline
                  prompt_char
                )

                get_windows_userprofile() {
                  if command -v powershell.exe >/dev/null 2>&1; then
                    powershell.exe -NoLogo -NoProfile -Command '$env:UserProfile' 2>/dev/null && return
                  fi

                  if [[ -x /init && -x /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
                    /init /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -Command '$env:UserProfile' 2>/dev/null && return
                  fi

                  return 1
                }

                if command -v wslpath >/dev/null 2>&1; then
                  windows_userprofile="$(get_windows_userprofile | tr -d '\r')"
                  if [[ -n "$windows_userprofile" ]]; then
                    export WINHOME=$(wslpath -u "$windows_userprofile")
                    export APPDATA="$WINHOME/AppData/Roaming"
                    export DESKTOP="$WINHOME/Desktop"
                    export DOWNLOADS="$WINHOME/Downloads"
                  fi

                  if [[ -d "/mnt/g" ]]; then
                    export GDRIVE="/mnt/g/My Drive"
                    export GBACKUPS="/mnt/g/My Drive/Backups"
                  fi
                fi

                unset -f get_windows_userprofile
                unset windows_userprofile

                if command -v mise >/dev/null 2>&1; then
                  eval "$(mise activate zsh)"
                fi

                setup_1password_ssh_agent() {
                  if [[ -n "$WSL_DISTRO_NAME" ]]; then
                    if command -v ssh.exe >/dev/null 2>&1; then
                      ssh() {
                        command ssh.exe -o StrictHostKeyChecking=accept-new "$@"
                      }
                      scp() {
                        command scp.exe -o StrictHostKeyChecking=accept-new "$@"
                      }
                      sftp() {
                        command sftp.exe -o StrictHostKeyChecking=accept-new "$@"
                      }
                      ssh-add() {
                        command ssh-add.exe "$@"
                      }
                      ssh-agent() {
                        command ssh-agent.exe "$@"
                      }
                      export GIT_SSH_COMMAND="ssh.exe -o StrictHostKeyChecking=accept-new"
                    fi
                    unset SSH_AUTH_SOCK
                    return
                  fi

                  local sock="$HOME/.1password/agent.sock"
                  if [[ -S "$sock" || ! -e "$sock" ]]; then
                    export SSH_AUTH_SOCK="$sock"
                  fi
                }
                setup_1password_ssh_agent

                dotfiles_auth_bootstrap() {
                  if [[ ! -t 0 || ! -t 1 ]]; then
                    return
                  fi

                  local env_script="$HOME/.local/bin/bootstrap-env-from-1password"

                  if command -v op >/dev/null 2>&1; then
                    if ! op whoami >/dev/null 2>&1; then
                      echo "1Password CLI is not signed in. Launching 'op signin'..."
                      eval $(op signin) || echo "1Password CLI signin skipped or failed."
                    fi

                    if op whoami >/dev/null 2>&1 && [[ -x "$env_script" ]]; then
                      "$env_script" --quiet
                    fi
                  fi

                  if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
                    echo "GitHub CLI is not authenticated. Launching 'gh auth login --web'..."
                    gh auth login --web -h github.com || echo "GitHub CLI login skipped or failed."
                  fi
                }

                if [[ $- == *i* && -z "$DOTFILES_AUTH_BOOTSTRAP_DONE" ]]; then
                  export DOTFILES_AUTH_BOOTSTRAP_DONE=1
                  dotfiles_auth_bootstrap
                fi
              '';
    };

    home.activation.linkMutableDotfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            repo="$HOME/.dotfiles"

            if [ ! -d "$repo" ]; then
              echo "Expected dotfiles repo at $HOME/.dotfiles; clone it before relying on linked config files."
              exit 0
            fi

            link_dotfile() {
              source="$1"
              target="$2"

              if [ ! -e "$source" ]; then
                echo "Skipping missing dotfiles source: $source"
                return
              fi

              mkdir -p "$(dirname "$target")"

              if [ -L "$target" ]; then
                current="$(readlink "$target")"
                if [ "$current" = "$source" ]; then
                  return
                fi
                rm "$target"
              elif [ -e "$target" ]; then
                backup="$target.pre-nix-backup"
                index=0
                while [ -e "$backup" ]; do
                  index=$((index + 1))
                  backup="$target.pre-nix-backup.$index"
                done
                mv "$target" "$backup"
                echo "Moved existing $target to $backup"
              fi

              ln -s "$source" "$target"
            }

            link_dotfile "$repo/nvim" "$HOME/.config/nvim"
            link_dotfile "$repo/wezterm" "$HOME/.config/wezterm"
            link_dotfile "$repo/.wezterm.lua" "$HOME/.wezterm.lua"
          '';
  };
}
