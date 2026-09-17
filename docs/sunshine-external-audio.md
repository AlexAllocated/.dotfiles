# Sunshine capture-only fork

Our optional Windows patch separates capture from Windows default-device ownership.
The fork is <https://github.com/AlexAllocated/Sunshine>. Exact source and build
revisions are in `platforms/windows/sunshine-fork.json`; the feature branch excludes
the personal build workflow. This is not an upstream release or signed LizardByte build.

## Build and fetch

The personal build branch runs Sunshine's native Windows workflow, including tests
and packaging. Retrieve its pinned successful artifact with:

```bash
bash scripts/windows/fetch-sunshine-fork.sh
```

This fails closed if the run is pending, failed, or for a different commit. It caches
the download under `~/.cache/dotfiles/sunshine`, checks the cached archive's checksum
on repeat runs, and never changes the running Sunshine service. GitHub artifacts expire; a replacement run
must be reviewed and explicitly repinned, not silently selected as "latest".

The fetcher's offline regression tests use a fake GitHub command and isolated caches:

```bash
bash scripts/windows/tests/test-fetch-sunshine-fork.sh
```

## Behavior

The fork adds `external_audio = enabled` on Windows. An explicit `audio_sink` is
required. It disables default-device switching and restoration, virtual-sink
selection, format changes, and automatic Steam audio driver installation. The
selected endpoint is captured directly; missing endpoints do not fall back to an
unrelated device. Moonlight's host-playback toggle no longer manages local playback.
The option defaults to disabled; Linux and macOS behavior is unchanged.

## Activation gate

Do not enable this in the stock installed build. The Windows reconciliation scripts
honor a machine-local `sunshine-fork/active.json` under the dotfiles LocalAppData
directory only when its binary hash matches the installed Sunshine executable.
An activated fork is excluded from WinGet import; a missing marker preserves stock
behavior, and a mismatched marker fails closed. Before activation:

- Back up the full Sunshine installation, configuration, pairing state, and service
  registration. Preserve a tested rollback path and SSH access.
- Arrange a reconnect window; replacing Sunshine interrupts Moonlight.
- Configure AMPS to feed the selected streaming endpoint explicitly. Its existing
  automatic Moonlight detection relies on the default-device transition that this
  patch removes. Do not assume the new setting alone preserves that integration.
- Install the complete build, not just its executable, and verify configuration,
  client pairing, audio, device changes, reconnect, and service startup.
- Only then update the declarative configuration and prevent WinGet from replacing
  the pinned fork with stock Sunshine. Do not block stock updates prematurely.

`scripts/windows/install-sunshine-fork.ps1` has explicit `Stage`, `Deploy`,
`Rollback`, and `Confirm` modes. Stage accepts a new `StateDirectory`, verified
`ArchivePath`, `ExpectedArchiveHash`, and pinned `BuildRevision`; it does not stop
services. Deploy requires elevation and that staged directory. It backs up Sunshine
and AMPS saved state, preserves the installation path, and configures an explicit
AMPS **Moonlight** output node feeding Steam Streaming Speakers. Existing main
output routes remain independent. Phone audio follows this listening feed, not OBS.

Deployment failure attempts immediate rollback. There is deliberately no scheduled
watchdog. Once the user verifies Moonlight picture and sound, use Confirm with the
same state directory. Recovery files remain under the machine-local recovery path
recorded in `plan.json`; elevated Rollback can restore the original installation and
remove only the migration-owned AMPS node. Do not commit those files: they contain
pairing information and machine-specific endpoint identities. No reboot or audio
driver reinstall is involved.

Native build validation for the pinned artifact passed on both x64 and ARM64:
605 tests passed and five environment-dependent tests were skipped on each target.
The six new Windows audio regression tests passed. Frontend build and isolated
browser configuration checks passed, as did fetcher regression tests and a cached
second fetch. On the initial deployment, the user confirmed Moonlight picture and
sound after reconnecting; AMPS stayed healthy with a separate Moonlight output.
Two subsequent Sunshine `Ensure` runs made no service restart or elevation request.
Future upgrades must repeat the live client check rather than assume this result.

## Upstream review

Sunshine's `AGENTS.md` prohibits coding agents from opening issues or PRs in the
LizardByte organization. Its contribution policy also requires human oversight and
a contributor-written PR description. The branch is prepared for human review;
upstream submission is not automated. Use the official PR template, disclose AI
assistance, and report only completed tests. The feature builds on upstream #5408;
Linux issue #4950 is related context, not fixed by this Windows-only change.
