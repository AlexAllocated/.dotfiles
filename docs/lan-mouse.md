# Keyboard and mouse sharing

The NixOS desktop uses [Lan Mouse](https://github.com/feschber/lan-mouse)
instead of Synergy/Deskflow. Under Wayland, Synergy and Deskflow require an
InputCapture portal that niri does not currently implement. Lan Mouse uses
niri's supported layer-shell capture and wlroots virtual-input protocols.

The package, graphical-session service, and UDP 4242 firewall rule are
declarative. Peer names, addresses, positions, and TLS fingerprints remain in
the machine-local `~/.config/lan-mouse/config.toml` because they identify
specific hardware.

## macOS peer

Install the matching `lan-mouse-macos-*.zip` from the project's
[latest release](https://github.com/feschber/lan-mouse/releases/latest), move
**Lan Mouse.app** into Applications, and run:

```sh
xattr -rd com.apple.quarantine "/Applications/Lan Mouse.app"
open -a "Lan Mouse"
```

macOS must grant Lan Mouse Accessibility permission. When the desktop first
connects, authorize its displayed TLS fingerprint in the Mac's Lan Mouse menu.
The Mac does not need an outgoing client entry unless it should also control
the desktop.

On NixOS, `systemctl --user status lan-mouse` shows connection logs. The
default emergency release chord is left Control + Shift + Super + Alt.
Clipboard sharing is not currently implemented by Lan Mouse.
