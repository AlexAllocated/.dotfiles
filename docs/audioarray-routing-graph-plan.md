# AudioArray: unified routing canvas design and rollout

Status: implementation, September 5, 2026. The user approved implementing,
installing, and verifying the existing-capability canvas without another approval
checkpoint. The original seven-bus baseline is `8af62e4`. The runtime foundation,
React Flow/ELK canvas, and supported editing are implemented; see the
[current AudioArray guide](../packages/audioarray/README.md) for actual behavior.

The detailed design below retains longer-term targets, not a claim that every
future gate is complete. Current boundaries: undo history is session-local;
device selection retains the existing Windows coordinator; since September 6,
OBS/app placeholder nodes and illustrative edges are excluded so the canvas shows
only AudioArray-owned routes, devices, and processing; no arbitrary DSP insertion or Linux
audio backend has been added. Automated native and isolated browser tests cover
the first three phases. Native hotplug/Bluetooth/VR and game/stream soak testing
are separate follow-up verification, not prerequisites for another permission
request to install this approved canvas.

Deployed verification: 29 native Rust tests and six frontend tests pass. The
production-browser suite checks actual port/node dragging, keyboard undo,
guarded menu edits, slider draft preservation, node spacing, and desktop/iPad
layouts under the packaged CSP. Windows engine/UI release hashes match the
installed binaries. Startup preserved all eight routes and the old controls
file byte-for-byte. Live native checks then verified disconnect/undo of an idle
monitor route, duplicate request handling, stale-revision rejection, feedback
blocking, and RTX intensity changes/undo with an unchanged engine session.
The original routes and filter intensity were restored. The native window
could not be inspected with Computer Use because that tool's WSL context failed;
browser visual checks are not represented as native-window inspection.

## Recommendation

Replace the static signal diagram and separate patch matrix with one interactive
node-and-port canvas. Selecting a node opens its controls; dragging a wire edits
the actual routing. Keep the Intrepid/LCARS framing, palette, and optional interface
sounds, but prioritize readable signal direction and unambiguous connections.

Use React Flow for interaction and custom node rendering, with ELK for optional
automatic layout. Keep the authoritative graph, validation, device coordination,
and audio execution in Rust. The editor is a view/controller, not a second audio
engine or an independent configuration database.

This is more than making the existing SVG draggable. First strengthen the runtime
contract so the picture can distinguish requested wiring from audio that actually
started. Then introduce the canvas against today's supported routing. Arbitrary
DSP insertion is a later engine feature, not something the UI should pretend
already exists.

## Working baseline and invariants

The conversation layout must preserve these roles:

| Bus         | Signal                              | Intended consumers                                       |
| ----------- | ----------------------------------- | -------------------------------------------------------- |
| Game        | Game/unassigned playback            | Main Output, isolated OBS game track                     |
| Comms In    | Received voice communications       | Main Output, ChatGPT In, isolated OBS chat track         |
| Music       | Music/media playback                | Main Output, isolated OBS music track                    |
| ChatGPT Out | AI playback                         | Main Output, Comms Send                                  |
| Clean Mic   | Physical mic after suppression only | ChatGPT In, Comms Send, isolated OBS mic track           |
| ChatGPT In  | Clean Mic + Comms In                | ChatGPT/Codex microphone input                           |
| Comms Send  | Clean Mic + ChatGPT Out             | Discord or another communications app's microphone input |

Four playback-to-monitor links plus four conversation links form the eight default
patches. Existing user-selected patches remain authoritative; migrating the UI
must not reapply defaults or reconnect intentionally disconnected routes.

Clean Mic and ChatGPT Out are source-only in the patch layer. ChatGPT In and Comms
Send accept mixes but cannot be used as patch sources. Comms In must not reach
Comms Send, and ChatGPT Out must not reach ChatGPT In, directly or through another
bus. Game audio does not enter ChatGPT merely because a game supports voice chat.

Comms is generic. Discord is one associated application, not the owner or name of
the bus. A game with separate voice-device settings can use Comms In/Comms Send;
an application that combines voice and game audio cannot be separated by drawing
an extra wire. The UI must explain that limitation.

## Original implementation assessment (baseline `8af62e4`)

- The frontend is vanilla JavaScript and static HTML/SVG inside Tauri. Moving to
  React requires a deliberate frontend build step; this is not a drop-in library
  for the existing DOM code. The tray supervisor and native engine can remain.
  [Current frontend configuration](https://github.com/AlexAllocated/.dotfiles/blob/8af62e484a0b538924dcce08d01b5dd08b7332f7/packages/audioarray/ui/src-tauri/tauri.conf.json).
- Tauri commands read configuration and save controls behind a UI-process mutex.
  A successful command currently means the file was updated, not that the engine
  acknowledged that exact graph. `GraphSnapshot` combines configuration and device
  observations; it is not a revisioned applied-graph receipt.
  [Current commands](https://github.com/AlexAllocated/.dotfiles/blob/8af62e484a0b538924dcce08d01b5dd08b7332f7/packages/audioarray/ui/src-tauri/src/main.rs#L149).
- The patch worker polls controls and replaces the set of CPAL patch streams.
  New streams are started before replacing the old set; this is not yet an atomic
  per-edge routing transaction. A node-editor library will not fix that boundary.
  [Current patch worker](https://github.com/AlexAllocated/.dotfiles/blob/8af62e484a0b538924dcce08d01b5dd08b7332f7/packages/audioarray/src/windows_audio.rs#L1798).
- Microphone capture, 48 kHz mono processing, and VAC Clean Mic output form a
  dedicated pipeline. NVIDIA AFX and DeepFilterNet are real in-process DSP, but
  currently belong to that pipeline rather than arbitrary insert slots.
  [Current mic pipeline](https://github.com/AlexAllocated/.dotfiles/blob/8af62e484a0b538924dcce08d01b5dd08b7332f7/packages/audioarray/src/windows_audio.rs#L1978).
- DTS Headphone:X and Dolby Atmos are selected on the Game and Music Windows
  render endpoints. They are endpoint-bound Windows effects, not freely movable
  Rust DSP instances. Existing routing captures PCM; the editor must not claim
  it carries arbitrary spatial-object metadata between processors.
  [Current spatial configuration](https://github.com/AlexAllocated/.dotfiles/blob/8af62e484a0b538924dcce08d01b5dd08b7332f7/scripts/windows/configure-audio-array.ps1#L337).

## One graph model, several kinds of connection

Use stable node, port, and edge IDs independent of display names and physical
endpoint names. Rust owns a versioned domain model; generated TypeScript types
or checked schemas keep the renderer aligned with it.

Distinguish these node kinds:

- **Source:** physical capture or application playback arriving at a bus.
- **Processor:** a supported audio transformation with explicit input/output
  formats, parameters, latency, availability, and bypass behavior.
- **Mixer:** multiple named input ports and one mixed output, with explicit
  summing and gain semantics.
- **Endpoint:** a stable application-facing VAC interface on Windows, or a
  corresponding virtual endpoint in a future Linux backend.
- **Sink:** physical playback, application capture, or an observed OBS input.
- **Device binding:** the logical Main Input/Main Output selection and its
  currently resolved physical or temporary-session device.

Separate audio edges from policy/observation edges. An app's configured default
is a preference; its active audio session is evidence of where it really opened.
An OBS stem connection is observed/configured externally, not automatically
editable merely because it appears on the canvas. Mark fixed, editable, and
externally managed connections distinctly. Never draw an unverified preference
as a confirmed live audio route.

A VAC node can visually collapse its render/capture plumbing, but every visible
port must have one direction and an explicit meaning such as "playback in" or
"captured signal out." Show voice-app playback and voice-app microphone capture
as separate nodes or clearly separated ports. Avoid one ambiguous two-way box.

Ports carry direction, signal format, channel layout, allowed fan-in/fan-out,
and routing permissions. The compiler resolves sample-rate/channel conversion
into inspectable adapter stages; it must not silently throw away stereo channels
or imply unsupported multichannel processing. Ordinary inputs accept one source;
mixers expose explicit summing ports. Initial unity-gain mixes retain current
behavior. Later gain controls must expose clipping/headroom rather than silently
normalizing all existing audio.

## Validation and feedback protection

Validate in Rust for every client, with frontend previews only for responsiveness:

1. IDs exist, output connects to input, duplicates are rejected, protected ports
   remain protected, and the requested backend supports the operation.
2. Formats are compatible or a supported conversion is identified. Device
   presence, DSP resources, and latency limits are checked before applying.
3. Audio cycles are rejected. Fan-out is allowed; intentional feedback networks
   and delay-based loop exceptions are outside the initial scope.
4. Propagate signal origin through mixers/processors. Reject a path carrying
   received communications back to Comms Send, or AI playback back to ChatGPT In,
   even when a renamed/intermediate node makes it look harmless.
5. Preserve pure Clean Mic provenance and independent OBS stems. Adding music to
   Comms Send does not change Clean Mic, the source music signal, or its OBS stem.

Cycle checks alone are insufficient: the return path through Discord's network
or an AI session is outside the local audio DAG. Keep protected conversation
domains in the model. External applications, acoustic speaker-to-mic feedback,
and routes created outside AudioArray remain beyond what this graph can prove.

First support the current generic Comms domain. Separately isolating several
simultaneous calls would require distinct receive/send domains and potentially
additional virtual endpoints; it is not solved by renaming the existing cable.

## Authoritative runtime and safe edits

The engine becomes the single writer while running. Tauri and CLI send bounded,
typed commands over user-restricted local IPC; no shell execution or arbitrary
filesystem access is exposed to canvas data. Offline edits use the same validator,
an exclusive state lock, and the same durable storage format.

Expose three separate states:

- **Desired:** the saved routing and selected preferences.
- **Applied:** the exact revision the engine successfully activated.
- **Observed:** current devices, negotiated formats, app sessions, signal levels,
  and temporary overrides.

Each edit has a unique request ID and expected graph revision. Commands such as
Connect, Disconnect, ReplaceConnection, SetProcessorParameter, and SelectDevice
operate on stable IDs. ReplaceConnection is one edit, not a visible disconnect
followed by an unrelated connect. Reject stale conflicting commands with a fresh
snapshot; do not blindly overwrite the whole graph. Ignore late responses older
than the current request/revision, including slider responses.

Proposed transaction lifecycle:

1. Validate an isolated candidate and determine the affected routes. The working
   graph remains active during validation.
2. Resolve devices and stage resources off the audio callback. Reuse unchanged
   captures, processors, and sinks; do not reopen the entire array for one wire.
   Recheck the device-generation token before activation.
3. Record a durable prepared transaction with enough information to recover.
   Stage new writers muted; starting a second audible copy of the old graph is
   not a safe substitute for an application boundary.
4. Activate at the engine's processing boundary. Crossfade only where compatible;
   when device/format changes cannot be gapless, isolate and report the brief
   interruption. Independent hardware clocks cannot promise a globally
   sample-synchronous switch.
5. Write the committed revision and emit Applied. If activation fails, keep or
   restore the old routes and return an error tied to the attempted edge. If the
   durable commit fails after activation, report the unsaved state and attempt
   rollback; never report a fully saved success.

Prepared-but-uncommitted transactions are discarded on startup; recover the last
validated committed graph. Persist with atomic replacement/write-ahead records
and bounded backups, not a plain in-place text write. Real-time callbacks perform
no file I/O, configuration parsing, blocking locks, device enumeration, or UI work.

Undo/redo submits validated inverse commands against the current revision. A
slider gesture is one history item, not hundreds. Layout history is separate from
audio history. Hotplug events and Moonlight/Quest overrides are observations, not
user edits to undo. If an inverse cannot apply to current devices, explain the
conflict instead of restoring a stale whole-system snapshot.

## Canvas behavior and readability

The default layout flows left-to-right: sources, processing, buses/mixes, then
consumers. Group monitoring, conversation sends, and OBS recording as clearly
labelled lanes. Allow drag positioning and explicit Arrange/Reset Layout actions;
meter updates must never trigger rearrangement.

Ports, not box corners, are connection anchors. Reserve measured spacing between
nodes and between parallel wires. Use rounded orthogonal routes with short
straight entry/exit segments, fixed input/output port sides, and deterministic
ordering. A crossing is not a junction: use an overpass/gap or separation where
necessary, and only mix at an explicit mixer node. Spatial-effect attachments
remain visibly attached to their endpoint even when that group is moved.

Use arrowheads and port labels for direction without requiring animation. On
selection, highlight the complete upstream/downstream path and dim unrelated
wires. A "What reaches this input?" inspector lists contributing sources and
gains. Selecting an invalid connection explains the exact rejected return path.

Reuse the actual waveform telemetry, but associate every wire with the signal
at that edge's source/tap, never the destination's already mixed meter. When the
physical mic is silent and music feeds a send, the mic-to-filter wire stays dark.
Maintain consistent waveform spacing per path length, bounded amplitude, and
clearance around ports; use a wider invisible hit target than the visible stroke.
Pending, active-but-silent, unavailable, and failed routes need distinct states.
Silence alone does not mean a route is disconnected.

Keep a compact selection inspector rather than another patch matrix. It shows
only controls the backend can actually apply: current device binding, filter
backend/intensity/bypass, supported gains, source contributors, and error details.
Main Output distinguishes preferred hardware from a temporary Quest/Moonlight
override; selecting it must preserve today's Windows-default switching behavior
and physical-device history. Master volume stays downstream of the buses and
does not attenuate the OBS stems.

## Processor boundaries

The initial canvas can inspect and control the existing mic filter, but its
position in that pipeline remains fixed. Later, an explicit Rust DSP-node API
can make supported processors insertable: declared formats, state lifecycle,
parameter updates, resource limits, bypass semantics, and measurable latency.

DTS/Atmos should initially appear as locked "Windows endpoint effect" attachments
with their configured/observed status. Changing an attachment is an OS endpoint
configuration operation that may reopen streams, not dragging a generic DSP onto
an arbitrary wire. Moving a PCM wire cannot recover positional objects that were
already rendered to headphone stereo. A future native spatial pipeline requires
its own compatibility and signal-path validation; do not promise it here.

## Editor and layout library choice

| Approach                       | Fit                                                                                    | Cost / decision                                                                                                                                               |
| ------------------------------ | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React Flow + ELK               | Custom nodes/edges, directed handles, keyboard foundations; separate port-aware layout | Recommended. Introduces React/TypeScript tooling, but avoids owning all canvas interaction. Rust remains the authority.                                       |
| Rete.js + Lit + layout plugin  | Custom nodes, sockets, and controls without converting the whole console to React      | Credible fallback if minimizing framework migration wins the prototype. Requires assembling plugin behavior and validating keyboard/touch access ourselves.   |
| Extend the handmade SVG editor | Reuses current DOM code and waveform paths                                             | Highest ongoing interaction burden: dragging, zoom, hit testing, keyboard connections, routing, and history integration all become our code. Not recommended. |

React Flow supports custom SVG edge paths, so existing measured waveforms can be
adapted instead of replaced with canned animation. Its core is MIT-licensed and
provides keyboard/screen-reader scaffolding; it does not supply AudioArray's
transaction semantics. The published undo/redo example is a separate Pro example,
not a free core engine-level undo implementation. Build our own command history.
[Custom edges](https://reactflow.dev/learn/customization/custom-edges),
[accessibility](https://reactflow.dev/learn/advanced-use/accessibility),
[core license](https://github.com/xyflow/xyflow),
[undo example](https://reactflow.dev/examples/interaction/undo-redo).

Rete's Lit renderer provides customizable nodes, connections, sockets, and
controls and is MIT-licensed. Its editor/processing concepts are useful, but any
JavaScript dataflow execution must remain outside the audio engine; it would
otherwise create a competing runtime.
[Lit renderer](https://retejs.org/docs/guides/renderers/lit/),
[renderer license](https://github.com/retejs/lit-plugin).

ELK computes layout, not UI interaction. Its layered algorithm suits directed
port graphs and it supports worker execution. Use it for initial layout and
explicit arrangement, with port-side/order constraints; do not assume automatic
layout will perfectly preserve arbitrary hand placements. Keep pinned positions
under application control and verify rounding does not introduce collisions.
ELK is EPL-2.0, not MIT; retain its license/source-distribution information in the
dependency inventory before packaging a distributable build.
[ELK JavaScript](https://github.com/kieler/elkjs),
[port constraints](https://eclipse.dev/elk/reference/options/org-eclipse-elk-portConstraints.html),
[license](https://raw.githubusercontent.com/kieler/elkjs/master/LICENSE.md).

Validate this recommendation in a small non-live prototype first: the real
seven-bus fixture, multiple ports, custom LCARS nodes, waveform edges, and iPad
input. Reuse the surrounding console styles/sounds. Bundle dependencies and the
layout worker locally through a pinned build; no CDN dependencies or broadened
remote-code permissions. The library choice remains reversible behind an editor
adapter, while the Rust graph contract does not depend on it.

## Persistence, portability, and telemetry

Version the audio graph separately from the layout. Layout stores positions,
collapsed groups, and viewport only; moving a node changes no audio settings.
Import current controls losslessly, map legacy send aliases to stable IDs, retain
all disconnected/custom routes, and keep a private pre-migration backup. Unknown
schema versions are not overwritten. An old application should refuse a newer
schema rather than partially "repairing" it.

Device IDs, histories, and app-session details remain machine-local. Public
dotfiles contain reusable defaults and migrations, not this machine's live graph
or identifiers. Future Windows and PipeWire adapters advertise their capabilities;
unavailable nodes remain visible with a reason and can be rebound, not silently
deleted. The Linux adapter is a separate future implementation, not a claim of
current parity.

Topology/control events and audio telemetry use separate channels. Send bounded,
downsampled meter/waveform data keyed by stable tap IDs; do not stream full PCM
through Tauri just to draw wires. Start with capped visible updates comparable
to today's roughly 30 Hz meter refresh, then measure. Pause graphical telemetry
when hidden/minimized and request a fresh snapshot on return. Audio runs
independently of frontend frame rate, layout work, or a renderer crash. Preserve
the existing tray lifecycle: closing the window hides it; Exit takes the whole
array offline; Restart Array is explicit.

## Accessibility and verification gates

Offer both dragging and an equivalent port-menu workflow: select output, choose
destination, confirm connection. Provide keyboard selection/connect/disconnect,
focus visibility, labelled ports, touch-sized targets, and cancellation before
applying. A text route list in the selected-node inspector is an accessible view
of the same graph, not a second configuration surface.

LCARS headings can remain distinctive; port labels and error text need readable
type and contrast. Do not rely only on color, sound, waveform motion, or hover.
Honor reduced motion and independent sound mute. Test focus/selection through
device refreshes and background state updates so controls do not jump back while
being edited.

Implementation/verification phases (technical checks, not extra user approval gates):

1. **Contract and transaction foundation.** Add revisioned applied state,
   single-writer commands, durable recovery, provenance validation, and a mock
   backend. Retain all 18 existing Rust tests and the six frontend guard cases.
   Add tests for simultaneous edits, duplicate requests, late responses, format
   failures, partial activation, missing devices, and crashes at each commit
   boundary. Rejected edits must leave the applied graph unchanged.
2. **Read-only canvas and migration preview.** Render the real graph from that
   contract, with fixed endpoint effects and actual session evidence. Compare
   every route against the baseline and import saved custom/empty graphs without
   adding links. Verify spacing, crossing semantics, labels, and path tracing
   at desk and iPad sizes. No live routing writes from the prototype.
3. **Existing-capability editing.** Enable safe connect/reconnect/disconnect,
   device selection, existing filter controls, and undo/redo through the same
   Rust commands. Test mouse, keyboard, and touch; unavailable destinations must
   fail visibly without stopping unrelated buses. Remove the old matrix only
   after all its supported operations work on the canvas.
4. **Audio correctness and soak.** Use isolated test signals to verify the
   contribution to every sink: AI never returns to AI input, incoming comms never
   returns to Comms Send, and Clean Mic stays pure. Confirm monitoring/OBS stems
   and master-volume isolation. Exercise AirPods HFP/A2DP, unplug/replug, Quest,
   Moonlight, engine restart, and UI crash/reconnect. Compare callback underruns,
   latency, CPU/GPU load, and UI frame time against the current release under the
   same game/stream load; animation must not add audio glitches.
5. **Optional DSP graph expansion.** Only after the above is stable, design and
   implement movable supported Rust DSP stages and explicit mix controls. Require
   format, latency, gain/clipping, bypass, and resource-failure tests before each
   new processor becomes connectable. Endpoint spatial effects stay constrained
   unless a separately verified backend capability makes more possible.

Phases 1–3 are authorized through deployment and verification. Preserve the
functioning conversation routes and a recoverable binary/configuration backup.
Phase 5 remains an optional future expansion, not a reason to delay the approved
existing-capability editor or silently broaden its scope.
