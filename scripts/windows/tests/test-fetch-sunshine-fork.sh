#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture_root=$(mktemp -d /tmp/sunshine-fetch-test.XXXXXXXX)
export XDG_CACHE_HOME="$fixture_root/cache"
export SUNSHINE_FIXTURE_ROOT="$fixture_root"
export SUNSHINE_FIXTURE_REVISION
SUNSHINE_FIXTURE_REVISION=$(jq -r .buildRevision "$repo_root/platforms/windows/sunshine-fork.json")
gh() {
	if [[ "$1 $2" == 'run view' ]]; then
		local sha="$SUNSHINE_FIXTURE_REVISION" status=completed conclusion=success
		case "$SUNSHINE_FIXTURE_MODE" in
			pending) status=in_progress; conclusion='' ;;
			failed) conclusion=failure ;;
			mismatch) sha=wrong ;;
		esac
		jq -n --arg sha "$sha" --arg status "$status" --arg conclusion "$conclusion" \
			'{headSha:$sha,status:$status,conclusion:$conclusion,url:"fixture"}'
	elif [[ "$1 $2" == 'run download' ]]; then
		test ! -e "$SUNSHINE_FIXTURE_ROOT/downloaded"
		touch "$SUNSHINE_FIXTURE_ROOT/downloaded"
		local target=''
		while (( $# )); do
			if [[ "$1" == --dir ]]; then target="$2"; break; fi
			shift
		done
		printf 'test artifact, not an executable\n' > "$target/Sunshine-Windows-AMD64-lite.zip"
	else return 99
	fi
}
export -f gh
helper="$repo_root/scripts/windows/fetch-sunshine-fork.sh"
for mode in pending failed mismatch; do
	export SUNSHINE_FIXTURE_MODE="$mode"
	if bash "$helper" > "$fixture_root/$mode.log" 2>&1; then exit 1; fi
	test ! -e "$fixture_root/downloaded"
done
export SUNSHINE_FIXTURE_MODE=success
bash "$helper" > "$fixture_root/success.log"
bash "$helper" > "$fixture_root/repeat.log"
archive=$(find "$XDG_CACHE_HOME" -name Sunshine-Windows-AMD64-lite.zip -print -quit)
printf 'corruption\n' >> "$archive"
before=$(sha256sum "$archive")
if bash "$helper" > "$fixture_root/corrupt.log" 2>&1; then exit 1; fi
test "$before" = "$(sha256sum "$archive")"
echo 'PASS: pending, failed, wrong revision, successful download, cached repeat, corruption refusal'
