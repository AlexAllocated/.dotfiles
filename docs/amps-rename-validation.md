# AMPS rename verification

Verified on Windows with Ubuntu WSL, 2026-09-06. The main interface heading is
**Audio Mixing and Processing Subsystem**; shorter system names use AMPS.

## Automated checks

- Native Windows release builds of `amps` and `amps-ui` pass with locked dependencies.
- Native Rust tests: 32 passed; UI crate test/build target passes.
- Frontend tests: 6 passed; TypeScript and production Vite build pass.
- Isolated browser checks pass at desktop, native-window, iPad, narrow, and minimum
  window sizes. The full heading fits, outer-page overflow is absent, and graph
  editing, waveforms, layout persistence, and undo/redo pass.
- Windows PowerShell parsing and isolated migration/OBS fixture tests pass.
- Fixtures cover legacy migration, fresh setup, existing-state precedence,
  customized configuration, and rollback of binaries, configuration, endpoint
  names, browser preferences, shortcuts, and startup registrations.
- Ubuntu Home Manager build and live activation pass.
- The all-systems flake check evaluates the configurations but cannot build the
  macOS checks on this Linux host (platform mismatch). The native Linux quality,
  Home Manager module API, Tracer contract, and Firefox wrapper checks all pass.

## Live cutover

- All fourteen VAC endpoint IDs remain unchanged; only friendly names change.
- Saved controls and physical-device history are byte-identical to the recovery
  snapshot. The running engine acknowledges the same saved revision and routes,
  with the previous physical input/output and suppression settings.
- Saved chart-layout JSON and sound preferences are unchanged. The five bundled
  sound files are byte-identical to their AudioArray versions.
- OBS's scene file is byte-identical, and all four existing capture bindings
  resolve through AMPS. Existing source labels intentionally remain OBS-owned.
- Exactly one AMPS engine and one tray supervisor run. A second UI launch exits
  without replacing either process. The legacy startup task and Start-menu
  shortcut are retired only after verification.
- A second reconciliation performs no rebuild, restart, elevation, or preference
  rewrite. Both development shortcuts resolve to `packages/amps`.

Recovery snapshots remain under `%LOCALAPPDATA%\AMPS\backups`. The old installation
and preferences remain available; no reboot or VAC reinstall was performed.

The Windows Computer Use tool could not initialize from the WSL task directory.
Native window title/startup/single-instance checks passed; close-to-tray, restart,
and full-exit handlers were reviewed and retain their previous implementation,
but their actual tray-menu clicks were not automated in this session.

## Repeat the isolated checks

Run `npm test` and `npm run build` in `packages/amps/ui`. Use the browser harness
documented in the [AMPS README](../packages/amps/README.md). On Windows, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/tests/amps-migration.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/tests/amps-obs.tests.ps1
```

These fixtures do not manipulate the live audio graph or OBS configuration.
