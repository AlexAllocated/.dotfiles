# Sunshine display policy

Tracer streams a virtual display at the resolution and frame rate requested by
the client. With the LG active, it extends the desktop without changing the LG's
resolution, refresh rate, or HDR. With the LG off, it is the sole display. Selection runs before
encoder initialization on both launch and reconnect. Reconnect after changing
the LG's power state; seamless switching during an existing stream is not promised.

## NixOS

`dotfiles.desktop.sunshine.mode = "adaptive"` pins Niri's virtual-output branch
at `dc0505f043028a8cc1e007d5760953753dec2d3b` and uses Sunshine's Wayland capture
backend with NVIDIA encoding. The patch is not yet merged upstream. The regular
Niri package and KMS/session capture modes remain available to other hosts.

`sunshine-display-policy.py` creates/resizes `Moonlight`, placed to the right of the
active LG using its logical bounds, or at the origin when headless. On disconnect
it removes the virtual output if the LG is available, but retains it when it is
the last output so the desktop stays usable headlessly. Idle startup does not
create an extra screen when the LG is available. The old iPad dummy EDID is not used.

The virtual output uses 150% scaling. After a resolution, scale, or position change, the
pre-stream hook briefly moves it one pixel and back to refresh Xwayland's output
geometry. Otherwise X11 applications can retain the old desktop size and clamp
clicks to its edges even while Niri and Sunshine show the new resolution. An
unchanged reconnect does not repeat this refresh; physical LG placement is untouched.

The adaptive launcher pins capture buffers to the NVIDIA render device, discovered
by its kernel driver rather than a volatile device number. With no physical monitor,
Sunshine's automatic selection otherwise falls back to `renderD128`, which can be
the integrated GPU and cause incompatible capture buffers and a black stream.
This profile requires exactly one NVIDIA render device and refuses ambiguous GPUs.

Sunshine remains a system-managed service using the existing identity, certificates,
and paired clients. Adaptive capture needs the Niri user session; unlike KMS, it
does not provide greeter capture. The service waits for Niri and restarts when its
socket disappears. Applying a new compositor build does not replace the running
compositor: save work and restart the graphical session to activate it.

Client sizes are bounded to 320–7680 pixels wide, 240–4320 pixels high, and 10–240 Hz.
These are policy limits, not guarantees that the encoder/client supports every
combination.

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
