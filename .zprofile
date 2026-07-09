# Compatibility profile for pre-Home Manager and managed macOS bootstrap.

if [[ -n "${DOTFILES_ZPROFILE_LOADED:-}" ]]; then
	return 0
fi
export DOTFILES_ZPROFILE_LOADED=1

dotfiles_append_path() {
	local dir="$1"
	[[ -d "$dir" ]] || return 0
	case ":$PATH:" in
		*":$dir:"*) ;;
		*) export PATH="$PATH:$dir" ;;
	esac
}

dotfiles_load_homebrew() {
	if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
	elif command -v brew >/dev/null 2>&1; then
		eval "$(brew shellenv)"
	elif [[ -x /usr/local/bin/brew ]]; then
		eval "$(/usr/local/bin/brew shellenv)"
	elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
		eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
	fi
}

[[ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]] &&
	source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
[[ -r "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]] &&
	source "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"

dotfiles_load_homebrew

if command -v mise >/dev/null 2>&1; then
	eval "$(mise activate zsh)"
fi

dotfiles_append_path "$HOME/.local/bin"
dotfiles_append_path "$HOME/bin"
dotfiles_append_path "$HOME/.bun/bin"
dotfiles_append_path "$HOME/.cache/.bun/bin"
dotfiles_append_path "$HOME/.cargo/bin"
dotfiles_append_path "$HOME/go/bin"
dotfiles_append_path "$HOME/.volta/bin"

dotfiles_load_homebrew

[[ -r "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

load_dotfiles_env_file() {
	local env_file="$1"
	if [[ -f "$env_file" ]]; then
		set -a
		source "$env_file"
		set +a
	fi
}
load_dotfiles_env_file "$HOME/.dotfiles/.env"

unset -f dotfiles_append_path dotfiles_load_homebrew load_dotfiles_env_file

export EDITOR="${EDITOR:-nvim}"
export HOMEBREW_NO_ENV_HINTS=1
export MS_COG_SVC_SPEECH_SKIP_BINDGEN=1
export NEOVIM_SRC_DIR="${NEOVIM_SRC_DIR:-$HOME/.cache/neovim}"
