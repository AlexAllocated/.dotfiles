#!/usr/bin/env bash

stage_repo() {
	local destination="$1"
	require_command rsync
	mkdir -p "$destination"
	rsync -a --delete \
		--exclude .git/ \
		--exclude .env \
		--exclude node_modules/ \
		--exclude 'result*' \
		"$REPO_ROOT/" "$destination/"
}

update_neovim_candidate() {
	local candidate="$1"
	local runtime="$2/nvim"
	local log_file="$runtime/update.log"
	[[ -f "$candidate/nvim/lazy-lock.json" ]] || return 0
	if ! command_exists nvim; then
		printf 'Neovim is unavailable; leaving its lockfile unchanged.\n'
		return 0
	fi
	mkdir -p "$runtime/config" "$runtime/data" "$runtime/state" "$runtime/cache"
	ln -s "$candidate/nvim" "$runtime/config/nvim"
	printf 'Refreshing Neovim plugin pins in an isolated runtime...\n'
	if ! DOTFILES_NVIM_AUTOMATION=1 \
		DOTFILES_NVIM_LOCKFILE="$candidate/nvim/lazy-lock.json" \
		XDG_CONFIG_HOME="$runtime/config" \
		XDG_DATA_HOME="$runtime/data" \
		XDG_STATE_HOME="$runtime/state" \
		XDG_CACHE_HOME="$runtime/cache" \
		nvim --headless "+set nomore" "+Lazy! update" "+MasonUpdate" "+TSUpdateSync" "+lua require(\"config.bootstrap\").wait_for_mason()" +qa \
		>"$log_file" 2>&1; then
		printf 'Neovim pin refresh failed:\n' >&2
		cat "$log_file" >&2
		return 1
	fi
	printf 'Neovim plugin pins and registries refreshed.\n'
}

validate_update_candidate() {
	local candidate="$1"
	if command_exists nix; then
		printf 'Evaluating every supported Nix system before accepting updated pins...\n'
		nix flake check --all-systems --no-build "$candidate"
	fi
}

accept_candidate_locks() {
	local candidate="$1"
	local path
	for path in flake.lock nvim/lazy-lock.json; do
		if [[ -f "$candidate/$path" ]]; then
			cp "$candidate/$path" "$REPO_ROOT/$path"
		fi
	done
}

sync_live_neovim_runtime() (
	local config_home log_file
	command_exists nvim || return 0
	config_home="$(mktemp -d)"
	log_file="$config_home/update.log"
	trap 'rm -rf "$config_home"' EXIT
	ln -s "$REPO_ROOT/nvim" "$config_home/nvim"
	printf 'Applying accepted Neovim pins to the active runtime...\n'
	if ! DOTFILES_NVIM_AUTOMATION=1 \
		DOTFILES_NVIM_LOCKFILE="$REPO_ROOT/nvim/lazy-lock.json" \
		XDG_CONFIG_HOME="$config_home" \
		nvim --headless "+set nomore" "+Lazy! restore" "+MasonUpdate" "+TSUpdateSync" "+lua require(\"config.bootstrap\").wait_for_mason()" +qa \
		>"$log_file" 2>&1; then
		printf 'Active Neovim runtime sync failed:\n' >&2
		cat "$log_file" >&2
		return 1
	fi
	printf 'Active Neovim runtime synchronized.\n'
)

prepare_update_candidate() {
	local candidate="$1"
	local work="$2"
	stage_repo "$candidate"
	if command_exists nix; then
		printf 'Refreshing flake inputs in a staging checkout...\n'
		nix flake update --flake "$candidate"
	fi
	update_neovim_candidate "$candidate" "$work"
	validate_update_candidate "$candidate"
}

run_update() {
	local profile="${1:-$(detect_profile)}"
	local work candidate
	work="$(mktemp -d)"
	candidate="$work/repo"
	trap 'rm -rf "$work"' EXIT
	prepare_update_candidate "$candidate" "$work"
	accept_candidate_locks "$candidate"
	sync_live_neovim_runtime
	trap - EXIT
	rm -rf "$work"
	printf 'Updated pins passed validation for %s.\n' "$profile"
}

ensure_updoot_checkout() {
	local branch
	require_command git
	git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
		printf 'Cannot publish updoot changes: %s is not a Git checkout.\n' "$REPO_ROOT" >&2
		return 1
	}
	branch="$(git -C "$REPO_ROOT" branch --show-current)"
	if [[ -z "$branch" ]]; then
		printf 'Cannot publish updoot changes from a detached HEAD.\n' >&2
		return 1
	fi
}

fetch_and_rebase_upstream() {
	local result_var="$1"
	local remote remote_branch upstream
	printf -v "$result_var" '0'
	if ! upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
		return 0
	fi
	remote="${upstream%%/*}"
	remote_branch="${upstream#*/}"
	git -C "$REPO_ROOT" fetch "$remote" "$remote_branch"
	if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$upstream" HEAD; then
		printf 'Rebasing onto the latest %s...\n' "$upstream"
		git -C "$REPO_ROOT" rebase "$upstream"
		printf -v "$result_var" '1'
	fi
}

restore_updoot_stash() {
	local stash_ref="$1"
	if git -C "$REPO_ROOT" stash apply --index "$stash_ref"; then
		git -C "$REPO_ROOT" stash drop "$stash_ref" >/dev/null
		printf 'Restored local dotfiles changes after upstream sync.\n'
		return 0
	fi
	printf 'Local changes conflicted with upstream and remain in %s.\n' "$stash_ref" >&2
	printf 'Resolve the working tree, then drop the stash after confirming its changes are present.\n' >&2
	return 1
}

sync_before_update() {
	local rebased=0 stash_ref=""
	ensure_updoot_checkout
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
		git -C "$REPO_ROOT" stash push --include-untracked --message "dotfiles updoot pre-sync $(date -u +%Y%m%dT%H%M%SZ)" >/dev/null
		stash_ref='stash@{0}'
		printf 'Saved local dotfiles changes before upstream sync.\n'
	fi
	if ! fetch_and_rebase_upstream rebased; then
		if [[ -n "$stash_ref" ]]; then
			if [[ ! -d "$(git -C "$REPO_ROOT" rev-parse --git-path rebase-merge)" && ! -d "$(git -C "$REPO_ROOT" rev-parse --git-path rebase-apply)" ]]; then
				restore_updoot_stash "$stash_ref" || true
			else
				printf 'Local changes remain saved in %s while the rebase is resolved.\n' "$stash_ref" >&2
			fi
		fi
		return 1
	fi
	if [[ "$rebased" == "1" ]]; then
		printf 'Integrated upstream changes before refreshing pins.\n'
	fi
	if [[ -n "$stash_ref" ]]; then
		restore_updoot_stash "$stash_ref"
	fi
}

commit_updates() {
	local message
	ensure_updoot_checkout

	git -C "$REPO_ROOT" add -A
	if ! git -C "$REPO_ROOT" diff --cached --quiet; then
		message="${DOTFILES_UPDOOT_COMMIT_MESSAGE:-chore: updoot $(date +%F)}"
		git -C "$REPO_ROOT" commit -m "$message"
	else
		printf 'No repository changes to commit.\n'
	fi
}

push_updates() {
	local branch
	branch="$(git -C "$REPO_ROOT" branch --show-current)"
	if git -C "$REPO_ROOT" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
		git -C "$REPO_ROOT" push
	elif git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
		git -C "$REPO_ROOT" push --set-upstream origin "$branch"
	else
		printf 'Cannot publish updoot changes: %s has no upstream or origin remote.\n' "$branch" >&2
		return 1
	fi
}

run_check() {
	local work candidate
	require_command nix
	work="$(mktemp -d)"
	candidate="$work/repo"
	trap 'rm -rf "$work"' EXIT
	stage_repo "$candidate"
	nix flake check "$candidate"
	nix flake check --all-systems --no-build "$candidate"
	trap - EXIT
	rm -rf "$work"
}
