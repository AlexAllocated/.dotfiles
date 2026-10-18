# Razer devices on NixOS

## Input Control editor

Open **Razer Input Control** from the launcher, the Razer tray menu, or run
`razer-keybind-editor`. One profile covers the Basilisk V3 Pro 35K, Huntsman V2
Analog, and Tartarus Pro. Select a control on its device schematic, record a key
or chord (including standalone modifiers), then save the assignment. The
HyperShift checkbox edits the alternate layer; “Hold HyperShift” assigns its
activation key. Duplicate creates an independent profile for all three devices,
including devices which previously inherited a default.

The Intrepid frame follows Torplex's Voyager V26 interface contract: Antonio,
black content fields, silver paired elbows, segmented rails, and gold headings.
Fonts and interaction sounds reuse AMPS's bundled assets. The sound button mutes
the short interaction cues; there is no background ambience.

**Save assignment** validates and saves without touching the running bindings.
**Apply profile** activates the profile across connected devices. The tray also
lists newly created profiles. Local changes live in
`~/.local/state/razer-profile/editor-overrides.json`, with previous versions in
`editor-backups/`. Nix rebuilds preserve these overrides while continuing to
provide imported defaults. Concurrent edits are rejected rather than overwritten.
Each applied transaction retains its compiled source for rollback.

The editor supports the mouse's nine existing remappable controls, keyboard
keys, keypad keys, thumb controls and wheel, plus HyperShift assignments. Primary
mouse clicks remain unchanged. Existing macros and inactive Tartarus keymaps are
preserved; this is not a macro sequencer or analog-actuation editor. Device
drawings are schematic, not manufacturer photographs. The keypad drawing follows
the [Razer default key assignments](https://dl.razerzone.com/master-guides/RazerSynapse3/TartarusV2-00000555-en.pdf).

## Existing tools

The native desktop uses two complementary tools:

- **Polychromatic/OpenRazer** manages lighting, DPI, polling rate, battery
  notifications, and other supported hardware settings.
- **Input Remapper** manages keyboard, keypad, and mouse-button mappings above
  the Linux `evdev`/`uinput` layer. Its mappings work in Plasma, niri, Mango,
  and other Wayland sessions.

The recovered Synapse 4 profiles are tracked under
`razer/input-remapper-2/presets/`. Home Manager seeds writable copies into
`~/.config/input-remapper-2/presets/` without replacing later local edits.

## Using the migrated profiles

1. Open **Input Remapper** from the application launcher.
2. Select the Basilisk, Tartarus, or Huntsman.
3. Select a migrated profile and choose **Apply**.
4. Enable **Autoload** only for the profile that should be the device default.

Run `razer-profile-sync` to install newly tracked profiles without overwriting
local changes. Run `razer-profile-sync --force` to restore every tracked
profile to its migrated baseline.

Open **Polychromatic** to configure lighting and the supported hardware
settings. The recovered Windows baseline was:

- Basilisk: 1800 DPI, 1000 Hz, 70% brightness
- Tartarus: 100% brightness
- Huntsman: 100% brightness

## Migration limits

The full conversion inventory is in `razer/migration-report.json`. The eight
Tartarus layouts and the Huntsman Caps Lock/Escape swap were directly
translated. The Huntsman's onboard profile now performs that complete swap on
the keyboard itself, so its equivalent Input Remapper preset is retained for
recovery but is not autoloaded; enabling both layers would swap the keys back.
Ordinary Basilisk side-button and horizontal-wheel mappings were translated
too.

On the unified-profile setup, `razer-profile apply-profile Heroes` selects
one layout across the connected mouse, keyboard, and keypad. Simple Basilisk
key actions are programmed into both its active and default onboard profiles:
Heroes uses Z/B for left/right wheel tilt and Left Alt for the clutch.
Software-only actions, such as macros and shared HyperShift, still use Input
Remapper. Private controls use F13-F16 bridges only for those software actions;
their presets explicitly select the mouse's keyboard event interface.

The unified profile manager keeps the default onboard button assignments aligned
with the selected profile, so wireless sleep/wake and power cycling cannot fall
back to an older layout while the USB receiver stays connected. This also changes
the default button layout seen on another OS. Before changing onboard bindings,
the previous assignments are saved under
`~/.local/state/razer-profile/onboard-backups/`; only changed buttons are written
and each write is read back. DPI, lighting, polling rate, macros, and other onboard
slots are preserved. Failed onboard writes attempt to restore the old assignments.
Repeated application of the same profile does not rewrite those flash bindings.
The startup/hotplug service retains its bounded retries; it does not periodically
reprogram the mouse.

Both wired `1532:00d6` and wireless `1532:00d7` transports are supported, with wired
preferred when both are present. Run `razer-profile reapply-profile` to restore
the selected layout, or `razer-profile validate` to check all generated hardware
profiles without accessing the mouse. Native protocol support is proposed in
[razerqdhid PR #6](https://github.com/geezmolycos/razerqdhid/pull/6).

These remaining Synapse-only features need separate treatment:

- Synapse HyperShift layers and its `Valheim Dodge` macro were preserved in the
  report but are not activated by the initial conversion.
- Huntsman analog actuation and Snap Tap are firmware/Synapse features rather
  than ordinary key remaps; Input Remapper cannot reproduce them exactly.
- Synapse's executable-based automatic profile switching is not imported.
  Input Remapper autoloads one default per device; game presets are selected
  manually until a native launcher hook is added.

The Windows filesystem was read only throughout extraction. No Synapse or
Windows files were modified.
