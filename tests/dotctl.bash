#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$repo_root"

# shellcheck source=scripts/lib/common.sh
source "$repo_root/scripts/lib/common.sh"
# shellcheck source=scripts/commands/update.sh
source "$repo_root/scripts/commands/update.sh"

assert_equal() {
	local expected="$1"
	local actual="$2"
	[[ "$actual" == "$expected" ]] || {
		printf 'expected %q, got %q\n' "$expected" "$actual" >&2
		exit 1
	}
}

assert_equal "$repo_root#linux" "$(flake_ref_for_profile linux)"
assert_equal "$repo_root#wsl" "$(flake_ref_for_profile nixos-wsl)"
assert_equal "/tmp/staged-dotfiles#wsl" "$(flake_ref_for_profile nixos-wsl /tmp/staged-dotfiles)"
if flake_ref_for_profile macos-managed >/dev/null 2>&1; then
	printf 'macos-managed unexpectedly resolved to a flake output\n' >&2
	exit 1
fi

cleanup_fixture="$(mktemp -d)"
bash -c 'set -u; source "$1"; cleanup_path="$2"; register_cleanup() { local work="$cleanup_path"; trap_remove_on_exit "$work"; }; register_cleanup' _ \
	"$repo_root/scripts/lib/common.sh" "$cleanup_fixture"
[[ ! -e "$cleanup_fixture" ]] || {
	printf 'captured cleanup trap did not remove %s\n' "$cleanup_fixture" >&2
	exit 1
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/source/modules/home"
printf 'untracked module\n' >"$fixture/source/modules/home/foundation.nix"
REPO_ROOT="$fixture/source"
stage_repo "$fixture/candidate"
assert_equal "untracked module" "$(cat "$fixture/candidate/modules/home/foundation.nix")"

git init --quiet --bare "$fixture/remote.git"
git init --quiet --initial-branch=main "$fixture/checkout"
git -C "$fixture/checkout" config user.name "Dotfiles Test"
git -C "$fixture/checkout" config user.email "dotfiles@example.test"
printf 'initial\n' >"$fixture/checkout/tracked"
git -C "$fixture/checkout" add tracked
git -C "$fixture/checkout" commit --quiet -m initial
git -C "$fixture/checkout" remote add origin "$fixture/remote.git"
git -C "$fixture/checkout" push --quiet --set-upstream origin main
git clone --quiet --branch main "$fixture/remote.git" "$fixture/peer"
git -C "$fixture/peer" config user.name "Dotfiles Peer"
git -C "$fixture/peer" config user.email "peer@example.test"
printf 'peer\n' >"$fixture/peer/peer-change"
git -C "$fixture/peer" add peer-change
git -C "$fixture/peer" commit --quiet -m "peer update"
git -C "$fixture/peer" push --quiet
peer_commit="$(git -C "$fixture/peer" rev-parse HEAD)"
printf 'changed\n' >"$fixture/checkout/tracked"
printf 'untracked\n' >"$fixture/checkout/untracked"
REPO_ROOT="$fixture/checkout"
sync_before_update >/dev/null
git -C "$fixture/checkout" merge-base --is-ancestor "$peer_commit" HEAD
assert_equal "changed" "$(cat "$fixture/checkout/tracked")"
assert_equal "untracked" "$(cat "$fixture/checkout/untracked")"
assert_equal "" "$(git -C "$fixture/checkout" stash list)"
DOTFILES_UPDOOT_COMMIT_MESSAGE="test: automatic updoot" commit_updates >/dev/null
printf 'late peer\n' >"$fixture/peer/late-peer-change"
git -C "$fixture/peer" add late-peer-change
git -C "$fixture/peer" commit --quiet -m "late peer update"
git -C "$fixture/peer" push --quiet
late_peer_commit="$(git -C "$fixture/peer" rev-parse HEAD)"
rebased=0
fetch_and_rebase_upstream rebased >/dev/null
assert_equal "1" "$rebased"
git -C "$fixture/checkout" merge-base --is-ancestor "$late_peer_commit" HEAD
push_updates >/dev/null
assert_equal "test: automatic updoot" "$(git -C "$fixture/checkout" log -1 --pretty=%s)"
assert_equal "$(git -C "$fixture/checkout" rev-parse HEAD)" "$(git --git-dir="$fixture/remote.git" rev-parse main)"
assert_equal "" "$(git -C "$fixture/checkout" status --short)"

printf 'dotctl helper tests passed\n'
