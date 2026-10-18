#!/usr/bin/env bash
# Fetch a successful, pinned Windows build without touching the active service.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
manifest="$repo_root/platforms/windows/sunshine-fork.json"
for tool in gh jq sha256sum flock; do
	command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
repository=$(jq -er '.repository' "$manifest")
revision=$(jq -er '.buildRevision' "$manifest")
run=$(jq -er '.buildRun' "$manifest")
artifact=$(jq -er '.artifact' "$manifest")
metadata=$(gh run view "$run" --repo "$repository" --json headSha,status,conclusion,url)
if ! jq -e --arg revision "$revision" \
	'.headSha == $revision and .status == "completed" and .conclusion == "success"' \
	<<< "$metadata" >/dev/null; then
	echo "The pinned Sunshine build is not verified successful; nothing downloaded or installed." >&2
	jq '{headSha,status,conclusion,url}' <<< "$metadata" >&2
	exit 1
fi

cache_parent="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/sunshine"
mkdir -p "$cache_parent"
exec 9> "$cache_parent/fetch.lock"
flock 9
download_root="$cache_parent/$revision-$run"
if [[ -e "$download_root" ]]; then
	if ! (cd "$download_root" && sha256sum --check SHA256SUMS); then
		echo "Existing Sunshine cache failed verification; refusing to overwrite it: $download_root" >&2
		exit 1
	fi
else
	staging=$(mktemp -d "$cache_parent/staging.XXXXXXXX")
	gh run download "$run" --repo "$repository" --name "$artifact" --dir "$staging"
	test -s "$staging/Sunshine-Windows-AMD64-lite.zip"
	(cd "$staging" && sha256sum Sunshine-Windows-AMD64-lite.zip > SHA256SUMS)
	mv "$staging" "$download_root"
fi
cat "$download_root/SHA256SUMS"
printf 'Verified build revision: %s\nDownloaded to: %s\nNo installation or service restart performed.\n' \
	"$revision" "$download_root"
