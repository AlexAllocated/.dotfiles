#!/usr/bin/env bash

run_neovim_automation() (
	local entry automation_path="" inherited_path="$PATH"
	# Editor maintenance uses the host-declared runtimes, even when invoked
	# from a project shell or an old session with Mise shims ahead of Nix/Brew.
	while [[ -n "$inherited_path" ]]; do
		entry="${inherited_path%%:*}"
		if [[ "$inherited_path" == *:* ]]; then
			inherited_path="${inherited_path#*:}"
		else
			inherited_path=""
		fi
		case "$entry" in
			*/mise/shims | */mise/installs/* | "${MISE_DATA_DIR:-$HOME/.local/share/mise}"/shims | "${MISE_DATA_DIR:-$HOME/.local/share/mise}"/installs/*) continue ;;
		esac
		[[ -z "$entry" ]] || automation_path="${automation_path:+$automation_path:}$entry"
	done
	if command_exists nix; then
		for entry in "$HOME/.nix-profile/bin" "/etc/profiles/per-user/$(id -un)/bin"; do
			[[ ! -d "$entry" ]] || automation_path="$entry:$automation_path"
		done
	elif [[ "$(uname -s)" == "Darwin" ]] && command_exists brew; then
		automation_path="$(brew --prefix)/bin:$automation_path"
	fi
	export PATH="$automation_path"
	nvim "$@"
)

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
	[[ -f "$candidate/nvim/lazy-lock.json" ]] || return 0
	if ! command_exists nvim; then
		printf 'Neovim is unavailable; leaving its lockfile unchanged.\n'
		return 0
	fi
	mkdir -p "$runtime/config" "$runtime/data" "$runtime/state" "$runtime/cache"
	ln -s "$candidate/nvim" "$runtime/config/nvim"
	printf 'Refreshing Neovim plugin pins in an isolated runtime...\n'
	if ! DOTFILES_NVIM_AUTOMATION=1 \
		DOTFILES_NVIM_PIN_UPDATE=1 \
		DOTFILES_NVIM_LOCKFILE="$candidate/nvim/lazy-lock.json" \
		XDG_CONFIG_HOME="$runtime/config" \
		XDG_DATA_HOME="$runtime/data" \
		XDG_STATE_HOME="$runtime/state" \
		XDG_CACHE_HOME="$runtime/cache" \
		GIT_CONFIG_COUNT=1 \
		GIT_CONFIG_KEY_0=advice.detachedHead \
		GIT_CONFIG_VALUE_0=false \
		run_neovim_automation --headless "+set nomore" "+lua require(\"config.bootstrap\").update_plugin_pins()"; then
		printf 'Neovim pin refresh failed.\n' >&2
		return 1
	fi
	printf 'Neovim plugin pins refreshed.\n'
}

update_codex_candidate() {
	local candidate="$1"
	local metadata="$2/codex-release.json"
	local output="$candidate/pins/codex.json"
	local staged="$output.next"
	local tag version

	require_command curl
	require_command jq
	mkdir -p "$(dirname "$output")"
	printf 'Refreshing Codex from the official OpenAI release channel...\n'
	curl -fsSL \
		--connect-timeout 10 \
		--max-time 30 \
		https://releases.openai.com/codex/channels/latest \
		-o "$metadata"
	tag="$(jq -er '.tag_name | strings' "$metadata")"
	case "$tag" in
		rust-v*) version="${tag#rust-v}" ;;
		*)
			printf 'Unexpected Codex release tag: %s\n' "$tag" >&2
			return 1
			;;
	esac
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
		printf 'Unexpected Codex release version: %s\n' "$version" >&2
		return 1
	}

	jq -e --arg version "$version" '
		def package($system; $target):
			("codex-package-" + $target + ".tar.gz") as $name
			| ([.assets[] | select(.name == $name)]
				| if length == 1 then .[0] else error("expected exactly one " + $name) end) as $asset
			| ($asset.digest | capture("^sha256:(?<hash>[0-9a-f]{64})$").hash) as $sha256
			| ("https://releases.openai.com/codex/releases/" + $version + "/" + $name) as $url
			| if $asset.browser_download_url != $url then
				error("unexpected download URL for " + $name)
			  else
				{ key: $system, value: { target: $target, url: $url, sha256: $sha256 } }
			  end;

		[
			package("aarch64-darwin"; "aarch64-apple-darwin"),
			package("aarch64-linux"; "aarch64-unknown-linux-musl"),
			package("x86_64-linux"; "x86_64-unknown-linux-musl")
		] as $assets
		| {
			channel: "latest",
			version: $version,
			assets: ($assets | from_entries)
		}
	' "$metadata" >"$staged"
	mv "$staged" "$output"
	printf 'Codex %s is pinned from OpenAI.\n' "$version"
}

validate_update_candidate() {
	local candidate="$1"
	if command_exists nix; then
		printf 'Running native Nix checks before accepting updated pins...\n'
		nix flake check "path:$candidate" || return $?
		printf 'Evaluating every supported Nix system before accepting updated pins...\n'
		nix flake check --all-systems --no-build "path:$candidate" || return $?
	fi
}

accept_candidate_locks() {
	local candidate="$1"
	local path
	for path in flake.nix flake.lock nvim/lazy-lock.json pins/codex.json pins/chatgpt-desktop.json pins/iloader-cargo.json; do
		if [[ -f "$candidate/$path" ]]; then
			cp "$candidate/$path" "$REPO_ROOT/$path"
		fi
	done
}

accept_candidate_neovim_lock() {
	local candidate="$1"
	if [[ -f "$candidate/nvim/lazy-lock.json" ]]; then
		cp "$candidate/nvim/lazy-lock.json" "$REPO_ROOT/nvim/lazy-lock.json"
	fi
}

sync_live_neovim_runtime() (
	local config_home
	command_exists nvim || return 0
	config_home="$(mktemp -d)"
	trap_remove_on_exit "$config_home"
	ln -s "$REPO_ROOT/nvim" "$config_home/nvim"
	printf 'Applying accepted Neovim pins to the active runtime...\n'
	if ! DOTFILES_NVIM_AUTOMATION=1 \
		DOTFILES_NVIM_LOCKFILE="$REPO_ROOT/nvim/lazy-lock.json" \
		XDG_CONFIG_HOME="$config_home" \
		GIT_CONFIG_COUNT=1 \
		GIT_CONFIG_KEY_0=advice.detachedHead \
		GIT_CONFIG_VALUE_0=false \
		run_neovim_automation --headless "+set nomore" "+lua require(\"config.bootstrap\").sync_runtime()"; then
		printf 'Active Neovim runtime sync failed.\n' >&2
		return 1
	fi
	printf 'Active Neovim runtime synchronized.\n'
)

prepare_update_candidate() {
	local candidate="$1"
	local work="$2"
	stage_repo "$candidate"
	require_command python3
	if command_exists nix; then
		python3 "$REPO_ROOT/scripts/updates/releases.py" "$candidate"
	else
		printf 'Nix is unavailable; leaving flake URLs and lockfile unchanged.\n'
		python3 "$REPO_ROOT/scripts/updates/releases.py" "$candidate" --skip-flake
	fi
	update_codex_candidate "$candidate" "$work"
	if command_exists nix; then
		printf 'Refreshing flake inputs in a staging checkout...\n'
		nix flake update --flake "path:$candidate"
		python3 "$REPO_ROOT/scripts/updates/releases.py" "$candidate" --iloader-cargo
	fi
	update_neovim_candidate "$candidate" "$work"
	validate_update_candidate "$candidate"
}

run_update() {
	local profile="${1:-$(detect_profile)}"
	local work candidate
	work="$(mktemp -d)"
	candidate="$work/repo"
	trap_remove_on_exit "$work"
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

normalize_intent_to_add_entries() {
	local entry path normalized=0
	while IFS= read -r -d '' entry; do
		[[ "${entry:0:2}" == " A" ]] || continue
		path="${entry:3}"
		git -C "$REPO_ROOT" reset -q -- "$path"
		normalized=1
	done < <(git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all)
	if [[ "$normalized" == "1" ]]; then
		printf 'Normalized intent-to-add files before saving local changes.\n'
	fi
}

fetch_and_rebase_upstream() {
	local result_var="$1"
	local remote remote_branch upstream ancestry_status
	printf -v "$result_var" '0'
	if ! upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
		return 0
	fi
	remote="${upstream%%/*}"
	remote_branch="${upstream#*/}"
	git -C "$REPO_ROOT" fetch "$remote" "$remote_branch" || return $?
	if git -C "$REPO_ROOT" merge-base --is-ancestor "$upstream" HEAD; then
		return 0
	else
		ancestry_status=$?
		((ancestry_status == 1)) || return "$ancestry_status"
		printf 'Rebasing onto the latest %s...\n' "$upstream"
		git -C "$REPO_ROOT" rebase "$upstream" || return $?
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
	# An intent-to-add index entry is neither an ordinary tracked change nor an
	# untracked file, and `git stash --include-untracked` refuses to merge it
	# into the temporary stash tree. Return those entries to their lossless
	# untracked representation before preserving the complete working tree.
	normalize_intent_to_add_entries
	if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
		git -C "$REPO_ROOT" stash push --include-untracked --message "dotfiles updoot pre-sync $(date -u +%Y%m%dT%H%M%SZ)" >/dev/null
		stash_ref='stash@{0}'
		printf 'Saved local dotfiles changes before upstream sync.\n'
	fi
	if ! fetch_and_rebase_upstream rebased; then
		if [[ -n "$stash_ref" ]]; then
			if [[ ! -d "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path rebase-merge)" && ! -d "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path rebase-apply)" ]]; then
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

cleanup_nix_after_updoot() {
	local profile="$1"
	local system_profile=/nix/var/nix/profiles/system
	local generations current generation kept_previous=0
	local -a delete_generations=()
	local -A keep_generations=()

	command_exists nix-collect-garbage || return 0
	case "$profile" in
		chev-desktop | tracer)
			require_command sudo
			require_command nix-env
			generations="$(sudo nix-env --profile "$system_profile" --list-generations)"
			current="$(awk '/\(current\)/ { print $1; exit }' <<<"$generations")"
			[[ "$current" =~ ^[0-9]+$ ]] || {
				printf 'Could not identify the active NixOS generation; refusing cleanup.\n' >&2
				return 1
			}

			keep_generations["$current"]=1
			while IFS= read -r generation; do
				[[ "$generation" =~ ^[0-9]+$ ]] || continue
				[[ "$generation" == "$current" ]] && continue
				if ((kept_previous < 2)); then
					keep_generations["$generation"]=1
					((kept_previous += 1))
				fi
			done < <(awk '{ print $1 }' <<<"$generations" | sort -rn)

			while IFS= read -r generation; do
				[[ "$generation" =~ ^[0-9]+$ ]] || continue
				[[ -n "${keep_generations[$generation]:-}" ]] || delete_generations+=("$generation")
			done < <(awk '{ print $1 }' <<<"$generations")

			if ((${#delete_generations[@]})); then
				printf 'Removing superseded NixOS generations; retaining current plus two backups...\n'
				sudo nix-env --profile "$system_profile" --delete-generations "${delete_generations[@]}"
			else
				printf 'NixOS generation history already contains only current plus two backups.\n'
			fi
			sudo nix-collect-garbage
			;;
		macos-managed) ;;
		*) nix-collect-garbage ;;
	esac
}

run_check() {
	local work candidate
	require_command nix
	work="$(mktemp -d)"
	candidate="$work/repo"
	trap_remove_on_exit "$work"
	stage_repo "$candidate"
	nix flake check "path:$candidate"
	nix flake check --all-systems --no-build "path:$candidate"
	trap - EXIT
	rm -rf "$work"
}
