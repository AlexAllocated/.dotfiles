#!/usr/bin/env bash

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

require_command() {
	if ! command_exists "$1"; then
		printf 'Required command not found: %s\n' "$1" >&2
		return 1
	fi
}

copy_if_changed() {
	local source="$1"
	local destination="$2"
	mkdir -p "$(dirname "$destination")"
	if [[ -f "$destination" ]] && cmp -s "$source" "$destination"; then
		return 0
	fi
	cp "$source" "$destination"
	printf 'Updated Windows integration file: %s\n' "$destination"
}

apply_windows_packages() {
	local source_root="${1:-$REPO_ROOT}"
	local script manifest neovide_config script_windows manifest_windows roaming_windows roaming_linux neovide_target
	[[ -n "${WSL_DISTRO_NAME:-}" ]] || return 0
	require_command powershell.exe
	require_command wslpath
	script="$source_root/scripts/windows/apply-packages.ps1"
	manifest="$source_root/platforms/windows/winget.json"
	neovide_config="$source_root/neovide/windows-wsl.toml"
	[[ -f "$script" ]] || {
		printf 'Windows package reconciler not found: %s\n' "$script" >&2
		return 1
	}
	[[ -f "$manifest" ]] || {
		printf 'WinGet manifest not found: %s\n' "$manifest" >&2
		return 1
	}
	[[ -f "$neovide_config" ]] || {
		printf 'Neovide config not found: %s\n' "$neovide_config" >&2
		return 1
	}
	script_windows="$(wslpath -w "$script")"
	manifest_windows="$(wslpath -w "$manifest")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script_windows" \
		-ManifestPath "$manifest_windows"

	# Bypass packaged-app filesystem virtualization by writing through DrvFs.
	roaming_windows="$(powershell.exe -NoLogo -NoProfile -Command \
		'[Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)' | tr -d '\r')"
	[[ -n "$roaming_windows" ]] || {
		printf 'Could not determine the Windows Roaming AppData directory.\n' >&2
		return 1
	}
	roaming_linux="$(wslpath -u "$roaming_windows")"
	neovide_target="$roaming_linux/neovide/config.toml"
	mkdir -p "$(dirname "$neovide_target")"
	if [[ ! -f "$neovide_target" ]] || ! cmp -s "$neovide_config" "$neovide_target"; then
		cp "$neovide_config" "$neovide_target"
		printf 'Updated Neovide config at %s.\n' "$roaming_windows\\neovide\\config.toml"
	else
		printf 'Neovide config is current.\n'
	fi
}

apply_windows_integration() {
	local source_root="${1:-$REPO_ROOT}"
	local script font_installer configurator desktop_config ssh_forwarder quest_hotspot obs_configurator obs_wallpaper obs_production_mode obs_production_launcher amps_configurator amps_endpoint_configurator amps_source amps_workspace docker_configurator always_on slack_presence slack_presence_launcher vdd_settings sunshine_session sunshine_configurator nvidia_frame_limiter wallpaper_configurator lg_display wallpaper_ultrawide wallpaper_ipad script_windows nvidia_video_effects nvidia_audio_effects
	local font_package font_directory_windows font_installer_windows obs_configurator_windows obs_wallpaper_windows obs_production_mode_windows obs_production_launcher_windows nvidia_frame_limiter_windows amps_configurator_windows amps_source_windows docker_configurator_windows nvidia_video_effects_windows nvidia_audio_effects_windows
	local windows_home local_appdata program_files system_root windows_home_linux local_appdata_linux neovide_windows
	local ssh_forwarder_target ssh_forwarder_target_windows quest_hotspot_target quest_hotspot_target_windows always_on_target always_on_target_windows slack_presence_target slack_presence_target_windows slack_presence_launcher_target
	local vdd_settings_target sunshine_configurator_target sunshine_configurator_target_windows nvidia_frame_limiter_target wallpaper_configurator_target wallpaper_configurator_target_windows lg_display_target lg_display_target_windows wallpaper_directory wallpaper_directory_windows minecraft_vr minecraft_desktop minecraft_graphics powerwash_configurator powerwash_launcher powerwash_configurator_target powerwash_configurator_target_windows flat2vr_configurator flat2vr_configurator_target flat2vr_configurator_target_windows
	[[ -n "${WSL_DISTRO_NAME:-}" ]] || return 0
	require_command nix
	require_command powershell.exe
	require_command python3
	require_command wslpath

	script="$source_root/scripts/windows/apply-wsl-links.ps1"
	font_installer="$source_root/scripts/windows/install-user-fonts.ps1"
	configurator="$source_root/scripts/windows/configure-codex.py"
	desktop_config="$source_root/platforms/windows/codex-desktop.toml"
	ssh_forwarder="$source_root/scripts/windows/apply-wsl-ssh-forward.ps1"
	quest_hotspot="$source_root/scripts/windows/configure-quest-hotspot.ps1"
	obs_configurator="$source_root/scripts/windows/configure-obs.ps1"
	obs_production_mode="$source_root/scripts/windows/obs-production-mode.lua"
	obs_production_launcher="$source_root/scripts/windows/obs-production-frame-limit.vbs"
	nvidia_video_effects="$source_root/scripts/windows/configure-nvidia-video-effects.ps1"
	nvidia_audio_effects="$source_root/scripts/windows/configure-nvidia-audio-effects.ps1"
	obs_wallpaper="$source_root/assets/wallpapers/pixel-meadow-hive-2560x1440.png"
	amps_configurator="$source_root/scripts/windows/configure-amps.ps1"
	amps_endpoint_configurator="$source_root/scripts/windows/configure-amps-endpoints.ps1"
	amps_source="$source_root/packages/amps"
	amps_workspace="$HOME/code/AMPS"
	wallpaper_configurator="$source_root/scripts/windows/configure-wallpapers.ps1"
	lg_display="$source_root/scripts/windows/configure-lg-display.ps1"
	wallpaper_ultrawide="$source_root/assets/wallpapers/pixel-meadow-hive-3440x1440.png"
	wallpaper_ipad="$source_root/assets/wallpapers/pixel-meadow-hive-2732x2048.png"
	docker_configurator="$source_root/scripts/windows/configure-docker-desktop.ps1"
	always_on="$source_root/scripts/windows/configure-always-on.ps1"
	slack_presence="$source_root/scripts/windows/keep-slack-active.ps1"
	slack_presence_launcher="$source_root/scripts/windows/keep-slack-active-hidden.vbs"
	vdd_settings="$source_root/platforms/windows/vdd_settings.xml"
	sunshine_session="$source_root/scripts/windows/set-sunshine-display-session.ps1"
	sunshine_configurator="$source_root/scripts/windows/configure-sunshine-virtual-display.ps1"
	nvidia_frame_limiter="$source_root/scripts/windows/set-nvidia-frame-limit.ps1"
	minecraft_vr="$source_root/scripts/windows/configure-minecraft-vr.ps1"
	minecraft_desktop="$source_root/scripts/windows/configure-minecraft-desktop.ps1"
	minecraft_graphics="$source_root/scripts/windows/minecraft-graphics-assets.ps1"
	powerwash_configurator="$source_root/scripts/windows/configure-powerwash-simulator-2.ps1"
	powerwash_launcher="$source_root/scripts/windows/PowerWashLauncher.cs"
	flat2vr_configurator="$source_root/scripts/windows/configure-flat2vr-mods.ps1"
	for required in "$script" "$font_installer" "$configurator" "$desktop_config" "$ssh_forwarder" "$quest_hotspot" "$obs_configurator" "$obs_production_mode" "$obs_production_launcher" "$nvidia_video_effects" "$nvidia_audio_effects" "$obs_wallpaper" "$amps_configurator" "$amps_endpoint_configurator" "$amps_source/Cargo.toml" "$wallpaper_configurator" "$lg_display" "$wallpaper_ultrawide" "$wallpaper_ipad" "$docker_configurator" "$always_on" "$slack_presence" "$slack_presence_launcher" "$vdd_settings" "$sunshine_session" "$sunshine_configurator" "$nvidia_frame_limiter" "$minecraft_vr" "$minecraft_desktop" "$minecraft_graphics" "$powerwash_configurator" "$powerwash_launcher" "$flat2vr_configurator"; do
		[[ -f "$required" ]] || {
			printf 'Windows integration file not found: %s\n' "$required" >&2
			return 1
		}
	done

	script_windows="$(wslpath -w "$script")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$script_windows" \
		-DistroName "$WSL_DISTRO_NAME" -LinuxHome "$HOME"
	font_package="$(nix build "path:$source_root#bigblue-font" --no-link --print-out-paths)"
	font_directory_windows="$(wslpath -w "$font_package/share/fonts")"
	font_installer_windows="$(wslpath -w "$font_installer")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$font_installer_windows" \
		-FontDirectory "$font_directory_windows"
	mkdir -p "$(dirname "$amps_workspace")"
	if [[ -L "$amps_workspace" ]]; then
		if [[ "$(readlink "$amps_workspace")" != "$amps_source" ]]; then
			ln -sfn "$amps_source" "$amps_workspace"
		fi
	elif [[ -e "$amps_workspace" ]]; then
		printf 'Refusing to replace existing AMPS workspace: %s\n' "$amps_workspace" >&2
		return 1
	else
		ln -s "$amps_source" "$amps_workspace"
	fi
	# Preserve the old development shortcut without replacing a real checkout.
	if [[ -L "$HOME/code/AudioArray" ]]; then
		case "$(readlink "$HOME/code/AudioArray")" in
			"$source_root/packages/audioarray" | "$amps_source" | "$amps_workspace")
				ln -sfn "$amps_workspace" "$HOME/code/AudioArray"
				;;
			*) printf 'Leaving custom AudioArray workspace alias untouched.\n' ;;
		esac
	elif [[ ! -e "$HOME/code/AudioArray" ]]; then
		ln -s "$amps_workspace" "$HOME/code/AudioArray"
	fi
	nvidia_audio_effects_windows="$(wslpath -w "$nvidia_audio_effects")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$nvidia_audio_effects_windows"
	amps_configurator_windows="$(wslpath -w "$amps_configurator")"
	amps_source_windows="$(wslpath -w "$amps_source")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$amps_configurator_windows" \
		-SourceDirectory "$amps_source_windows"
	obs_configurator_windows="$(wslpath -w "$obs_configurator")"
	obs_wallpaper_windows="$(wslpath -w "$obs_wallpaper")"
	obs_production_mode_windows="$(wslpath -w "$obs_production_mode")"
	obs_production_launcher_windows="$(wslpath -w "$obs_production_launcher")"
	nvidia_frame_limiter_windows="$(wslpath -w "$nvidia_frame_limiter")"
	nvidia_video_effects_windows="$(wslpath -w "$nvidia_video_effects")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$nvidia_video_effects_windows"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$obs_configurator_windows" \
		-WallpaperPath "$obs_wallpaper_windows" \
		-ProductionModeScriptPath "$obs_production_mode_windows" \
		-ProductionFrameLauncherPath "$obs_production_launcher_windows" \
		-FrameLimiterPath "$nvidia_frame_limiter_windows"
	docker_configurator_windows="$(wslpath -w "$docker_configurator")"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$docker_configurator_windows" \
		-DistroName "$WSL_DISTRO_NAME"

	windows_home="$(powershell.exe -NoLogo -NoProfile -Command "\$env:USERPROFILE" | tr -d '\r')"
	local_appdata="$(powershell.exe -NoLogo -NoProfile -Command "\$env:LOCALAPPDATA" | tr -d '\r')"
	program_files="$(powershell.exe -NoLogo -NoProfile -Command "\$env:ProgramFiles" | tr -d '\r')"
	system_root="$(powershell.exe -NoLogo -NoProfile -Command "\$env:SystemRoot" | tr -d '\r')"
	if [[ -z "$windows_home" || -z "$local_appdata" || -z "$program_files" || -z "$system_root" ]]; then
		printf 'Could not resolve the Windows profile paths required by the Codex integration.\n' >&2
		return 1
	fi
	windows_home_linux="$(wslpath -u "$windows_home")"
	local_appdata_linux="$(wslpath -u "$local_appdata")"
	vdd_settings_target="$local_appdata_linux/dotfiles/virtual-display/vdd_settings.xml"
	copy_if_changed "$vdd_settings" "$vdd_settings_target"
	copy_if_changed "$sunshine_session" "$local_appdata_linux/dotfiles/set-sunshine-display-session.ps1"
	sunshine_configurator_target="$local_appdata_linux/dotfiles/configure-sunshine-virtual-display.ps1"
	sunshine_configurator_target_windows="$local_appdata\dotfiles\configure-sunshine-virtual-display.ps1"
	nvidia_frame_limiter_target="$local_appdata_linux/dotfiles/set-nvidia-frame-limit.ps1"
	copy_if_changed "$sunshine_configurator" "$sunshine_configurator_target"
	copy_if_changed "$nvidia_frame_limiter" "$nvidia_frame_limiter_target"
	neovide_windows="$program_files\\Neovide\\neovide.exe"
	[[ -f "$(wslpath -u "$neovide_windows")" ]] || {
		printf 'Neovide executable not found after Windows package reconciliation: %s\n' "$neovide_windows" >&2
		return 1
	}
	copy_if_changed "$source_root/scripts/windows/open-in-nvim.ps1" "$local_appdata_linux/NvimWSL/open-in-nvim.ps1"
	copy_if_changed "$source_root/scripts/windows/open-in-neovide.ps1" "$local_appdata_linux/NeovideWSL/open-in-neovide.ps1"
	ssh_forwarder_target="$local_appdata_linux/dotfiles/apply-wsl-ssh-forward.ps1"
	ssh_forwarder_target_windows="$local_appdata\\dotfiles\\apply-wsl-ssh-forward.ps1"
	copy_if_changed "$ssh_forwarder" "$ssh_forwarder_target"
	powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$ssh_forwarder_target_windows" \
		-Mode Ensure -DistroName "$WSL_DISTRO_NAME"
	# The single-quoted expression is evaluated by PowerShell, not Bash.
	# shellcheck disable=SC2016
	if [[ "$(powershell.exe -NoLogo -NoProfile -Command '$env:COMPUTERNAME' | tr -d '\r')" == "TRACER" ]]; then
		quest_hotspot_target="$local_appdata_linux/dotfiles/configure-quest-hotspot.ps1"
		quest_hotspot_target_windows="$local_appdata\\dotfiles\\configure-quest-hotspot.ps1"
		always_on_target="$local_appdata_linux/dotfiles/configure-always-on.ps1"
		always_on_target_windows="$local_appdata\\dotfiles\\configure-always-on.ps1"
		slack_presence_target="$local_appdata_linux/dotfiles/keep-slack-active.ps1"
		slack_presence_target_windows="$local_appdata\\dotfiles\\keep-slack-active.ps1"
		slack_presence_launcher_target="$local_appdata_linux/dotfiles/keep-slack-active-hidden.vbs"
		wallpaper_configurator_target="$local_appdata_linux/dotfiles/configure-wallpapers.ps1"
		wallpaper_configurator_target_windows="$local_appdata\\dotfiles\\configure-wallpapers.ps1"
		lg_display_target="$local_appdata_linux/dotfiles/configure-lg-display.ps1"
		lg_display_target_windows="$local_appdata\\dotfiles\\configure-lg-display.ps1"
		wallpaper_directory="$local_appdata_linux/dotfiles/wallpapers"
		wallpaper_directory_windows="$local_appdata\\dotfiles\\wallpapers"
		copy_if_changed "$quest_hotspot" "$quest_hotspot_target"
		copy_if_changed "$always_on" "$always_on_target"
		copy_if_changed "$slack_presence" "$slack_presence_target"
		copy_if_changed "$slack_presence_launcher" "$slack_presence_launcher_target"
		copy_if_changed "$wallpaper_configurator" "$wallpaper_configurator_target"
		copy_if_changed "$lg_display" "$lg_display_target"
		copy_if_changed "$minecraft_vr" "$local_appdata_linux/dotfiles/configure-minecraft-vr.ps1"
		copy_if_changed "$minecraft_desktop" "$local_appdata_linux/dotfiles/configure-minecraft-desktop.ps1"
		copy_if_changed "$minecraft_graphics" "$local_appdata_linux/dotfiles/minecraft-graphics-assets.ps1"
		powerwash_configurator_target="$local_appdata_linux/dotfiles/configure-powerwash-simulator-2.ps1"
		powerwash_configurator_target_windows="$local_appdata\\dotfiles\\configure-powerwash-simulator-2.ps1"
		flat2vr_configurator_target="$local_appdata_linux/dotfiles/configure-flat2vr-mods.ps1"
		flat2vr_configurator_target_windows="$local_appdata\\dotfiles\\configure-flat2vr-mods.ps1"
		copy_if_changed "$powerwash_configurator" "$powerwash_configurator_target"
		copy_if_changed "$powerwash_launcher" "$local_appdata_linux/dotfiles/PowerWashLauncher.cs"
		copy_if_changed "$flat2vr_configurator" "$flat2vr_configurator_target"
		copy_if_changed "$wallpaper_ultrawide" "$wallpaper_directory/pixel-meadow-hive-3440x1440.png"
		copy_if_changed "$wallpaper_ipad" "$wallpaper_directory/pixel-meadow-hive-2732x2048.png"
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$quest_hotspot_target_windows" -Mode Ensure
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$lg_display_target_windows"
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$wallpaper_configurator_target_windows" \
			-Mode Ensure \
			-UltrawidePath "$wallpaper_directory_windows\\pixel-meadow-hive-3440x1440.png" \
			-IpadPath "$wallpaper_directory_windows\\pixel-meadow-hive-2732x2048.png"
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \
			"$sunshine_configurator_target_windows" -Mode Ensure
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$always_on_target_windows"
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$slack_presence_target_windows" -Mode Ensure
		if powershell.exe -NoLogo -NoProfile -Command \
			'if (Get-Process -Name "PowerWash Simulator 2" -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }'; then
			printf 'PowerWash Simulator 2 is running; deferring its display-layout reconciliation until the next apply.\n'
		else
			powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \
				"$powerwash_configurator_target_windows" -Mode Ensure
		fi
		powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \
			"$flat2vr_configurator_target_windows" -Mode Ensure
	fi

	mkdir -p "$HOME/.codex/sqlite"
	python3 "$configurator" \
		--config "$windows_home_linux/.codex/config.toml" \
		--desktop-config "$desktop_config" \
		--linux-home "$HOME" \
		--neovim-script "$local_appdata\\NvimWSL\\open-in-nvim.ps1" \
		--neovim-icon "$local_appdata\\NvimWSL\\NvimWSL.exe" \
		--neovide-script "$local_appdata\\NeovideWSL\\open-in-neovide.ps1" \
		--neovide-icon "$neovide_windows" \
		--powershell "$system_root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
}

trap_remove_on_exit() {
	local path="$1"
	local cleanup
	printf -v cleanup 'rm -rf -- %q' "$path"
	# Expand now so function-local paths remain available when EXIT fires.
	# shellcheck disable=SC2064
	trap "$cleanup" EXIT
}

is_nixos() {
	[[ -f /etc/NIXOS ]]
}

detect_profile() {
	if [[ "$(uname -s)" == "Darwin" ]]; then
		if [[ "$(uname -m)" != "arm64" ]]; then
			printf 'Unsupported platform: only Apple Silicon macOS is supported.\n' >&2
			return 2
		elif ! command_exists nix; then
			printf 'macos-managed\n'
		else
			printf 'macos\n'
		fi
	elif [[ "${WSL_DISTRO_NAME:-}" == Ubuntu* ]]; then
		printf 'ubuntu-wsl\n'
	elif is_nixos; then
		case "$(hostname)" in
			tracer) printf 'tracer\n' ;;
			*) printf 'chev-desktop\n' ;;
		esac
	else
		printf 'linux\n'
	fi
}

flake_ref_for_profile() {
	local profile="$1"
	local source_root="${2:-$REPO_ROOT}"
	case "$profile" in
		ubuntu-wsl) printf 'path:%s#ubuntu-wsl\n' "$source_root" ;;
		tracer) printf 'path:%s#tracer\n' "$source_root" ;;
		# The native target includes a machine-generated, gitignored ESP PARTUUID.
		# path: semantics deliberately include it in every rebuild.
		chev-desktop) printf 'path:%s#chev-desktop\n' "$source_root" ;;
		linux) printf 'path:%s#linux\n' "$source_root" ;;
		macos) printf 'path:%s#macos-arm64\n' "$source_root" ;;
		darwin-macos) printf 'path:%s#macos-arm64\n' "$source_root" ;;
		*)
			printf 'Profile does not have a Nix flake output: %s\n' "$profile" >&2
			return 2
			;;
	esac
}

backup_path() {
	local path="$1"
	local backup_dir="$HOME/.backup_dotfiles"
	local stamp
	stamp="$(date +%Y%m%d%H%M%S)"
	mkdir -p "$backup_dir"
	mv "$path" "$backup_dir/$(basename "$path").$stamp"
	printf 'Backed up %s to %s\n' "$path" "$backup_dir/$(basename "$path").$stamp"
}

link_path() {
	local target="$1"
	local source="$2"
	if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
		return 0
	fi
	if [[ -e "$target" || -L "$target" ]]; then
		backup_path "$target"
	fi
	mkdir -p "$(dirname "$target")"
	ln -s "$source" "$target"
	printf 'Linked %s -> %s\n' "$target" "$source"
}

write_profile_marker() {
	mkdir -p "$HOME/.local/share/dotfiles"
	printf '%s\n' "$1" >"$HOME/.local/share/dotfiles/profile"
}

git_identity_path() {
	printf '%s/.config/git/identity\n' "$HOME"
}

git_config_value() {
	local key="$1"
	local file="${2:-}"
	command_exists git || return 0
	if [[ -n "$file" ]]; then
		git config --file "$file" --get "$key" 2>/dev/null || true
	else
		git config --global --get "$key" 2>/dev/null || true
	fi
}

write_git_identity() {
	local name="$1"
	local email="$2"
	local identity
	identity="$(git_identity_path)"
	mkdir -p "$(dirname "$identity")"
	{
		printf '[user]\n'
		printf '\tname = %s\n' "$name"
		printf '\temail = %s\n' "$email"
	} >"$identity"
	chmod 600 "$identity"
	printf 'Wrote Git identity to %s\n' "$identity"
}

default_identity_name() {
	local name
	name="$(git_config_value user.name)"
	if [[ -z "$name" ]] && command_exists id; then
		name="$(id -F 2>/dev/null || true)"
	fi
	[[ -n "$name" ]] || name="$(id -un)"
	printf '%s\n' "$name"
}

ensure_git_identity() {
	local identity existing_name existing_email name email default_name default_email
	identity="$(git_identity_path)"
	existing_name="$(git_config_value user.name "$identity")"
	existing_email="$(git_config_value user.email "$identity")"
	if [[ -n "$existing_name" && -n "$existing_email" ]]; then
		return 0
	fi
	default_name="${DOTFILES_GIT_NAME:-$(default_identity_name)}"
	default_email="${DOTFILES_GIT_EMAIL:-$(git_config_value user.email)}"
	if [[ -n "${DOTFILES_GIT_NAME:-}" && -n "${DOTFILES_GIT_EMAIL:-}" ]]; then
		write_git_identity "$DOTFILES_GIT_NAME" "$DOTFILES_GIT_EMAIL"
		return 0
	fi
	if [[ ! -t 0 || ! -t 1 ]]; then
		printf 'Git identity is not configured at %s.\n' "$identity" >&2
		printf 'Run interactively or set DOTFILES_GIT_NAME and DOTFILES_GIT_EMAIL.\n' >&2
		return 1
	fi
	printf 'Git author name [%s]: ' "$default_name"
	IFS= read -r name
	[[ -n "$name" ]] || name="$default_name"
	while [[ -z "${email:-}" ]]; do
		if [[ -n "$default_email" ]]; then
			printf 'Git author email [%s]: ' "$default_email"
		else
			printf 'Git author email: '
		fi
		IFS= read -r email
		[[ -n "$email" ]] || email="$default_email"
	done
	write_git_identity "$name" "$email"
}

print_repo_status() {
	if command_exists git && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf 'Repository changes after update/apply:\n'
		git -C "$REPO_ROOT" status --short
	fi
}
