#!/usr/bin/env bash
set -euo pipefail

NEOVIM_SRC_DIR="${HOME}/.cache/neovim"
UPDATE_TIMESTAMP_FILE="${HOME}/.last_update_check"
NEOVIM_SOURCE_MESSAGE=""

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
	SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
	SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
	[[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
REPO_ROOT="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

log() {
	printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$@"
}

run_step() {
	local title="$1"
	shift
	if (($# == 0)); then
		fail "run_step requires a command to execute"
	fi
	log "==> ${title}"
	if "$@"; then
		log "[DONE] ${title}"
	else
		local status=$?
		log "[FAIL] ${title}"
		exit "$status"
	fi
}

fail() {
	printf '\nERROR: %s\n' "$@" >&2
	exit 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

require_command() {
	if ! command_exists "$1"; then
		fail "$2"
	fi
}

confirm_sudo() {
	if ! command_exists sudo; then
		fail "sudo is required. Please install sudo and rerun."
	fi
	if ! sudo -n true >/dev/null 2>&1; then
		log "sudo access is required. You may be prompted for your password."
	fi
	if ! sudo -v; then
		fail "Unable to obtain sudo credentials."
	fi
}

apt_get() {
	sudo env \
		DEBIAN_FRONTEND=noninteractive \
		APT_LISTCHANGES_FRONTEND=none \
		NEEDRESTART_MODE=a \
		apt-get -y \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		"$@"
}

ensure_network() {
	local target="https://github.com"
	if command_exists curl; then
		if ! curl -fsSL --connect-timeout 10 --max-time 20 "$target" >/dev/null; then
			fail "Network check failed for ${target}. Please ensure internet connectivity."
		fi
		return
	fi

	if command_exists wget; then
		if ! wget -q --timeout=20 --tries=1 "$target" -O /dev/null; then
			fail "Network check failed for ${target}. Please ensure internet connectivity."
		fi
		return
	fi

	fail "Neither curl nor wget is available for network checks. Please install curl and rerun."
}

windows_symlinks_up_to_date() {
	if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
		return 0
	fi

	if ! command_exists powershell.exe; then
		return 1
	fi

	local dotfiles_dir="${HOME}/.dotfiles"
	local wezterm_config_target
	local wezterm_dir_target
	local nvim_config_target

	if ! wezterm_config_target=$(wslpath -w "${dotfiles_dir}/.wezterm.lua" 2>/dev/null); then
		return 1
	fi
	if ! wezterm_dir_target=$(wslpath -w "${dotfiles_dir}/wezterm" 2>/dev/null); then
		return 1
	fi
	if ! nvim_config_target=$(wslpath -w "${dotfiles_dir}/nvim" 2>/dev/null); then
		return 1
	fi

	local ps_tmp
	ps_tmp="$(mktemp)"
	local ps_script="${ps_tmp}.ps1"

	cat >"${ps_script}" <<'EOF_PS'
param(
   [string]$WeztermConfigTarget,
   [string]$WeztermDirTarget,
   [string]$NvimConfigTarget
)

$ErrorActionPreference = 'Stop'
$needsUpdate = $false

function Normalize-Target {
   param([string]$Path)

   if ($null -eq $Path) {
      return $null
   }

   if ($Path.StartsWith('UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
      $Path = '\\' + $Path.Substring(4)
   }

   return $Path.TrimEnd('\')
}

function Check-Link {
   param(
      [string]$Name,
      [string]$LinkPath,
      [string]$ExpectedTarget
   )

   if (-not (Test-Path -LiteralPath $LinkPath)) {
      Write-Host ("Missing symlink: {0}" -f $Name)
      $script:needsUpdate = $true
      return
   }

   $item = Get-Item -LiteralPath $LinkPath -Force
   if (-not ($item.PSObject.Properties.Name -contains 'Target')) {
      Write-Host ("Unable to determine target for {0}" -f $Name)
      $script:needsUpdate = $true
      return
   }

   $target = $item.Target
   if ($null -eq $target) {
      Write-Host ("Null target for {0}" -f $Name)
      $script:needsUpdate = $true
      return
   }

   if ($target -is [Array]) {
      $target = $target[0]
   }

   $normalizedActual = Normalize-Target $target
   $normalizedExpected = Normalize-Target $ExpectedTarget

   if (-not [string]::Equals($normalizedActual, $normalizedExpected, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Host ("Target mismatch for {0}. Current: {1}" -f $Name, $target)
      $script:needsUpdate = $true
   }
}

$weztermConfigLink = Join-Path $env:USERPROFILE '.wezterm.lua'
$weztermDirLink = Join-Path $env:USERPROFILE '.wezterm'
$nvimConfigLink = Join-Path $env:LOCALAPPDATA 'nvim'

Check-Link 'WezTerm config file' $weztermConfigLink $WeztermConfigTarget
Check-Link 'WezTerm directory' $weztermDirLink $WeztermDirTarget
Check-Link 'Neovim config directory' $nvimConfigLink $NvimConfigTarget

if ($needsUpdate) {
   exit 1
}

exit 0
EOF_PS

	local ps_path
	ps_path=$(wslpath -w "${ps_script}")

	if powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "${ps_path}" "${wezterm_config_target}" "${wezterm_dir_target}" "${nvim_config_target}"; then
		rm -f "${ps_script}"
		rm -f "${ps_tmp}"
		return 0
	fi

	rm -f "${ps_script}"
	rm -f "${ps_tmp}"
	return 1
}

launch_windows_symlink_terminal() {
	if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
		return
	fi

	if ! command_exists powershell.exe; then
		log "powershell.exe not found; skipping elevated Windows symlink helper."
		return
	fi

	if windows_symlinks_up_to_date; then
		log "Windows symlinks already configured; skipping elevated helper."
		return
	fi

	local repo_quoted
	repo_quoted=$(printf '%q' "${REPO_ROOT}")

	local wsl_script
	wsl_script="$(mktemp)"
	cat >"${wsl_script}" <<EOF_WSL
#!/usr/bin/env bash
set -euo pipefail
trap 'rm -f "\$0"' EXIT
cd ${repo_quoted}
./create-symlinks.sh --windows-only
exit "\$?"
EOF_WSL
	chmod +x "${wsl_script}"

	local wsl_script_ps
	wsl_script_ps=$(printf '%s' "${wsl_script}" | sed "s/'/''/g")
	local distribution_ps
	distribution_ps=$(printf '%s' "${WSL_DISTRO_NAME}" | sed "s/'/''/g")

	local ps_tmp
	ps_tmp="$(mktemp)"
	local ps_script="${ps_tmp}.ps1"

	cat >"${ps_script}" <<'EOF_PS'
$ErrorActionPreference = 'Stop'
$distribution = '__DISTRO__'
$symlinkScript = '__WSL_SCRIPT__'
$wslExe = '__WSL_EXE__'
if (-not (Test-Path -Path $wslExe)) {
	Write-Error "wsl.exe not found at $wslExe"
	exit 1
}
$arguments = @('-d', $distribution, '--', '/bin/bash', $symlinkScript)
Write-Host ('WSL args: {0}' -f ($arguments -join ' '))
$process = Start-Process -FilePath $wslExe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
$exitCode = $process.ExitCode
if ($exitCode -ne 0) {
	Write-Host ('Windows symlink setup failed with exit code {0}' -f $exitCode)
	Read-Host 'Press Enter to close...'
}
exit $exitCode
EOF_PS

	local wsl_exe_win='C:\Windows\System32\wsl.exe'
	local wsl_exe_ps=${wsl_exe_win//\/\\/}

	DISTRIBUTION="${distribution_ps}" WSL_SCRIPT_PS="${wsl_script_ps}" WSL_EXE_PS="${wsl_exe_ps}" PS_SCRIPT="${ps_script}" python - <<'PY_PS'
import os
from pathlib import Path
ps_path = Path(os.environ['PS_SCRIPT'])
text = ps_path.read_text()
text = text.replace('__DISTRO__', os.environ['DISTRIBUTION'])
text = text.replace('__WSL_SCRIPT__', os.environ['WSL_SCRIPT_PS'])
text = text.replace('__WSL_EXE__', os.environ['WSL_EXE_PS'])
ps_path.write_text(text)
PY_PS

	local ps_path
	ps_path=$(wslpath -w "${ps_script}")

	if powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "${ps_path}"; then
		log "Windows symlink helper launched. Approve the UAC prompt to finish setup."
	else
		local ps_status=$?
		log "Unable to launch elevated Windows PowerShell automatically (exit code: ${ps_status}). Run manually:"
		log "  wsl.exe -d ${WSL_DISTRO_NAME} -- bash -lc 'cd ${REPO_ROOT} && ./create-symlinks.sh --windows-only'"
		rm -f "${wsl_script}"
	fi

	rm -f "${ps_script}"
}

install_terminfo() {
	local tempfile
	tempfile="$(mktemp)"
	trap 'tmp="${tempfile:-}"; [[ -n "$tmp" ]] && rm -f "$tmp"' RETURN
	if command_exists curl; then
		curl -fsSL -o "$tempfile" https://raw.githubusercontent.com/wez/wezterm/main/termwiz/data/wezterm.terminfo
	elif command_exists wget; then
		wget -q -O "$tempfile" https://raw.githubusercontent.com/wez/wezterm/main/termwiz/data/wezterm.terminfo
	else
		fail "Neither curl nor wget is available to download WezTerm terminfo."
	fi
	/usr/bin/tic -x -o "$HOME/.terminfo" "$tempfile"
}

link_dotfiles() {
	(
		cd "$REPO_ROOT"
		bash "./create-symlinks.sh" "$@"
	)
}

brew_taps() {
	brew tap jesseduffield/lazygit >/dev/null
	brew tap oven-sh/bun >/dev/null
	brew tap wez/wezterm-linuxbrew >/dev/null
	if [[ "$platform" == "macos" ]]; then
		brew tap stripe/stripe-cli >/dev/null
	fi
}

brew_trust_taps() {
	if ! brew trust --help >/dev/null 2>&1; then
		return 0
	fi

	local taps=(
		jesseduffield/lazygit
		oven-sh/bun
		wez/wezterm-linuxbrew
	)

	if [[ "$platform" == "macos" ]] || brew tap | grep -Fxq "stripe/stripe-cli"; then
		taps+=(stripe/stripe-cli)
	fi
	if brew tap | grep -Fxq "wezterm/wezterm-linuxbrew"; then
		taps+=(wezterm/wezterm-linuxbrew)
	fi

	brew trust --tap "${taps[@]}" >/dev/null
}

brew_cleanup_all() {
	brew cleanup -s --prune=all --verbose
}

brew_upgrade_casks() {
	brew upgrade --cask --yes --verbose 2>/dev/null || true
}

install_stripe_cli_ubuntu() {
	local keyring="/usr/share/keyrings/stripe.gpg"
	local repo_file="/etc/apt/sources.list.d/stripe.list"
	local repo_entry="deb [signed-by=${keyring}] https://packages.stripe.dev/stripe-cli-debian-local stable main"

	log "Refreshing Stripe CLI apt signing key"
	curl -fsSL https://packages.stripe.dev/api/security/keypair/stripe-cli-gpg/public | gpg --dearmor | sudo tee "$keyring" >/dev/null

	if [[ ! -d "/etc/apt/sources.list.d" ]]; then
		sudo mkdir -p /etc/apt/sources.list.d
	fi

	echo "$repo_entry" | sudo tee "$repo_file" >/dev/null

	apt_get update
	apt_get install stripe
}

install_1password_cli_ubuntu() {
	local keyring="/usr/share/keyrings/1password-archive-keyring.gpg"
	local repo_file="/etc/apt/sources.list.d/1password.list"
	local repo_entry="deb [signed-by=${keyring}] https://downloads.1password.com/linux/debian/amd64 stable main"

	log "Refreshing 1Password CLI apt signing key"
	curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor | sudo tee "$keyring" >/dev/null

	if [[ ! -d "/etc/apt/sources.list.d" ]]; then
		sudo mkdir -p /etc/apt/sources.list.d
	fi

	echo "$repo_entry" | sudo tee "$repo_file" >/dev/null

	sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22
	curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null

	sudo mkdir -p /etc/debsig/trust.d
	curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.gpg | gpg --dearmor | sudo tee /etc/debsig/trust.d/1password-archive-keyring.gpg >/dev/null

	apt_get update
	apt_get install 1password-cli
}

install_google_cloud_cli_ubuntu() {
	local keyring="/usr/share/keyrings/cloud.google.gpg"
	local repo_file="/etc/apt/sources.list.d/google-cloud-sdk.list"
	local repo_entry="deb [signed-by=${keyring}] https://packages.cloud.google.com/apt cloud-sdk main"

	log "Refreshing Google Cloud CLI apt signing key"
	curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor | sudo tee "$keyring" >/dev/null

	if [[ ! -d "/etc/apt/sources.list.d" ]]; then
		sudo mkdir -p /etc/apt/sources.list.d
	fi

	echo "$repo_entry" | sudo tee "$repo_file" >/dev/null

	apt_get update
	apt_get install google-cloud-cli
}

mise_use_global() {
	mise use --global --yes "$1"
}

mise_install_all() {
	mise install --yes
	mise upgrade --yes
}

mise_configure_runtime_settings() {
	mise settings --yes set python.compile false
}

mise_doctor_check() {
	if ! mise doctor; then
		printf 'mise doctor reported issues. Please resolve them and rerun.\n' >&2
		return 1
	fi
}

bun_install_agents() {
	bun install --global "$@"
}

bun_update_agents() {
	bun install --global "$@" || log "bun install for coding agents failed; continuing."
}

bun_global_has_package() {
	local package="$1"
	NO_COLOR=1 bun pm ls --global 2>/dev/null | grep -Fq "${package}@"
}

ensure_windows_ssh_directory() {
	if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
		return 0
	fi

	if ! command_exists powershell.exe; then
		log "powershell.exe not available; cannot prepare Windows SSH directory."
		return 0
	fi

	local win_home
	win_home="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
	if [[ -z "$win_home" ]]; then
		log "Unable to resolve Windows user profile; skipping SSH directory preparation."
		return 0
	fi

	local wsl_home
	if ! wsl_home="$(wslpath -u "$win_home" 2>/dev/null)"; then
		log "wslpath failed to convert Windows profile path (${win_home}); skipping SSH directory preparation."
		return 0
	fi

	local ssh_dir="${wsl_home}/.ssh"
	if [[ ! -d "$ssh_dir" ]]; then
		mkdir -p "$ssh_dir"
	fi
	if [[ ! -f "${ssh_dir}/known_hosts" ]]; then
		touch "${ssh_dir}/known_hosts"
	fi

	return 0
}

configure_1password_ssh_agent() {
	if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
		ensure_windows_ssh_directory
		return 0
	fi

	local sock_link="$HOME/.1password/agent.sock"
	mkdir -p "${sock_link%/*}"

	local target=""
	if [[ "$platform" == "macos" ]]; then
		target="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
	elif [[ "$platform" == "ubuntu" ]]; then
		target="$HOME/.config/1Password/ssh/agent.sock"
	else
		return 0
	fi

	ln -snf "$target" "$sock_link"

	return 0
}

sync_neovim_sources() {
	NEOVIM_SOURCE_MESSAGE=""
	neovim_build_needed=1
	prev_commit=""
	new_commit=""
	if [[ -d "${NEOVIM_SRC_DIR}/.git" ]]; then
		if ! prev_commit="$(git -C "${NEOVIM_SRC_DIR}" rev-parse HEAD 2>/dev/null)"; then
			prev_commit=""
		fi
		git -C "${NEOVIM_SRC_DIR}" fetch --tags --prune --force
		git -C "${NEOVIM_SRC_DIR}" reset --hard origin/master
		new_commit="$(git -C "${NEOVIM_SRC_DIR}" rev-parse HEAD)"
		if [[ -n "$prev_commit" && "$prev_commit" == "$new_commit" ]]; then
			neovim_build_needed=0
			NEOVIM_SOURCE_MESSAGE="Neovim source already at ${new_commit}; skipping rebuild/install."
		else
			NEOVIM_SOURCE_MESSAGE="Neovim source updated to ${new_commit} (was ${prev_commit:-unknown}); rebuilding."
		fi
	else
		rm -rf "${NEOVIM_SRC_DIR}"
		git clone https://github.com/neovim/neovim.git "${NEOVIM_SRC_DIR}"
		new_commit="$(git -C "${NEOVIM_SRC_DIR}" rev-parse HEAD)"
		NEOVIM_SOURCE_MESSAGE="Cloned Neovim sources at ${new_commit}; building."
	fi
}

neovim_build_from_source() {
	require_command ninja "'ninja' not found; install it via Homebrew (brew install ninja) or system packages."
	require_command cmake "'cmake' not found; install it via Homebrew (brew install cmake) or system packages."
	pushd "${NEOVIM_SRC_DIR}" >/dev/null
	export CMAKE_GENERATOR=Ninja
	export DEPS_CMAKE_GENERATOR=Ninja
	export CMAKE_MAKE_PROGRAM="$(command -v ninja)"
	rm -rf build .deps
	cmake -S cmake.deps -B .deps -G Ninja
	cmake --build .deps
	cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
	cmake --build build
	sudo cmake --install build
	popd >/dev/null
	if [[ "$platform" == "ubuntu" ]]; then
		sudo ldconfig
	fi
}

bootstrap_neovim() {
	if ! command_exists nvim; then
		log "Skipping Neovim bootstrap. 'nvim' not found in PATH."
		return
	fi

	log "Priming Neovim plugins (Lazy sync, MasonUpdate, TSUpdateSync)"
	if ! nvim --headless "+set nomore" "+Lazy! sync" "+MasonUpdate" "+TSUpdateSync" +qa; then
		fail "Neovim plugin bootstrap failed."
	fi
}

platform=""
case "$(uname -s)" in
Darwin)
	platform="macos"
	;;
Linux)
	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
			platform="ubuntu"
		fi
	fi
	;;
esac

[[ -n "$platform" ]] || fail "Unsupported platform. Only macOS and Ubuntu are supported."

log "Running bootstrap on ${platform}."
confirm_sudo
ensure_network

run_step "Install WezTerm terminfo" install_terminfo

if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
	run_step "Link dotfiles (WSL Linux side)" link_dotfiles --posix-only
	launch_windows_symlink_terminal
else
	run_step "Link dotfiles" link_dotfiles
fi

if [[ "$platform" == "macos" ]]; then
	if ! xcode-select -p >/dev/null 2>&1; then
		log "Installing Xcode Command Line Tools"
		xcode-select --install || true
		while ! xcode-select -p >/dev/null 2>&1; do
			log "Waiting for Xcode Command Line Tools installation..."
			sleep 20
		done
	fi
else
	run_step "Refresh apt repositories" apt_get update
	run_step "Upgrade apt packages" apt_get upgrade
	run_step "Install Ubuntu prerequisites" apt_get install --no-install-recommends \
		apt-transport-https \
		build-essential \
		cmake \
		ca-certificates \
		curl \
		gnupg \
		file \
		git \
		procps \
		sudo \
		tzdata \
		unzip
	run_step "Install Stripe CLI (apt)" install_stripe_cli_ubuntu
	run_step "Install 1Password CLI (apt)" install_1password_cli_ubuntu
	run_step "Install Google Cloud CLI (apt)" install_google_cloud_cli_ubuntu
	run_step "Apt autoremove" apt_get autoremove
	run_step "Apt clean" apt_get clean
fi

log "Bootstrapping Homebrew"
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ASK=1
if ! command_exists brew; then
	export NONINTERACTIVE=1
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if command_exists /opt/homebrew/bin/brew; then
	BREW_BIN=/opt/homebrew/bin/brew
elif command_exists /home/linuxbrew/.linuxbrew/bin/brew; then
	BREW_BIN=/home/linuxbrew/.linuxbrew/bin/brew
else
	BREW_BIN="$(command -v brew)"
fi

eval "$("${BREW_BIN}" shellenv)"

if ! command_exists brew; then
	fail "Homebrew shellenv did not expose brew at ${BREW_BIN}. Please check the installation."
fi

run_step "Ensure brew taps" brew_taps
run_step "Trust brew taps" brew_trust_taps
run_step "brew update" brew update --verbose
run_step "brew upgrade (formula)" brew upgrade --formula --yes --verbose
run_step "brew upgrade (cask)" brew_upgrade_casks
run_step "brew cleanup" brew_cleanup_all

brew_formulae=(
	azure-cli
	bat
	cairo
	cmake
	dotnet
	eza
	fastfetch
	fd
	fzf
	gcc
	gh
	giflib
	git-delta
	go
	helm
	gettext
	jpeg
	k9s
	libtool
	libpng
	librsvg
	lazygit
	lynx
	mise
	ninja
	automake
	pkg-config
	ripgrep
	rust-analyzer
	tlrc
	wordnet
	pango
	zoxide
	zsh
	powerlevel10k
	zsh-vi-mode
)

if [[ "$platform" == "macos" ]]; then
	brew_formulae+=(stripe/stripe-cli/stripe)
fi

if [[ "$platform" == "ubuntu" ]]; then
	brew_formulae+=(
		"wez/wezterm-linuxbrew/wezterm"
		glew
		libxext
		libxi
		libx11
		mesa
		mesa-glu
		llvm
	)
fi

run_step "Install brew packages" brew install --yes "${brew_formulae[@]}"

if [[ "$platform" == "macos" ]]; then
	run_step "Install WezTerm (cask)" brew install --cask --yes wezterm
	run_step "Install 1Password CLI (cask)" brew install --cask --yes 1password-cli
	run_step "Install Google Cloud CLI (cask)" brew install --cask --yes google-cloud-sdk
fi

log "Cloning fzf-git"
if [[ -d "$HOME/.fzf-git/.git" ]]; then
	run_step "Update fzf-git" git -C "$HOME/.fzf-git" pull --ff-only
elif [[ -d "$HOME/.fzf-git" ]]; then
	log "Existing ~/.fzf-git directory without git found. Skipping clone."
else
	run_step "Clone fzf-git" git clone https://github.com/junegunn/fzf-git.sh.git "$HOME/.fzf-git"
fi

run_step "Configure 1Password SSH agent bridges" configure_1password_ssh_agent

log "Configuring mise runtimes"
if ! command_exists mise; then
	fail "mise is not available after Homebrew installation"
fi

run_step "Configure mise runtime settings" mise_configure_runtime_settings

mise_globals=(
	node@latest
	bun@latest
	lua@latest
	python@latest
	rust@latest
)

for tool in "${mise_globals[@]}"; do
	run_step "Ensure ${tool} via mise" mise_use_global "$tool"
done

run_step "Install/upgrade mise runtimes" mise_install_all

# Ensure PROMPT_COMMAND exists before mise injects hook while set -u is active.
: "${PROMPT_COMMAND:=}"

eval "$(mise activate bash)"

run_step "Run mise doctor" mise_doctor_check

if ! command_exists bun; then
	fail "bun is not available after mise activation"
fi

log "Installing global coding agents via Bun"
agents=(
	@openai/codex
	@just-every/code
)
missing_agents=()

for agent in "${agents[@]}"; do
	if ! bun_global_has_package "$agent"; then
		missing_agents+=("$agent")
	fi
done

if ((${#missing_agents[@]} > 0)); then
	install_args=("${missing_agents[@]/%/@latest}")
	run_step "Install global coding agents" bun_install_agents "${install_args[@]}"
else
	log "Global coding agents already installed; skipping bun install."
fi

update_args=("${agents[@]/%/@latest}")
run_step "Update global coding agents" bun_update_agents "${update_args[@]}"

log "Building Neovim from source into ${NEOVIM_SRC_DIR}"
run_step "Sync Neovim sources" sync_neovim_sources
if [[ -n "$NEOVIM_SOURCE_MESSAGE" ]]; then
	log "$NEOVIM_SOURCE_MESSAGE"
fi

if [[ "$neovim_build_needed" == "1" ]]; then
	run_step "Build Neovim from source" neovim_build_from_source
fi

run_step "Prime Neovim plugins" bootstrap_neovim

log "Recording update timestamp"
touch "$UPDATE_TIMESTAMP_FILE"

log "Ensuring default shell is zsh"
zsh_path="$(command -v zsh)"
if [[ -n "$zsh_path" ]]; then
	if ! grep -Fq "$zsh_path" /etc/shells; then
		sudo sh -c "echo ${zsh_path} >> /etc/shells"
	fi

	current_shell=""
	if command_exists getent; then
		if current_shell="$(getent passwd "$USER" | cut -d: -f7)"; then
			:
		else
			current_shell=""
		fi
	elif command_exists dscl; then
		if dscl_output="$(dscl . -read "/Users/${USER}" UserShell 2>/dev/null)"; then
			current_shell="${dscl_output##* }"
		fi
	fi
	if [[ -z "$current_shell" ]]; then
		current_shell="${SHELL:-}"
	fi

	if [[ "$current_shell" == "$zsh_path" ]]; then
		log "Default shell already set to ${zsh_path}; skipping change."
	else
		log "Changing default shell to ${zsh_path}"
		sudo chsh -s "$zsh_path" "$USER"
	fi
else
	log "zsh not found in PATH; skipping shell change."
fi

log "Summary:"
log "- Platform: ${platform}"
if [[ "$neovim_build_needed" == "1" ]]; then
	log "- Neovim commit installed: ${new_commit}"
else
	log "- Neovim install skipped; already at ${new_commit:-unknown}"
fi
if ((${#missing_agents[@]} > 0)); then
	log "- Installed bun agents via @latest: ${missing_agents[*]}"
else
	log "- bun agents refreshed to @latest"
fi
log "- Dotfiles bootstrap complete. Please restart your shell."
