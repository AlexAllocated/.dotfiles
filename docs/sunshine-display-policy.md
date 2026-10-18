# Sunshine display policy

Tracer streams a virtual display at the resolution and frame rate requested by
the client. With the LG active, it extends the desktop without changing the LG's
resolution, refresh rate, or HDR. With the LG off, it is the sole display. Selection runs before
encoder initialization on both launch and reconnect. Reconnect after changing
the LG's power state; seamless switching during an existing stream is not promised.

## NixOS

`dotfiles.desktop.sunshine.mode = "adaptive"` pins Niri's virtual-output branch
at `7fd585dd44ed67644977dd9561bb6e8b3837f8f7` and uses Sunshine's Wayland capture
backend with NVIDIA encoding. The patch is not yet merged upstream. The regular
Niri package and KMS/session capture modes remain available to other hosts.

`sunshine-display-policy.py` creates/resizes `Moonlight`, placed to the right of the
active LG using its logical bounds, at global y=0 to match the output-follow
service, or at the origin when headless. On disconnect
it removes the virtual output if the LG is available, but retains it when it is
the last output so the desktop stays usable headlessly. Idle startup does not
create an extra screen when the LG is available. The old iPad dummy EDID is not used.

The virtual output uses 175% scaling. After a resolution, scale, or position change, the
pre-stream hook briefly moves it one pixel and back to refresh Xwayland's output
geometry. Otherwise X11 applications can retain the old desktop size and clamp
clicks to its edges even while Niri and Sunshine show the new resolution. An
unchanged reconnect does not repeat this refresh; physical LG placement is untouched.

The adaptive launcher pins capture buffers to the NVIDIA render device, discovered
by its kernel driver rather than a volatile device number. With no physical monitor,
Sunshine's automatic selection otherwise falls back to `renderD128`, which can be
the integrated GPU and cause incompatible capture buffers and a black stream.
This profile requires exactly one NVIDIA render device and refuses ambiguous GPUs.

Tracer also pins Niri's primary renderer to `/dev/dri/nvidia-render`, a udev alias
matched by the NVIDIA driver. Automatic selection can choose the integrated GPU
when the LG is off at login. In that case Niri cannot import Sunshine's NVIDIA
capture buffers, and the stream connects with a black image. Pinning both sides
avoids this dependency on monitor power and DRM probe order. This renderer choice
takes effect at the next graphical-session start, not on configuration reload.

Sunshine remains a system-managed service using the existing identity, certificates,
and paired clients. Adaptive capture needs the Niri user session; unlike KMS, it
does not provide greeter capture. The service waits for Niri and restarts when its
socket disappears. Applying a new compositor build does not replace the running
compositor: save work and restart the graphical session to activate it.

The local `niri-virtual-presentation-feedback.patch` reports presentation for
visible surfaces after a virtual-output capture finishes rendering. It covers
wlr screencopy, ext image-copy capture, and full-output PipeWire screencasts,
without adding another render pass or acknowledging hidden windows. This prevents
Chrome's 1.5-second fullscreen timeout on the streamed display. An uncaptured
virtual output has no presentation consumer and does not report presentation.

After building the Niri package, test its binary with
`python3 tests/test_niri_fullscreen.py --niri /path/to/built/niri`. The test needs
GPU-backed Chrome or Chromium, Node 22+, and grim on `PATH` (or explicit `--chrome`,
`--node`, and `--grim` paths). It starts a separate compositor and temporary browser
profile, captures the virtual output, and checks fullscreen persistence and hidden
window feedback. It never attaches to the running desktop. Use `--expect-exit` to
verify the unpatched failure; logs and results are retained in a temporary directory.

Client sizes are bounded to 320–7680 pixels wide, 240–4320 pixels high, and 10–240 Hz.
These are policy limits, not guarantees that the encoder/client supports every
combination.

### Moving running games

Keep WoW in **Windowed (Fullscreen)** at automatic/native resolution. The launcher
preserves that mode, and Niri's WoW rule opens the game fullscreen. Do not force
`GxMaximize=0`: that asks Wine for a normal window while Niri asks for fullscreen.
The shared Battle.net prefix remains at 96 DPI on both displays; changing its
global DPI during a running session causes inconsistent UI and input scaling.

With both outputs active, `Meta+Ctrl+Shift+Right` moves the focused column from
the LG to the iPad; `Meta+Ctrl+Shift+Left` moves it back. Battle.net and each game
are separate windows and can be moved independently. When the LG disappears,
Niri evacuates its workspaces, and the output-follow service restores the saved
workspaces when the LG returns.

The `xwayland-satellite-fractional-size.patch` rounds configured logical sizes
back to physical pixels. Before this fix, fullscreen on the 2732×2048 iPad at
175% became 2731×2047. A live WoW move then requested an exit from fullscreen
and recreated its window on the LG. The regression test covers LG → iPad → LG;
an isolated live X11 test verifies 3440×1440 → 2732×2048 → 3440×1440. Full game
handoff and LG power-cycle behavior still require verification with the patched
Xwayland session. Installing the package does not replace an already running
Xwayland-satellite process; activate it at the next graphical session start.

The Wine alias-repair helper described in [wine-display-sync.md](wine-display-sync.md)
remains necessary independently of this pixel-rounding correction.

## Windows

`output_name` selects the machine-local VDD identity and `preferred_output_name`
is cleared so an active LG does not override it. `ensure_active` enables the VDD
without making it primary or disabling the LG. The VDD uses Sunshine's automatic
resolution, refresh, and HDR handling and its existing disconnect restoration.

`configure-sunshine-virtual-display.ps1` rejects binaries without this option
before writing the Sunshine configuration. Deploy and verify the adaptive fork
before reconciling Windows; an older binary cannot implement the new policy.
The legacy `set-sunshine-display-session.ps1` entrypoint does not force a topology;
Sunshine owns activation and restoration.

Windows must be tested after booting Windows. Linux build/test results do not
verify Windows monitor detection or VDD behavior.
