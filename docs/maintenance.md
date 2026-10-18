# Dotfiles maintenance

Nix owns system configuration and package pins. Homebrew owns the managed Mac's native packages. The catalog owns explanations and relationships. Machine-local evidence records what was observed, checked, merged, and applied. Codex can prepare a bounded repair; the controller runs the checks and handles publication.

## Finding things

| Command                             | Purpose                                                            |
| ----------------------------------- | ------------------------------------------------------------------ |
| `dotctl map`                        | Machines, capabilities, and their custom tools                     |
| `dotctl catalog <words>`            | Search names, aliases, purpose, and source paths                   |
| `dotctl catalog --scope managed`    | Direct tools from native manifests and evaluated Nix inventory     |
| `dotctl catalog --scope background` | Declared background behavior                                       |
| `dotctl catalog --scope legacy`     | Legacy and retired behavior, including Windows helpers             |
| `dotctl catalog --scope storage`    | Registered artifact inventory                                      |
| `dotctl inspect <id>`               | Source, startup, side effects, disable procedure, and verification |
| `dotctl status`                     | Cached version, health, freshness, and deployment evidence         |
| `dotctl status --refresh`           | Bounded metadata and native observations                           |
| `dotctl patches`                    | Patch purposes, removal evidence, and pending regressions          |
| `dotctl storage --refresh`          | Inventory registered artifact roots                                |
| `dotctl cleanup --plan`             | Exact eligible artifacts and protected totals                      |
| `dotctl schedule status`            | Current local scheduling gate                                      |

Inspection output is plain text, and `--json` returns a versioned document. `NO_COLOR` is honored by emitting no terminal control sequences. `doctor` is a status alias. Neither cached status nor catalog search contacts upstreams or starts helpers. Component inspection may use an explicitly read-only runtime probe.

The Windows Slack helper is indexed by purpose as well as name. It is a legacy scheduled task, not a Linux service. Its source does not prove that the Windows task is installed or running. A manual helper is on-demand, not unhealthy because it has no process.

Background scope includes declared services whose runtime is unknown. Status counts missing local observations and unknown units within service groups explicitly; an intentionally inactive maintenance timer is not a runtime failure. Use `dotctl inspect <id>` for the individual unit evidence.

`catalog/components.json` records ownership and intent. `catalog/surfaces.json` records reviewed operational entry points so a new helper or inline service cannot silently disappear into the repository. `catalog/patches.json` covers local patches and other custom source changes. Native package versions are derived, never copied into these descriptions. Unreviewed historical behavior stays visibly unreviewed until evidence supports a stronger classification.

## Preparing and applying updates

`dotctl prepare <group>` fetches the canonical branch into a dedicated worktree. It does not use pending developer edits. The groups are:

| Group        | Scope                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------- |
| `system`     | Current Nix channels and Codex CLI                                                             |
| `os-release` | Matching stable NixOS, Home Manager, and nix-darwin release families                           |
| `drivers`    | Separate NVIDIA recipe/branch review and full target build                                     |
| `desktop`    | Custom desktop releases, including shell/compositor and desktop app pins                       |
| `editor`     | Lazy plugins, exact Mason packages/registry, and parser validation in isolated XDG directories |
| `mac`        | Review manifest for declared Homebrew packages, preserving the Claude-only company boundary    |

A deterministic preparation/check failure is retained with local evidence. A repair can make at most two attempts and cannot change tests, controller policy, or remove capabilities. Successful candidates become draft PRs. A publication/authentication failure leaves a validated candidate with publication pending. `dotctl retry <id>` resumes it. `dotctl retire <id> --reason <text>` closes a discarded candidate and preserves its artifacts.

`updoot [candidate]` selects exactly one candidate. It compares the local source, PR head, canonical base, and CI checks; validates local applicability; and displays the changes. One interactive confirmation authorizes merge and application. A changed base requires rebase, fresh checks, and a new review. Updoot confirms that the PR actually merged, validates the exact merged checkout, and applies that source. A merge queue entry is not treated as a completed merge.

The developer checkout is never stashed, reset, or automatically committed. Failed applications retain separate stage outcomes and the merged revision. A retry reconciles the same merged PR, rather than creating another merge. The system and editor are separate candidates, so a registry timeout cannot report a failed OS update.

`dotctl apply <profile>` applies a clean committed revision without discovering newer versions. `dotctl apply --update` is an Updoot compatibility alias; `dotctl update <group>` means prepare. The previous shell orchestrator remains as compatibility source, but the new dispatcher does not call its coupled update/apply/stash/commit flow.

Homebrew has no version lockfile equivalent here. The Mac manifest records target versions and recipe identities. Before applying, all recipes are resolved again; drift stops the operation. Each package result is recorded because a native Homebrew transaction can partially succeed. Company-managed macOS and OS drivers are informational, not upgraded by this controller.

## Evidence and recovery

Local state defaults to `~/.local/state/dotfiles` (or `$XDG_STATE_HOME/dotfiles` / `$DOTCTL_STATE_HOME`). Source checkout selection follows the invoked `scripts/dotctl`, `--root`, or `DOTFILES_ROOT`. An installed wrapper selects an explicit root, then a dotfiles worktree in the current directory, then the retained applied source in `active-source.json`, then the conventional checkout.

State includes:

- `status.json` and `inventory-nix.json`: timestamps, provider errors, declared packages, and installed-path evidence.
- `candidates/<id>/candidate.json`: base/head identities, stage results, publication/application state, and retained worktrees.
- Candidate `work/` directories: private diagnostic logs, native checks, build roots, and application receipts.
- `artifact-ownership.json`, `artifacts.json`, and cleanup receipts: provenance and exact retention decisions.
- `acceptance/`: actual native host acceptance, kept outside Git.

Metadata becomes stale after 48 hours. A failed refresh keeps the last successful value and its original timestamp. Installed, declared, and running versions are separate facts. A changed Nix generation path alone does not mean a reboot is required: kernel, modules, and initrd are compared. `system.stateVersion` is never used as an update target.

`dotctl rollback` offers the recorded previous NixOS system. It validates the target and records the result. No command reboots automatically. Generation garbage collection is a separate reviewed operation; keep the current, booted, last confirmed good, and at least two recent generations.

Patch retirement needs a build without the patch and the recorded regression test on the actual target. Hardware and application checks remain pending until performed. An upstream merge or failed patch application is evidence to investigate, not proof that removal is safe. Source or target changes invalidate older removal evidence.

## Storage lifecycle

Initial registered roots include `~/Backups`, `~/migration-recovery`, `~/save-recovery`, `~/.local/share/dotfiles`, `~/.backup_dotfiles`, and `~/Archives/codex-history`, plus controller-owned candidate, validation, application, and scratch storage. Scans do not mount volumes, traverse symlinked roots, follow symlinks, or cross nested mounts. Overlapping roots and hardlinks are not counted twice. Allocation estimates do not promise unique freed bytes; modification time is not last use, and a checksum is not a restore test.

Unknown artifacts, backups, archives, migration capsules, and recovery data are protected. Producers explicitly register purpose, provenance, references, and retention. Disposable scratch must be owned, inactive, unreferenced, unchanged for 30 days, and pass identity/tree revalidation before removal. Cleanup has a durable plan and receipt. Never remove `/nix/store` directly.

Resolved candidate worktrees may expire after 30 days only with remote merged/closed evidence and a clean exact Git revision. Current, booted, rollback, last good, recent, and actively selected editor/configuration sources remain protected. Dirty worktrees and ignored files prevent automatic removal.

Use `dotctl cleanup --disposable` to execute cleanup after reviewing `dotctl cleanup --plan`. The execution checks eligibility again; it does not remove protected or unknown artifacts.

## Schedules and rollout

Nix declares daily refresh and weekly preparation systemd user units. The managed Mac uses launch agents. Daily refresh is at 09:00 local time; weekly preparation is Sunday at 04:00. Jobs catch up once after downtime, use locks, and never activate systems, merge PRs, restart applications, or reboot.

Schedules start disabled. First validate and apply the same committed baseline on Tracer and the managed Mac. Run `dotctl schedule accept` on each actual host. Copy the resulting local acceptance JSON files to the other host's acceptance directory, then use `dotctl schedule enable`. Linux mocks do not substitute for Mac acceptance. Codex authentication and preferences stay machine-local.

Use `dotctl schedule status` to inspect the local execution gate and `dotctl schedule disable` to close it and unload or stop the host jobs.

The migration baseline was preserved before implementation in a hash-verified local backup. Existing pending work is part of the full intended workstation configuration. Do not activate a partial clean tree that omits it. The canonical branch must contain the reviewed rewrite before routine background preparation starts.

## Platform exceptions retained from main

The managed company Mac uses **Claude Code**, excludes Codex desktop/CLI, and disables AI editor extras and the Nix language extra. Shared personal environments retain Codex. Deterministic Mac preparation still produces a reviewed package candidate; a failed Mac update requests local Claude/manual repair instead of invoking Codex. The existing verified Lan Mouse app and login behavior remain part of the Mac profile.

WezTerm nightly has a mutable upstream identity. It remains declared and installed, but a review manifest lists it as a manual hold instead of pretending `latest` is a version lock or blocking unrelated package updates.

Tracer prepares both personal and managed editor lock variants in separate isolated runtimes. On the work Mac, apply a reviewed committed editor revision separately with `dotctl apply --group editor macos-managed`. Native Mac acceptance verifies the actual installed packages, configuration links, and editor runtime. Applied editor configuration is selected through a retained source pointer so the next ordinary Neovim launch uses the reviewed specs and locks.

Manual driver recipe proposals can enter the same pipeline with `dotctl prepare drivers --from <committed-revision>`. The proposal must descend from the canonical base and stay within the driver group. Full build validation does not replace game, display, or loaded-driver verification.

The history archiver restored from main is `scripts/codex/archive.py`. Its output root, `~/Archives/codex-history`, is protected and indexed. No export or uninstall is run as part of this rewrite.
