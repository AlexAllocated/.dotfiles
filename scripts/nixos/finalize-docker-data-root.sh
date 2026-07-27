#!/usr/bin/env bash
set -euo pipefail

source_root="/var/lib/docker"
destination_root="/data/docker"

if ((EUID != 0)); then
	exec sudo -- "$0" "$@"
fi

[[ "$(findmnt -nro TARGET /data)" == /data ]] || {
	printf '%s\n' '/data is not mounted; refusing to remove the old Docker tree.' >&2
	exit 1
}
[[ -d "$destination_root" && ! -L "$destination_root" ]] || {
	printf 'Docker destination is missing or unsafe: %s\n' "$destination_root" >&2
	exit 1
}
[[ -d "$source_root" && ! -L "$source_root" ]] || {
	printf 'Docker source is missing or unsafe: %s\n' "$source_root" >&2
	exit 1
}
[[ "$(docker info --format '{{.DockerRootDir}}')" == "$destination_root" ]] || {
	printf '%s\n' 'The running Docker daemon is not using /data/docker; refusing cleanup.' >&2
	exit 1
}
if findmnt -rn -o TARGET | awk -v root="$source_root" '$0 == root || index($0, root "/") == 1 { found = 1 } END { exit !found }'; then
	printf '%s\n' 'A filesystem is still mounted beneath /var/lib/docker; refusing cleanup.' >&2
	exit 1
fi

source_bytes="$(du --summarize --bytes --one-file-system "$source_root" | awk '{ print $1 }')"
printf 'Docker is active from %s.\n' "$destination_root"
printf 'The verified old tree occupies %s bytes on the system drive.\n' "$source_bytes"
printf '%s\n' 'It will be removed and /var/lib/docker will become a compatibility link to /data/docker.'
printf '%s\n' 'Type exactly: REMOVE OLD DOCKER ROOT'
printf '> '
read -r confirmation
[[ "$confirmation" == "REMOVE OLD DOCKER ROOT" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing was changed.' >&2
	exit 1
}

retiring_root="/var/lib/docker.retiring.$$.${RANDOM}"
mv -T "$source_root" "$retiring_root"
if ! ln -s "$destination_root" "$source_root"; then
	mv -T "$retiring_root" "$source_root"
	exit 1
fi
rm -rf --one-file-system -- "$retiring_root"
sync -f /var/lib

[[ "$(docker info --format '{{.DockerRootDir}}')" == "$destination_root" ]]
printf 'Removed %s bytes of rollback data; Docker remains active from %s.\n' "$source_bytes" "$destination_root"
