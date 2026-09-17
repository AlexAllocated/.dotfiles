# AMPS: multiple devices and phone calls

Implementation notes, September 7, 2026. Audio routing stays inside dotfiles,
with the existing Intrepid interface, sounds, WebView identity, and layout keys.

## Implemented graph model

- Add up to sixteen additional physical input/output nodes using machine-local,
  exact endpoint bindings. New inputs are not captured until wired.
- Preserve Main Input/Output as role-following conveniences, including Windows
  default selection, physical-device history, and Quest/Moonlight overrides.
- Each pinned output has independent rendering. A missing additional device
  leaves only its desired routes pending; unrelated routes keep playing.
- Phone Audio is an editable stereo source. Its default Main Output wire stays
  private. Drawing a wire or using Connect applies a cross-patch immediately,
  including application-facing buses; there is no extra phone confirmation.
- Preserve pure Clean Mic and the Comms/AI self-return guards.
- Preserve existing VAC endpoint IDs, OBS/app bindings, logical bus identifiers,
  filter settings, and application preferences. No extra VAC cable is needed.
- Remove-device confirmation lists the affected wire count; undo restores both
  the device and its wires. Unwired device additions do not alter defaults.
- Layout is node-driven, preserves saved positions, rejects stale asynchronous
  results, and safely drops deleted nodes during intervening meter refreshes.

## Phone ownership, timing, and privacy

The engine owns AudioPlaybackConnection and the hidden A2DP capture endpoint.
The tray controls it through a bounded, expiring, engine-session-specific local
mailbox. Meters use volatile loopback telemetry; no phone PCM is written to disk.

Phone Audio → Main Output uses Windows Listen, explicitly pinned to the engine's
applied physical output. It follows Main Output, including VR overrides, without
entering the default VAC bus. If that role cannot be resolved safely, reception
waits. Additional wires get independent native render workers and bounded,
clock-corrected queues. A stalled consumer cannot block reception or another sink.

At the user's request, the adjustable phone buffer feature is removed. Old
`bufferMs` values are accepted but ignored; later phone-setting writes omit them.
Automatic synchronization queues for cross-patches are internal implementation
details (currently 100 ms), not a playback-delay control. The native private
Main Output path has no AMPS reservoir. Windows and Bluetooth still add latency.

Earlier diagnostics found a source approximately 0.57% slower than the output
clock, beyond the old controller's 0.2% correction range. The revised smoothed
controller supports bounded ±2% correction, slews changes gradually, preserves
fractional sample phase, and passes long synthetic skew and burst regressions.
That fix remains useful for independent cross-patches. Residual rare/light pops
with AirPods were accepted; increasing buffer size did not eliminate them.
No further Bluetooth driver, hotspot, firmware, or radio changes are included.

Close-to-tray leaves reception active. Restart quiesces it before replacing the
engine; Exit shuts down the engine and disables native Listen. Relaunching an
already-running app signals the existing UI through a Windows event, so both
shortcut launch and tray clicks show the window through Tauri rather than raw
ShowWindow calls. Device cleanup no longer blocks normal close-to-tray handling.

## Migration and recovery

Controls schema 2 adds explicit physical bindings. Version-1 state receives the
previously fixed private phone route in memory. Only a successful edit commits
schema 2; deleting that route is then respected on later launches. Current AMPS
state takes precedence, unknown schemas fail without overwrite, and staged
changes roll back together on backend or persistence errors.

The deployment reconciler backs up binaries, controls, phone preferences, device
history, startup registration, and endpoint names before installation. It checks
the applied engine revision and retains recovery backups. No reboot or driver
reinstall is required. Unchanged reconciliation must not rebuild or restart.

## Native iPhone calls: blocked at registration

An unpackaged probe could discover the phone but received DeniedBySystem from
PhoneLineTransportDevice.RequestAccessAsync. With the user's permission, an
isolated development package was registered with the required capabilities.

The packaged probe verified its actual package identity and obtained **Allowed**
phone-specific access. Nevertheless, RegisterApp returned success while
IsRegistered remained false, both after a five-second settling period and from a
fresh transport instance. Bluetooth and phone services were running. The
prototype explicitly called UnregisterApp for its own attempted registration,
verified false, and was removed. It never connected, dialed, answered, or read
contacts/call history. This matches a [reported Microsoft API registration failure](https://learn.microsoft.com/en-ie/answers/questions/2244199/phonelinetransportdevice-registration-failure);
it is not proof that every Windows installation behaves this way.

No fake call controls or microphone-to-iPhone node are exposed. The following
remain gated on obtaining a real registered call line:

- Answer, decline, hang up, and real call-state events inside AMPS.
- Independent call receive/transmit graph ports and a low-latency microphone send.
- Proven caller-origin feedback protection through intermediate mixers.
- Explicit user-assisted incoming-call, two-way audio, and privacy tests.
- Testing Quest and AirPods separately; Phone Link documents Bluetooth-headset
  relay limitations and does not prove an AMPS route will work.

Developer Mode was enabled only for the authorized local investigation, not
silently added to the normal Windows reconciliation policy. No trust certificate,
Secure Boot change, service impersonation, or Phone Link identity was used.

Primary references:

- [Windows remote audio playback](https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/enable-remote-audio-playback)
- [PhoneLineTransportDevice](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.calls.phonelinetransportdevice?view=winrt-26100)
- [RegisterApp requirements](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.calls.phonelinetransportdevice.registerapp?view=winrt-26100)
- [Windows package identity](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)
- [Phone Link call limitations](https://support.microsoft.com/en-us/windows/apps/phonelink/troubleshooting-calls-in-the-phone-link)

## Verification

Rust tests cover migration, reload, undo/redo, bounded fan-out, clock skew,
stale/replayed commands, invalid ports, self-return, and transactional failure.
An opt-in Windows test opens two explicitly provided outputs and renders only
silence; it verifies one route continues after the other is dropped.

The browser suite uses an isolated mock bridge, not live phone audio. It covers
device add/remove/undo, immediate phone wiring from the panel and canvas, removed buffer controls,
waveforms, stored layouts, and desktop/tablet sizing. Native window close/tray
interaction and actual phone listening remain separate live acceptance checks.
