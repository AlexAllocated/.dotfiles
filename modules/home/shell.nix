{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  sourceRoot = if cfg.mutableSource != null then cfg.mutableSource else cfg.source;
  optionalPackage = name: lib.optional (builtins.hasAttr name pkgs) (builtins.getAttr name pkgs);
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
  imports = [ ./core.nix ];

  config = {
    home.packages =
      (with pkgs; [
        zsh
      ])
      ++ lib.concatMap optionalPackage [
        "zsh-powerlevel10k"
        "zsh-vi-mode"
      ];

    home.file.".p10k.zsh".source = sourceRoot + "/.p10k.zsh";
    home.file.".tool-versions".source = sourceRoot + "/.tool-versions";
    home.file."rustfmt.toml".source = sourceRoot + "/rustfmt.toml";
    home.file.".local/bin/bootstrap-env-from-1password" = {
      source = sourceRoot + "/bootstrap-env-from-1password";
      executable = true;
    };
    home.file.".local/bin/dotctl" = {
      source = sourceRoot + "/scripts/dotctl";
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
        updoot = "dotctl apply --update";
      };
      initContent = ''
        [[ -r "${sourceRoot}/wezterm-shell-integration.sh" ]] && source "${sourceRoot}/wezterm-shell-integration.sh"

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

        # Shell startup should not authenticate external services. Use explicit
        # commands such as `op`, `gh auth login`, or `dotctl secrets` when
        # credentials need refreshing.
      '';
    };
  };
}
