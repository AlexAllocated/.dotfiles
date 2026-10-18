# Battle.net monitor updates

The Battle.net launcher starts one `wine-display-sync` helper in its shared
Proton 11 session. The helper waits for registry change notifications; it
does not poll mouse input, resize windows, change DPI, or restart games. Logs
are in `~/.local/state/wine-display-sync/battlenet.log`.

Wine 11 can discover the correct XRandR displays while its numbered monitor
aliases still refer to previous source records. In the observed failure, the
LG game window was 3440×1440, but Wine exposed only a 2732×2048 monitor and
limited mouse capture to 2732 pixels horizontally. Restarting just the game
reuses the launcher's damaged display records.

The bug is in updating an existing registry symbolic link: Wine writes the
new `SymbolicLinkValue` into the old source record rather than changing the
alias itself. The helper opens the alias with `REG_OPTION_OPEN_LINK`, applies
and verifies the intended target, removes the misplaced value, then asks
Wine to refresh its shared display cache. Source records and game settings
are preserved. The helper holds Wine's display initialization mutex while
repairing records and accepts targets only inside the same GPU's `Sources`
subtree. All aliases are inspected before applying changes so exchanged
monitor indexes cannot produce a repair loop.

This workaround is restricted to Wine 11.0 because the cache refresh uses a
version-specific Wine API. Revalidate it when updating GE-Proton, including
whether upstream `win32u/sysparams.c:write_source_to_registry` still needs it.
The invisible helper accepts session shutdown and uses a named mutex to
prevent duplicate instances.

The launcher waits for a real Battle.net process in the matching prefix before
starting the watcher. The watcher registers as a Wine system process and observes
the session shutdown event, so it cannot keep an otherwise closed session alive.
The process API, like the display API above, is restricted to Wine 11.0.

Registry setup and the watcher use Proton's `runinprefix` verb. `run` runs through
`steam.exe`, whose completion waits for all application processes in the prefix;
an unrelated game or orphan overlay can therefore block even a finished registry
command indefinitely. Only the application launch uses `run`. Registry commands
have a 30-second timeout, and setup is serialized with a lock released before
launching the application. Launcher output is retained in
`~/.local/state/battlenet/launcher.log`.
The watcher also sets `WINELOADERNOEXEC=1`: otherwise Wine inserts a `start.exe`
parent that waits for the watcher and itself prevents session shutdown.

## Setup audit (October 2026)

- Confirmed launch failure: an orphan Battle.net overlay outlived the launcher;
  the next registry preflight waited for that unrelated process through Proton's
  session-wide `run` completion. Direct `runinprefix` commands returned in under
  one second in the same session. The orphaned diagnostic session was stopped.
- Confirmed helper lifetime problem: the display watcher and its `start.exe`
  parent could keep the prefix alive. The system-process registration and direct
  loader path now allow both the application and watcher to exit naturally.
- Confirmed update delay: UMU attempted a runtime download between registry
  commands, rejected a checksum mismatch, and fell back to the installed
  runtime. Normal Battle.net and Guild Wars 2 launches now skip update checks;
  initial runtime installation still works. With games closed, explicitly use
  `UMU_RUNTIME_UPDATE=1 battlenet` or `UMU_RUNTIME_UPDATE=1 guild-wars-2` to check
  for runtime updates and inspect the logs before testing games.
- Runtime ownership: the desktop entry, Heroes shortcut, and authentication URI
  handler use the same Battle.net launcher. No alternate Steam shortcut was
  present. Guild Wars 2 has a separate prefix and Nix-pinned GE runtime.
- Battle.net now uses a hash-verified snapshot of the tested Proton Experimental
  build. Steam can update its own installation without changing the runtime of
  an existing Battle.net session. Nix rolls back the runtime, but does not roll
  back prefix data; do not downgrade a migrated prefix without testing it.
- Display and input: fixed 96 DPI is applied only to a new session; X11 modeset
  handling, monitor alias repairs, and Niri focus/fullscreen rules retain their
  separate purposes. Private Wine display APIs remain version-gated. The tests
  validate registry repair, not every physical display hotplug or game UI.
- October 4 recurrence: Battle.net and WoW aborted in `monitor_get_dpi` while
  encoding a display scaling ratio. Steam had updated Proton Experimental on
  October 2 (build 25646868), reversing the previous `EmulateModeset` option
  interpretation. In a disposable prefix, `Y` allowed Wine to report 1920×1080
  while Xwayland remained at 3440×1440; `N` kept Wine at 3440×1440. The launcher
  now writes `N`. `wine-modeset-policy-test.exe --expect-native` verifies the
  behavior and queries raw DPI on every monitor after a resolution request;
  `--expect-emulated` is the negative control with the old `Y` setting. Run
  these only in a disposable prefix under Xwayland. A fresh session recovered
  this incident; the exact bad display values from the crashed session were
  not retained. Runtime updates still require revalidating this policy.
- Graphics: Diablo's reported-memory override is executable-specific, not a
  hard VRAM quota. No global Wine, Proton, DXVK, or VKD3D override was found in
  the desktop service environment. This launch fix does not establish that
  every game's GPU memory behavior is safe.
- Tray: the XEmbed bridge was active without restarts. It presents Wine icons;
  it does not own or terminate the applications behind them.

Validation included the full Tracer system build and flake checks, prefix-aware
process matching, 26 registry assertions, 13 live watcher assertions, a registry
query while another application remained open, and automatic watcher shutdown
after the last test application exited. The lifecycle test caught the extra
`start.exe` parent before activation.

`tests/wine-display-sync.c` exercises real Wine registry links using disposable
records. Its default mode tests the repair directly under a private HKCU key;
`--watch-test` creates an unreferenced test record under the observed display
registry and verifies the running helper repairs it automatically. Both modes
remove their fixtures on success. They do not alter physical monitor records.

## Mixed-display DPI regression (October 5, 2026)

The display bridge inferred an output's fractional scale from each window's
preferred scale. Those window events can arrive before the window enters its
new output, so moving a window between LG and iPad could assign 175% scaling
to the LG. Logs showed the global X11 scale changing between 1 and 1.75 while
the output configuration stayed unchanged. This also affects Electron apps:
their desktop DPI can change independently of the user's zoom setting.

`patches/xwayland-satellite-output-dpi.patch` derives fractional output scaling
from the output's pixel mode and logical dimensions, rounded to the protocol's
1/120 granularity. Window scale events continue to control that window's
viewport, but cannot rewrite global output scaling. The regression test sends
both orderings of window-move/scale events, then disconnects the LG and changes
the tablet's real output scale. Monitor rotation is accounted for when deriving
the ratio. Without logical dimensions, the bridge retains `wl_output.scale`.

Tracer also sets `dotfiles.desktop.xwaylandPrimaryOutput = "DP-1"`. The bridge
keeps the LG primary while its output is active; when it disappears, it keeps
an active fallback, such as Moonlight, and restores LG priority when it returns.
Keyboard and pointer focus still work normally, but no longer change the global
X11 primary monitor. This prevents WoW's default-monitor selection from following
the mouse onto the iPad. Other hosts retain upstream behavior unless they opt in.

Validation includes 86 library tests, an old-code negative control for the DPI
regression, and eight live cross-display focus changes with LG primary and 96 DPI
unchanged. The launcher also supplies its native installation directory and
working directory explicitly: UMU cannot infer those from a Windows-form path.
An initial post-restart missing-DLL dialog did not recur on subsequent launches;
the loader trace loaded the installed `battle.net.dll`. Its original cause was
not captured, so this does not establish that every launcher startup fault is
fixed.

## Mouse coordinates after moving a window (October 13, 2026)

Moving Codex to the iPad with `Mod+Shift+Ctrl+L` exposed a separate input bug.
Xwayland Satellite copied the surface scale into the pointer when it entered
the window. A later fractional-scale event updated the displayed viewport but
left mouse motion using the old copy. Moving out and back, or moving the window
again, could hide the problem by generating another pointer-enter event.

`patches/xwayland-satellite-pointer-scale.patch` reads the current surface scale
for each pointer-motion event. It preserves decoration handling and drops stale
surface events safely. This applies to all X11 windows, including Wine clients,
and does not change Moonlight's input-device mapping or the window-move shortcut.

The regression sends real Wayland pointer events across repeated 100%, 175%,
and 200% transitions without another pointer-enter event. The old bridge sends
`(100, 200)` where the 175% surface requires `(175, 350)`; the patched bridge
passes this test and all 89 library tests. An already running bridge must be
restarted to load the patch; switching the Nix generation alone cannot replace
that process.

The affected session also contained two invisible Forever processes and an old
Blizzard crash reporter. They were cleared with permission. Separate Forever
reports contain `BC_VERIFY(result == casResult::Success)` and an Aurora network
state assertion; the DPI patch does not establish that those game errors are
fixed. Preserve the shared `Data`, addons, and `WTF` while investigating them.

## Overnight launcher audit (October 13, 2026)

The overnight compositor logs show the streaming output disappearing, followed
by the LG disconnecting at 23:59. Xwayland had no outputs until the LG returned
at 14:21 the following day. Several previous helper sessions ended with
`BadRROutput` from `RRGetOutputInfo`. Wine queries a cached monitor ID without
handling that protocol error; Xlib's default handler terminates the caller.
The logs establish this hotplug failure, but do not establish that it caused
every historical black Battle.net window.

The output-follow service also restores X11's primary monitor using Niri's
resolved LG connector after startup or hotplug. This covers connector renumbering
and the currently running bridge before its next session restart. It never runs
on pointer focus changes or changes display modes.

Output following now also recognizes adaptive Sunshine's active `Moonlight`
virtual output, instead of requiring the retired physical dummy's make/model
identifier. This restores its intended origin and workspace-following behavior
when the LG leaves or returns.

`packages/battlenet-proton.nix` preserves the tested October 8 Wine 11 runtime
and supplies patched 32-bit and 64-bit XRandR libraries only inside that runtime.
Queries of removed outputs and CRTCs return `NULL`, which Wine already handles.
The error handling is restricted to the individual request, error code, and
opcode while holding the Xlib display lock. Unrelated errors still reach the
application's handler. Regression checks use real X11 requests on private Xvfb
servers, including valid queries after a failed query.

The runtime source is an immutable, hash-verified archive of Steam's installed
Proton build; it contains no game prefix or personal settings. If it is missing
from the store, run `python3 scripts/gaming/stage-battlenet-proton.py` from this
checkout with the matching Steam build installed. An updated or modified build
is rejected. Future runtime updates require staging and compatibility testing
before changing `pins/battlenet-proton.json`. Steam's materialized file fixups
are already applied and are not repeated against the immutable store path.

The display watcher logs its runtime, process identity, and timestamped topology
changes (monitor count, desktop bounds, and system DPI). It reports repair
failures as failures, and gets at most three delayed retries while a real Windows
application remains alive in the prefix. Duplicate watchers and unsupported runtimes do not retry. This
does not introduce a continuous process or input polling loop.

Live testing also reproduced a collapsed-alias case: both numbered monitor
aliases pointed to the iPad source, and fresh Wine processes saw a `WinDisc`
placeholder instead of the LG. Misplaced link values alone cannot reconstruct
the lost binding. The supervisor now publishes XRandR's actual active output
IDs in Wine's source order (including primary selection and mirrored-output
handling). The Wine helper verifies those IDs against the same GPU's source
records and repairs each alias independently, even when no misplaced value
remains. Incomplete source publication is left alone until the next event.

The publisher subscribes only to XRandR output/resource events. The helper
observes both registry notifications and atomic plan-file changes in a dedicated
subdirectory, so a late topology update cannot be missed. Position and size
changes also update the plan when output IDs stay the same; these notifications
force Wine to rebuild its cache after the streaming output is repositioned.
The publisher exits with the session helper. Its supervisor is owned by an on-demand user service,
so exiting a short-lived launcher focus/URI command cannot kill its children.
The service stops with the graphical session, and normal Wine shutdown ends it
after the last application closes. Regression fixtures cover collapsed aliases, missing
sources, mirrored outputs, primary return, and an empty display topology.

Force quit now also drains leftover Wine shell/service processes in affected
idle prefixes. It uses the launcher's startup lock, preserves unrelated
prefixes, and leaves the shared services alive if any other Windows application
is present, including Diablo or Overwatch. This removes the old invisible
Explorer instances without a global `wineserver -k`.

Three old sessions retained Xalia processes with exited leaders and live worker
threads. Proton's optional Steam UI-navigation helper could keep these sessions
alive after Battle.net exited. Battle.net now sets `PROTON_USE_XALIA=0`; ordinary
game keyboard, mouse, controller, and Tartarus mappings are not provided by that
helper. Idle-session recovery also recognizes an existing Xalia remnant.

Scaling remains a stable 96-DPI baseline in Wine and X11. The compositor applies
each window's output scale (100% LG, 175% iPad) and updates its viewport as it
moves. This is different from changing Wine's global `LogPixels` on focus: that
would reintroduce inconsistent game UI sizes and input geometry. Wine's current
X11 and Wayland drivers report a shared effective DPI; this setup does not claim
native Windows per-monitor DPI behavior for applications that require it.

`battlenet-diagnostics` reads the real session's monitor geometry, effective/raw
DPI, client bounds, and whether Battle.net/WoW respond to a bounded `WM_NULL`
request. It does not change resolution, send input, or force a repaint. Capture
its output before force quit if another frozen window occurs.

## Recovery audit follow-up (October 13, 2026)

The supervisor now recreates the XRandR publisher on every recovery attempt.
Previously, a failed publisher could leave subsequent helper retries without
fresh monitor data. A failed initial query removes the old plan and releases
its singleton lock; three failed snapshots during an output event invalidate
the plan and fail visibly instead of waiting indefinitely for another event.
The native helper then fails, allowing bounded recovery to establish a new
X11 connection and publish a fresh plan. Regression coverage disconnects a
real private Xvfb server and reconnects the publisher on the next attempt.
If recovery is exhausted, the user service posts one desktop notification
with the diagnostic and recovery commands. Ordinary shutdown does not notify.

Recovery also follows the whole prefix after the launcher closes. Diablo,
Overwatch, and other Windows applications keep it eligible for retries, while
leftover Explorer, Agent, and other known service processes do not. The tray
force-quit action preserves the display helper if another Windows application
remains; it drains the helper only when that prefix is idle. A process-level
regression exercises the force-quit action against private Battle.net, Diablo,
and helper fixtures and verifies that Diablo and its watcher survive.

The WoW configuration guard now reads the actual executable and matching Wine
prefix, including live threads after an exited leader, instead of depending
on a renamed or shortened kernel thread name. It covers all recognized Classic
executables and does not let a game in an unrelated prefix block this setup.

Sunshine preparation and Niri output following now agree on the virtual output's
position: to LG's right at y=0 when both are active, or at the origin when alone.
Previously, stream preparation bottom-aligned it, and the output-follow service
moved it again afterward. Keeping one layout rule avoids that extra transition.

## Rapid reconnect audit (October 13, 2026)

A rapid LG off/on cycle reproduced a missed transition: Niri was already back
to its previous state at the next one-second check, while X11 retained Moonlight
as primary. Wine then placed LG at negative coordinates. The output-follow guard
now checks the cached X11 primary during its existing output check and corrects
it only when necessary. `xrandr --current` avoids polling physical hardware;
normal checks do not send primary, mode, scale, or input changes. The resolved
connector is used on every check, including when connector numbering changes.

The native display helper also reports a failed notification wait as an error.
Previously, that path returned success, bypassing the supervisor's recovery and
failure notification. Its regression uses an actual failed Windows wait call.
