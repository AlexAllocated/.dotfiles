# Desktop scaling

Niri owns each output's scale. Moonlight uses 175% and the LG uses 100%.
ChatGPT's packaged launcher selects native Wayland so it follows its output
without relying on the shared X11 DPI. Existing app zoom remains independent;
reset it after switching from Xwayland if the interface is too large.

Steam still requires Xwayland. `steam-display-scale.service` checks the main
Steam window's workspace and output once a second and copies that output's
scale to Steam's desktop accessibility slider. It does not follow keyboard
focus, auxiliary dialogs, or game windows. Hidden Steam windows are left alone
until the main window reappears. Monitor disconnects and workspace evacuation
are handled by reading the current workspace/output mapping on each pass.

Steam starts with `-cef-enable-debugging`. Its CEF endpoint must listen only on
`127.0.0.1:8080`; verify with `ss -ltnp`. The helper connects to the trusted local
`SharedJSContext` and uses the same `SteamClient.Settings.SetSetting` call as the
desktop slider. It sends only protobuf field 26010
(`accessibility_desktop_ui_scale`, float). Current Steam limits this slider to
50–200%; larger Niri scales are capped at 200% and logged. The helper leaves the
global 96-DPI Xwayland baseline, Wine settings, and game resolution unchanged.

This is an internal Steam API rather than a supported automation interface.
If Steam changes it, the helper logs an error and retries; it does not restart
Steam, alter installed client files, or write Steam's configuration on disk.
Disable the helper if manually adjusting Steam's slider: otherwise its next
pass restores the output's value. The last applied value remains in Steam
after the helper stops.

Validate with `node --test tests/test_steam_display_scale.mjs`, then move Steam
between real outputs and inspect `journalctl --user -u steam-display-scale`.
Check that its UI returns to 100% on the LG and grows to 175% on Moonlight,
including after changing output scale or disconnecting the physical monitor.
Verify the packaged ChatGPT launcher creates a native Wayland window and that
focus, shortcuts, and any floating windows still work in the actual app.
