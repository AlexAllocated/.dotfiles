# Temporary compatibility rc. Home Manager replaces ~/.zshrc after activation.

[[ -r "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
[[ -r "$HOME/.dotfiles/wezterm-shell-integration.sh" ]] &&
	source "$HOME/.dotfiles/wezterm-shell-integration.sh"

: "${NEOVIM_SRC_DIR:=$HOME/.cache/neovim}"

function chpwd {
	echo "\x1b]1337;SetUserVar=panetitle=$(echo -n "$(basename "$(pwd)")" | base64)\x07"
}
chpwd

bindkey -v

source_first_readable() {
	local file
	for file in "$@"; do
		if [[ -r "$file" ]]; then
			source "$file"
			return 0
		fi
	done
	return 1
}

if command -v brew >/dev/null 2>&1; then
	p10k_theme="$(brew --prefix)/share/powerlevel10k/powerlevel10k.zsh-theme"
	zvm_plugin="$(brew --prefix)/opt/zsh-vi-mode/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
	[[ -r "$p10k_theme" ]] && source "$p10k_theme"
	[[ -r "$zvm_plugin" ]] && source "$zvm_plugin"
else
	source_first_readable \
		"$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme" \
		"/share/zsh-powerlevel10k/powerlevel10k.zsh-theme" \
		"/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme"
	source_first_readable \
		"$HOME/.local/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh" \
		"/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh" \
		"/usr/share/zsh/plugins/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
fi
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

unset -f source_first_readable

setup_1password_ssh_agent() {
	local sock="$HOME/.1password/agent.sock"
	if [[ -S "$sock" || ! -e "$sock" ]]; then
		export SSH_AUTH_SOCK="$sock"
	fi
}
setup_1password_ssh_agent
unset -f setup_1password_ssh_agent

alias cat="bat --paging=never"
alias ff="fastfetch"
alias help="run-help"
alias lg="lazygit"
alias ll="eza --color=always --all --long --git --icons=always --no-time --no-permissions"
alias nv="nvim"
alias vi="nvim"
alias vim="nvim"
if [[ "${DOTFILES_WORKSHOP:-0}" == "1" ]]; then
	alias updoot="dotctl workshop-update"
else
	alias updoot="dotctl apply --update"
fi
