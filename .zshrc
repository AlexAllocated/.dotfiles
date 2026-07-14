# Temporary compatibility rc. Home Manager replaces ~/.zshrc after activation.

[[ -r "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
[[ -r "$HOME/.dotfiles/wezterm-shell-integration.sh" ]] &&
	source "$HOME/.dotfiles/wezterm-shell-integration.sh"

: "${NEOVIM_SRC_DIR:=$HOME/.cache/neovim}"

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
	brew_prefix="$(brew --prefix)"
	p10k_theme="$brew_prefix/share/powerlevel10k/powerlevel10k.zsh-theme"
	zvm_plugin="$brew_prefix/opt/zsh-vi-mode/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
	zsh_autosuggestions="$brew_prefix/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
	zsh_syntax_highlighting="$brew_prefix/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
	[[ -r "$p10k_theme" ]] && source "$p10k_theme"
	[[ -r "$zsh_autosuggestions" ]] && source "$zsh_autosuggestions"
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
	zsh_syntax_highlighting=""
fi
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

dotfiles_update_pane_title() {
	if (( $+functions[__wezterm_set_user_var] )); then
		__wezterm_set_user_var panetitle "${PWD:t}"
	fi
}
precmd_functions+=(dotfiles_update_pane_title)

unset -f source_first_readable
unset brew_prefix p10k_theme zvm_plugin zsh_autosuggestions

setup_1password_ssh_agent() {
	local sock="$HOME/.1password/agent.sock"
	if [[ -S "$sock" || ! -e "$sock" ]]; then
		export SSH_AUTH_SOCK="$sock"
	fi
}
setup_1password_ssh_agent
unset -f setup_1password_ssh_agent

if command -v zoxide >/dev/null 2>&1; then
	eval "$(zoxide init zsh)"
fi

if command -v direnv >/dev/null 2>&1; then
	eval "$(direnv hook zsh)"
fi

if command -v brew >/dev/null 2>&1; then
	fzf_shell_dir="$(brew --prefix fzf 2>/dev/null)/shell"
	[[ -r "$fzf_shell_dir/completion.zsh" ]] && source "$fzf_shell_dir/completion.zsh"
	[[ -r "$fzf_shell_dir/key-bindings.zsh" ]] && source "$fzf_shell_dir/key-bindings.zsh"
	unset fzf_shell_dir
fi

[[ -n "${zsh_syntax_highlighting:-}" && -r "$zsh_syntax_highlighting" ]] && source "$zsh_syntax_highlighting"
unset zsh_syntax_highlighting

alias cat="bat --paging=never"
alias ff="fastfetch"
alias help="run-help"
alias lg="lazygit"
alias ll="eza --color=always --all --long --git --icons=always --no-time --no-permissions"
alias nv="nvim"
alias vi="nvim"
alias vim="nvim"
alias updoot="dotctl apply --update"
