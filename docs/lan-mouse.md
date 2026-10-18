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

The host-native `macos-managed` profile installs the architecture-matched
**Lan Mouse v0.11.0** app from the project's official release, verifies its
published checksum and bundle metadata, removes only the app's downloaded
quarantine attribute, and registers a per-user login item. Apply it with:

```sh
dotctl apply macos-managed
```

On first setup, allow the requesting terminal to control System Events so it
can add the login item. macOS must also grant Lan Mouse Accessibility
permission and, when requested, Input Monitoring and Local Network access.
These permissions are never bypassed by the profile. When the desktop first
connects, compare and authorize its displayed TLS fingerprint in the Mac's Lan
Mouse menu. The Mac does not need an outgoing client entry unless it should
also control the desktop.

On NixOS, `systemctl --user status lan-mouse` shows connection logs. The
default emergency release chord is left Control + Shift + Super + Alt.
Clipboard sharing is not currently implemented by Lan Mouse.
