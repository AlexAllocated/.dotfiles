# Razer devices on NixOS

The native desktop uses two complementary tools:

- **Polychromatic/OpenRazer** manages lighting, DPI, polling rate, battery
  notifications, and other supported hardware settings.
- **Input Remapper** manages keyboard, keypad, and mouse-button mappings above
  the Linux `evdev`/`uinput` layer. Its mappings work in Plasma, niri, Hyprland,
  Mango, and other Wayland sessions.

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
translated. Ordinary Basilisk side-button and horizontal-wheel mappings were
translated too.

The Basilisk V3 Pro 35K Phantom Green's four Razer-private controls are now
bridged as well. At boot and reconnect, `razer-onboard` programs only the
mouse's volatile direct profile:

- underside profile button -> F13
- multi-function thumb trigger -> F14
- rear scroll-wheel mode button -> F15
- front scroll-wheel mode button -> F16

Input Remapper then translates F13-F16 into each recovered Synapse action.
The persistent onboard profile used by Windows is never written. The bridge
supports both the wired `1532:00d6` and wireless `1532:00d7` transports and
prefers wired when both are present.

Use `razer-onboard dump --profile direct` to inspect the live Linux layer,
`razer-onboard apply-linux` to reapply it, or `razer-onboard restore` to copy
those four controls from onboard profile 1 back into the volatile layer. The
native protocol support is proposed upstream in
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
