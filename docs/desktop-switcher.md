# Desktop switcher

`desktop-switch` moves between the configured Wayland desktops without stopping
the system-level Sunshine server or visiting SDDM's session chooser. Save work
before an immediate switch: it ends the entire graphical login, not just the
terminal that launched it.

After the switcher is first installed, one normal reboot is required so SDDM
loads its dispatcher configuration. Until that reboot, immediate switching is
safely refused while `--next` remains available. Installing or updating the
switcher never reboots the computer automatically.

## Common commands

```console
desktop-switch --list
desktop-switch --status
desktop-switch niri
desktop-switch mango
desktop-switch plasma
```

The compositor short names select their Noctalia sessions. Every explicit
target is also available:

- `niri-noctalia`
- `mango-noctalia`
- `plasma`

Use `desktop-switch --restart` to restart the current desktop, or use
`desktop-switch --next TARGET` to remember a choice without ending the current
session. The latter takes effect at the next login or boot.

## Remote behavior and recovery

An immediate switch records the target and asks the graphical dispatcher to
exit cleanly. SDDM automatically logs Alex back in through a fresh dispatcher.
Moonlight may freeze or disconnect during the handoff; reconnect to the same
Sunshine host after a few seconds.

Before returning to SDDM, the dispatcher exits Alex's lingering per-user
systemd manager. The next login therefore starts a fresh user manager and DBus
activation environment rather than carrying compositor sockets or failed
desktop services across the boundary. Sunshine and the recovery web terminal
are system services and remain alive during this reset.

The dispatcher falls back to Plasma after three short launches of the same
non-Plasma target within two minutes. A desktop that stays alive for 90 seconds
is considered stable and its failure history is cleared.

If the graphical handoff still fails, use the recovery web terminal at
`http://192.168.0.117:7681` and run:

```console
desktop-switch --next plasma
desktop-switch --status
```

Then restart the graphical login from the local console or reboot only when it
is safe to do so. The switcher itself never reboots the computer.
