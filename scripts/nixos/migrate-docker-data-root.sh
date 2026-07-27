#!/usr/bin/env bash
set -euo pipefail

source_root="/var/lib/docker"
destination_root="/data/docker"
staging_root="/data/.docker-migration-staging"

usage() {
	cat <<'EOF'
Usage: sudo migrate-docker-data-root

Stops Docker, copies /var/lib/docker to the existing /data filesystem, and
performs a checksum-based second rsync pass before atomically publishing
/data/docker. The source tree is retained as rollback data.

This command does not repartition, resize, encrypt, or reformat /data.
EOF
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		usage >&2
		exit 2
		;;
esac

if ((EUID != 0)); then
	exec sudo -- "$0"
fi

[[ -d "$source_root" && ! -L "$source_root" ]] || {
	printf 'Docker source is missing or unsafe: %s\n' "$source_root" >&2
	exit 1
}
[[ "$(findmnt -nro TARGET /data)" == /data ]] || {
	printf '%s\n' '/data is not a mounted filesystem; refusing to copy onto the system disk.' >&2
	exit 1
}
[[ ! -e "$destination_root" ]] || {
	printf '%s\n' '/data/docker already exists; refusing to merge state.' >&2
	exit 1
}

resume_staging=false
if [[ -e "$staging_root" ]]; then
	[[ -d "$staging_root" && ! -L "$staging_root" ]] || {
		printf 'Existing staging path is not a safe directory: %s\n' "$staging_root" >&2
		exit 1
	}
	resume_staging=true
fi

available="$(df --block-size=1 --output=avail /data | awk 'NR == 2 { print $1 }')"
source_bytes="$(du --summarize --bytes --one-file-system "$source_root" | awk '{ print $1 }')"
((available > source_bytes + 10 * 1024 * 1024 * 1024)) || {
	printf 'Insufficient /data space: need the %s-byte source plus a 10 GiB reserve.\n' "$source_bytes" >&2
	exit 1
}

printf 'Docker will be unavailable while %s bytes are copied and verified.\n' "$source_bytes"
printf '%s\n' 'The original /var/lib/docker tree will be retained.'
if [[ "$resume_staging" == true ]]; then
	printf 'The interrupted copy at %s will be repaired and reused.\n' "$staging_root"
fi
printf '%s\n' 'Type exactly: MOVE DOCKER TO DATA'
printf '> '
read -r confirmation
[[ "$confirmation" == "MOVE DOCKER TO DATA" ]] || {
	printf '%s\n' 'Confirmation did not match; nothing was changed.' >&2
	exit 1
}

migration_complete=false
cleanup() {
	if [[ -d "$staging_root" ]]; then
		printf 'Incomplete staging data remains at %s for inspection.\n' "$staging_root" >&2
	fi
	if [[ "$migration_complete" != true ]]; then
		printf '%s\n' 'Restarting Docker on its unchanged source data-root.' >&2
		systemctl start docker.service docker.socket || true
	fi
}
trap cleanup EXIT

docker_is_running() {
	systemctl is-active --quiet docker.service ||
		systemctl is-active --quiet docker.socket ||
		pgrep -x dockerd >/dev/null
}

systemctl stop docker.service docker.socket
if docker_is_running; then
	printf '%s\n' 'Docker did not remain stopped; refusing to copy live state.' >&2
	exit 1
fi
if [[ "$resume_staging" != true ]]; then
	install -d -m 0710 -o root -g docker "$staging_root"
fi

rsync -aHAXx --delete --numeric-ids --info=progress2 "$source_root/" "$staging_root/"
verification="$(mktemp /run/docker-migration-verification.XXXXXXXX)"
for attempt in 1 2 3; do
	if docker_is_running; then
		printf '%s\n' 'Docker restarted during verification; refusing to publish inconsistent state.' >&2
		rm -f -- "$verification"
		exit 1
	fi
	: >"$verification"
	rsync -aHAXxnc --delete --numeric-ids "$source_root/" "$staging_root/" >"$verification"
	if [[ ! -s "$verification" ]]; then
		break
	fi
	if ((attempt == 3)); then
		printf '%s\n' 'Checksum verification still found differences after three repair passes:' >&2
		head -n 100 "$verification" >&2
		rm -f -- "$verification"
		exit 1
	fi
	printf 'Checksum pass %d found differences; repairing the stopped copy before retrying.\n' "$attempt"
	rsync -aHAXxc --delete --numeric-ids "$source_root/" "$staging_root/"
done
rm -f -- "$verification"

mv -T "$staging_root" "$destination_root"
sync -f "$destination_root"
migration_complete=true
trap - EXIT
printf '\nVerified Docker state is now staged at %s.\n' "$destination_root"
printf '%s\n' 'Docker remains stopped. Activate the generation whose data-root is /data/docker, then validate every container and volume.'
