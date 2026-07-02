#!/bin/bash

DOTFILES_DIR="$HOME/.dotfiles"

usage() {
	cat <<'EOF'
Usage: create-symlinks.sh [options]

Options:
  --posix-only, --unix-only, --linux-only   Only manage Linux/WSL symlinks.
  --windows-only                            Only manage Windows symlinks (requires powershell.exe).
  --no-windows                              Skip Windows symlinks.
  --no-posix                                Skip Linux/WSL symlinks.
  -h, --help                                Show this message.
EOF
}

RUN_POSIX=1
RUN_WINDOWS=1

while [ $# -gt 0 ]; do
	case "$1" in
		--posix-only | --unix-only | --linux-only)
			RUN_POSIX=1
			RUN_WINDOWS=0
			;;
		--windows-only)
			RUN_POSIX=0
			RUN_WINDOWS=1
			;;
		--no-windows)
			RUN_WINDOWS=0
			;;
		--no-posix)
			RUN_POSIX=0
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
	esac
	shift
done

# Define an array of source and target file pairs.
files=(
	"$HOME/.config/nvim:$DOTFILES_DIR/nvim"
	"$HOME/.config/wezterm:$DOTFILES_DIR/wezterm"
	"$HOME/.gitconfig:$DOTFILES_DIR/.gitconfig"
	"$HOME/.p10k.zsh:$DOTFILES_DIR/.p10k.zsh"
	"$HOME/.wezterm.lua:$DOTFILES_DIR/.wezterm.lua"
	"$HOME/.zprofile:$DOTFILES_DIR/.zprofile"
	"$HOME/.zshrc:$DOTFILES_DIR/.zshrc"
	"$HOME/.tool-versions:$DOTFILES_DIR/.tool-versions"
	"$HOME/rustfmt.toml:$DOTFILES_DIR/rustfmt.toml"
)

if [ "$RUN_POSIX" -eq 1 ]; then
	# Backup any existing files that are not symlinks and create symlinks.
	echo "Backing up existing files and creating symlinks..."
	for entry in "${files[@]}"; do
		# Extract the source and target from the entry.
		file="${entry%%:*}"
		target="${entry##*:}"

		# Skip files that are already correctly linked.
		if [ -L "$file" ]; then
			current_link=$(readlink "$file")
			if [ "$current_link" = "$target" ]; then
				echo "Skipping '$file' (already linked)."
				continue
			fi

			if current_realpath=$(readlink -f "$file" 2>/dev/null); then
				if [ "$current_realpath" = "$target" ]; then
					echo "Skipping '$file' (already linked)."
					continue
				fi
			fi
		fi

		# Backup existing files or symlinks if they are not the symlinks we want.
		if [ -e "$file" ] && [ "$(readlink -f "$file")" != "$target" ]; then
			echo "Backing up '$file'..."
			mkdir -p "$HOME/.backup_dotfiles"
			mv "$file" "$HOME/.backup_dotfiles/"
		fi

		# Create any missing parent directories.
		mkdir -p "$(dirname "$file")"

		# Create symlinks if they are not already the symlinks we want.
		if [ "$(readlink -f "$file")" != "$target" ]; then
			ln -sf "$target" "$file"
		fi
	done
	echo "...done! Backups were saved to $HOME/.backup_dotfiles/ and symlinks were created."
fi

create_windows_symlink() {
	local friendly_name="$1"
	local link_expression="$2"
	local target="$3"

	echo "Creating Windows symlink to $friendly_name..."

	local escaped_target=${target//\'/\'\'}
	local ps_script
	ps_script=$(cat <<EOF
\$ErrorActionPreference = 'Stop'
\$linkPath = ${link_expression}
\$targetPath = '${escaped_target}'
if (Test-Path -LiteralPath \$linkPath) {
	Remove-Item -LiteralPath \$linkPath -Recurse -Force
}
New-Item -ItemType SymbolicLink -Path \$linkPath -Target \$targetPath | Out-Null
EOF
)

	if ! powershell.exe -NoLogo -NoProfile -Command "$ps_script" >/dev/null 2>&1; then
		echo "  Skipped: Windows symlink creation requires elevated PowerShell or Developer Mode."
		WINDOWS_SYMLINK_WARNING=1
	else
		echo "...done!"
	fi
}

# If WSL, then create Windows symbolic links in Windows user directory.
if [ "$RUN_WINDOWS" -eq 1 ] && command -v powershell.exe &>/dev/null; then
	WINDOWS_SYMLINK_WARNING=0
	WINDOWS_WSL_DOTFILES_DISTRO="${WINDOWS_WSL_DOTFILES_DISTRO:-${WSL_DISTRO_NAME:-NixOS}}"

	WEZTERM_CONFIG_PATH=$(echo "//wsl.localhost/${WINDOWS_WSL_DOTFILES_DISTRO}${DOTFILES_DIR}/.wezterm.lua" | sed 's/\//\\/g')
	create_windows_symlink "wezterm config file" "Join-Path \$env:USERPROFILE '.wezterm.lua'" "$WEZTERM_CONFIG_PATH"

	WEZTERM_DIR_PATH=$(echo "//wsl.localhost/${WINDOWS_WSL_DOTFILES_DISTRO}${DOTFILES_DIR}/wezterm" | sed 's/\//\\/g')
	create_windows_symlink "wezterm directory" "Join-Path \$env:USERPROFILE '.wezterm'" "$WEZTERM_DIR_PATH"

	NVIM_CONFIG_PATH=$(echo "//wsl.localhost/${WINDOWS_WSL_DOTFILES_DISTRO}${DOTFILES_DIR}/nvim" | sed 's/\//\\/g')
	create_windows_symlink "nvim config directory" "Join-Path \$env:USERPROFILE 'AppData\\Local\\nvim'" "$NVIM_CONFIG_PATH"

	if [ "${WINDOWS_SYMLINK_WARNING:-0}" -eq 1 ]; then
		echo
		echo "Windows symlinks were skipped. Rerun from an elevated Windows PowerShell session or enable Developer Mode to allow symbolic link creation."
	fi
elif [ "$RUN_WINDOWS" -eq 1 ]; then
	echo "Skipping Windows symlink creation (powershell.exe not available)."
fi
