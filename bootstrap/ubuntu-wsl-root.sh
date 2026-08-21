#!/usr/bin/env bash
set -euo pipefail

user_name="alx"
ssh_port=2222
authorized_keys=""
install_nix=0

while (($#)); do
	case "$1" in
		--user)
			user_name="$2"
			shift 2
			;;
		--ssh-port)
			ssh_port="$2"
			shift 2
			;;
		--authorized-keys)
			authorized_keys="$2"
			shift 2
			;;
		--install-nix)
			install_nix=1
			shift
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

[[ "$user_name" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
	printf 'Invalid Linux user: %s\n' "$user_name" >&2
	exit 2
}
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || ((ssh_port < 1 || ssh_port > 65535)); then
	printf 'Invalid SSH port: %s\n' "$ssh_port" >&2
	exit 2
fi

export DEBIAN_FRONTEND=noninteractive
required_packages=(
	acl
	ca-certificates
	curl
	git
	iproute2
	openssh-server
	rsync
	sqlite3
	sudo
	xz-utils
	zsh
)
missing_packages=()
for package in "${required_packages[@]}"; do
	dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed || missing_packages+=("$package")
done
if ((${#missing_packages[@]})); then
	apt-get update
	apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

if ! id "$user_name" >/dev/null 2>&1; then
	existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"
	if [[ -n "$existing_user" && "$existing_user" != "$user_name" ]]; then
		existing_group="$(id -gn "$existing_user")"
		usermod --login "$user_name" --home "/home/$user_name" --move-home "$existing_user"
		if [[ "$existing_group" == "$existing_user" ]] && ! getent group "$user_name" >/dev/null; then
			groupmod --new-name "$user_name" "$existing_group"
		fi
	else
		getent group 1000 >/dev/null || groupadd --gid 1000 "$user_name"
		primary_group="$(getent group 1000 | cut -d: -f1)"
		useradd --uid 1000 --gid "$primary_group" --create-home --shell /usr/bin/zsh "$user_name"
	fi
fi
usermod --shell /usr/bin/zsh --append --groups sudo "$user_name"

install -d -m 0750 /etc/sudoers.d
sudoers_path="/etc/sudoers.d/90-dotfiles-$user_name"
sudoers_content="$user_name ALL=(ALL:ALL) NOPASSWD: ALL"
if [[ ! -f "$sudoers_path" ]] || [[ "$(<"$sudoers_path")" != "$sudoers_content" ]]; then
	printf '%s\n' "$sudoers_content" >"$sudoers_path"
	chmod 0440 "$sudoers_path"
fi
visudo --check --file "$sudoers_path" >/dev/null

wsl_conf='[boot]
systemd=true

[automount]
enabled=true
mountFsTab=true
options=metadata,umask=22,fmask=11

[interop]
enabled=true
appendWindowsPath=true

[network]
generateHosts=true
generateResolvConf=true

[user]
default='"$user_name"
if [[ ! -f /etc/wsl.conf ]] || [[ "$(</etc/wsl.conf)" != "$wsl_conf" ]]; then
	printf '%s\n' "$wsl_conf" >/etc/wsl.conf
	printf 'WSL_RESTART_REQUIRED=1\n'
fi

ssh_config_path=/etc/ssh/sshd_config.d/99-dotfiles-wsl.conf
ssh_config='Port '"$ssh_port"'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers '"$user_name"
ssh_config_changed=0
if [[ ! -f "$ssh_config_path" ]] || [[ "$(<"$ssh_config_path")" != "$ssh_config" ]]; then
	printf '%s\n' "$ssh_config" >"$ssh_config_path"
	chmod 0644 "$ssh_config_path"
	ssh_config_changed=1
fi

user_home="$(getent passwd "$user_name" | cut -d: -f6)"
install -d -m 0700 -o "$user_name" -g "$(id -gn "$user_name")" "$user_home/.ssh"
if [[ -n "$authorized_keys" && -s "$authorized_keys" ]]; then
	install -m 0600 -o "$user_name" -g "$(id -gn "$user_name")" "$authorized_keys" "$user_home/.ssh/authorized_keys"
fi
sshd -t

if ((install_nix)); then
	systemctl is-system-running >/dev/null 2>&1 || [[ "$(systemctl is-system-running 2>/dev/null || true)" == degraded ]] || {
		printf 'systemd is not ready; terminate and reopen this distro before installing Nix.\n' >&2
		exit 1
	}
	if [[ ! -x /nix/var/nix/profiles/default/bin/nix ]]; then
		installer="$(mktemp)"
		trap 'rm -f "$installer"' EXIT
		curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix -o "$installer"
		sh "$installer" install linux --no-confirm --init systemd
	fi
	systemctl enable --now nix-daemon.service
	systemctl enable --now ssh.service
	if ((ssh_config_changed)); then
		systemctl restart ssh.service
	fi
fi

printf 'Ubuntu WSL system prerequisites are current for %s.\n' "$user_name"
