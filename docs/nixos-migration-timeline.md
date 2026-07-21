# NixOS Migration Timeline

> Working notes for a future post. Repository-backed events use commit dates.
> Conversation-only events are grouped by phase when the exact timestamp is not
> important. “Installed” does not imply “fully tested.”

## Before July 2026 — Windows, WSL, and imperative dotfiles

- Windows was the primary desktop, gaming system, and hardware-control layer.
- WSL was the primary Linux development environment.
- Docker packaged portable versions of the development environment.
- The full development image was approximately 2.22 GB.
- A smaller Neovim-focused image was approximately 300 MB.
- The dotfiles repository used:
   - `install.sh` for procedural setup.
   - A separate symlink script.
   - Zsh startup logic with platform detection.
   - Native Windows WezTerm and Neovide connected to WSL.
   - Komorebi for Windows window management.
   - Host-specific PowerShell glue.
- Desired state was distributed between:
   - Shell scripts.
   - Docker layers.
   - WSL files.
   - Windows application settings.
   - Symlinks.
   - One-time manual operations.
   - Personal memory.
- The old architecture was useful and portable, but reproducing the final
  machine still depended on its history.
- The last pre-Nix state was preserved in the repository's `pre-nix` tag.

## July 1 — The dotfiles become a Nix architecture

- The old dotfiles structure was checkpointed (`be9aa3a`).
- The first Nix rewrite landed (`13266de`).
- The repository gained:
   - `flake.nix` and `flake.lock`.
   - NixOS-WSL support.
   - Home Manager configuration.
   - nix-darwin support.
   - `dot-bootstrap`.
   - `dotctl`.
   - A documented side-by-side NixOS-WSL rollout.
   - Windows link reconciliation.
- NixOS-WSL became the first-class Linux development target.
- Windows-native tools were pointed at the NixOS WSL distribution.
- Bun and user binaries were added to the correct session paths.
- The first major architectural shift occurred:
   - The repository stopped primarily describing installation steps.
   - It began describing reusable capabilities and host profiles.

## July 2 — NixOS-WSL reaches practical parity

- 1Password CLI access was bridged through the Windows host.
- Docker Desktop integration was enabled for NixOS-WSL.
- The Linux username was migrated from the old identity to `alex`.
- The existing WSL UID was preserved.
- Legacy user profiles and pre-Nix leftovers were removed.
- The large Home Manager configuration was split into reusable modules
  (`20aef37`).
- The Nix maintenance workflow was refined.
- Early lessons about state boundaries emerged:
   - Windows applications could remain Windows-owned.
   - WSL could own the Linux development environment.
   - The repository could declare integration between them.

## July 6–9 — Cross-platform experiments clarify the architecture

- A Docker-based macOS workshop environment was added and iterated on.
- Work included:
   - WezTerm launch behavior.
   - UTF-8 locale handling.
   - Neovim runtime priming.
   - SSH-agent forwarding.
   - 1Password integration.
   - Git identity synchronization.
   - Homebrew automation.
   - A host-command bridge.
- The Docker workshop proved useful but also exposed the cost of maintaining a
  large host/container integration layer.
- A host-native managed-macOS profile was added (`92a948c`).
- Codex paths were normalized across restored/container environments.
- Live Codex SQLite state was deliberately kept out of unsafe cross-filesystem
  restoration.
- The design continued moving toward:
   - Shared declarative capabilities.
   - Thin host-specific layers.
   - Explicit handling for mutable state.

## July 10–16 — The repository becomes a real control plane

- The dotfiles architecture was modularized around reusable toolsets
  (`6c0f70c`).
- `updoot` evolved beyond a simple update command.
- Update behavior gained:
   - Synchronization before changes.
   - Rebase handling.
   - Staged validation.
   - Streamed progress.
   - Separate persistent and isolated Neovim update phases.
- Windows Neovim integration was added.
- Windows applications began being managed declaratively from WSL
  (`43eaadb`).
- Desktop applications, fonts, Neovide, and WezTerm were coordinated across
  platforms (`73a9204`).
- Neovim runtime state and writable lockfiles were hardened.
- The repository explicitly stopped owning machine-local Codex preferences,
  plugins, rules, authentication, and `config.toml` (`e806c12`).
- By July 16, the flake already described:
   - NixOS-WSL.
   - Generic Linux Home Manager.
   - macOS profiles.
   - Container images.
   - Shared development capabilities.
- Native NixOS could now reuse an existing architecture rather than starting
  from scratch.

## July 17–18 — The native migration starts as a feasibility audit

- The initial prompt was a complaint that the Windows audio stack felt
  antiquated.
- The discussion expanded into whether NixOS could become the primary OS.
- The Windows installation was audited before committing to the move.
- Game compatibility became the first major decision point.
- Steam Deck and Proton progress made native Linux gaming plausible.
- Windows was retained for anything not actually proven, especially:
   - Rust.
   - Phasmophobia.
   - Anti-cheat-sensitive multiplayer games.
   - Official Meta Quest PC Link.
- Linux VR alternatives were identified:
   - ALVR.
   - WiVRn.
- Those alternatives were treated as experiments rather than parity claims.
- Adobe was declared expendable.
- Initial Linux creative replacements were selected:
   - Kdenlive for Premiere-like editing.
   - GIMP and Krita for image work.
   - Audacity and Ardour for audio.
   - Flameshot and ksnip for Snagit-like capture and annotation.
- NixOS remained the preferred distro because the repository was already built
  around Nix.
- Other distros were considered, but switching away from NixOS would have
  discarded much of the new architecture.

## July 17–18 — Storage and dual-boot constraints shape the plan

- Buying another SSD was ruled out.
- The migration had to happen in place.
- The Windows system partition would be shrunk from Windows.
- NixOS would be installed into newly created partitions in the released space.
- Windows would remain installed and would be pruned only after Linux parity
  was proven.
- The second data disk was audited before reuse.
- Important preservation decisions included:
   - Commit and push valuable Git work.
   - Preserve selected non-repository data.
   - Move OBS recordings that mattered.
   - Treat Docker state as disposable and reproducible.
- A small NTFS Windows-games area was discussed.
- The final declared Linux data layout instead centered on a Btrfs `/data`
  filesystem with dedicated games and preserved-data directories.
- Game storage was configured to avoid copy-on-write fragmentation.
- The Windows pagefile was questioned as part of the free-space audit.
- Windows was to be reduced gradually, not destructively on day one.
- A hard migration rule was established:
   - Never reboot without explicit approval.

## July 17–18 — Remote access and continuity become first-class requirements

- The workstation was regularly controlled from an iPad through Moonlight.
- The existing Windows setup used:
   - Sunshine.
   - An NVIDIA custom resolution.
   - A dummy display adapter.
   - The iPad Pro's exact 2732×2048 resolution.
- The Linux migration could not strand the workstation upstairs without a
  recovery path.
- The migration also needed to preserve:
   - The current Sunshine/Moonlight pairing.
   - Codex authentication.
   - The active migration conversation.
   - The Git history and uncommitted work that mattered.
- A local recovery terminal was planned for temporary trusted-LAN access.
- Tmux was eventually chosen so the browser would be only a viewer, not the
  owner of the shell or Codex process.
- Firmware and recovery instructions were prepared before any final reboot.
- Secure Boot was discussed because some Windows games required it.
- Secure Boot restoration was not treated as complete native NixOS work.

## July 18 morning — A custom migration appliance is added

- The first native migration commit landed (`de39b5d`).
- It added approximately 3,585 lines across 25 files.
- New flake outputs and modules included:
   - The native workstation profile.
   - A custom graphical installer ISO.
   - Migration and recovery tools.
   - Machine-manifest validation.
   - iPad display tooling.
   - Windows boot fallback recovery.
   - A Windows-side handoff exporter.
- The installer was designed to:
   - Validate the exact Windows-captured machine and disk layout.
   - Format only the two intended NixOS partitions.
   - Preserve the existing Windows EFI partition.
   - Require typed confirmation of the canonical target.
   - Restore the dotfiles Git bundle.
   - Restore the selected Codex state.
   - Restore Sunshine pairing material.
   - Set the native user password.
   - Unmount everything on completion.
   - Never resize partitions.
   - Never repair the Windows EFI filesystem.
   - Never reboot.
- The storage design used:
   - The existing Windows EFI System Partition.
   - A separate 2 GiB XBOOTLDR partition for NixOS kernels.
   - A Btrfs NixOS root.
   - `@root`, `@home`, `@nix`, and `@swap` subvolumes.
   - An 8 GiB swapfile.
   - Zram.
- The handoff capsule kept private state separate from both Git and the ISO.
- Capsule contents included:
   - A verified Git bundle.
   - The machine manifest.
   - Selected Codex conversation/database state.
   - Sunshine pairing state and credentials.
- Every capsule payload was hash-manifested and validated before import.

## July 18 morning — Installer staging fails safely several times

- Windows displayed: “NixOS installer staging stopped. No reboot occurred.”
- The first failure was treated as a stopped precondition, not something to
  bypass.
- FAT32-specific verification was fixed (`8ed1fcf`).
- The internal installer layout was changed so FAT32 contained:
   - Extracted EFI and boot files.
   - The unchanged installer ISO as a file.
- GRUB entries were given an explicit `findiso=` argument (`d914ac0`).
- Codex CLI was exposed in the installer (`0dcf407`).
- The installer was forced onto the classic initrd path that implemented
  `findiso=` (`051aba4`).
- Installer launchers were reordered after user creation (`4b2f631`).
- Writable FAT32 staging was fixed (`1f25212`).
- The image and staged FAT32 layout were rehearsed under OVMF without exposing
  host disks.
- Alex's summary after the repeated staging work: “Well this has taken all
  morning lol.”

## July 18 — First installer boot and the Windows corruption scare

- The first boot into the live NixOS installer appeared successful.
- The machine returned to Windows for filesystem checks.
- Windows ran CHKDSK during boot.
- Several unusual symptoms followed:
   - Login state needed repair.
   - The clock was several hours wrong until synchronized.
   - WSL initially failed to start.
   - WSL later opened after repeated attempts.
   - The PC froze while investigating.
   - A hard reboot triggered additional disk checks.
   - One Windows boot failed and entered automatic diagnostics.
   - Windows eventually booted with corruption-related errors.
   - WSL stopped loading because of storage corruption.
- The machine was returned to the live NixOS environment, which remained
  stable.
- The working summary became: “We are in some doo doo.”
- No simple causal claim was established.
- The migration did not assume that NixOS caused the Windows corruption.
- Read-only checks established:
   - The Windows system partition had not been resized by Linux.
   - The intended NixOS partitions had not been written unexpectedly.
   - Windows volumes could be inspected without mounting them read-write.
   - Identified CHKDSK records were system/log metadata rather than personal
     files.
   - The WSL VHDX had pending recovery state.
   - The ext4 filesystem inside it also had a pending journal.
   - No bad blocks or identified personal-file casualty were found.
- Windows repair was deferred instead of attempting Linux-side filesystem
  surgery.

## July 18 afternoon — The AI handoff proves too static

- The physical handoff capsule contained the original exported conversation.
- New recovery work accumulated in a private live import.
- Running the original resume command repeatedly reconstructed the frozen
  capsule instead of reusing the updated import.
- Fresh Codex sessions could not see the authoritative thread because it lived
  in the isolated recovery home.
- The updated conversation was eventually found intact.
- A synthetic resume prompt was removed because it interfered with normal
  reconnection.
- Path assumptions had to be normalized between:
   - The live installer user.
   - The installed native user.
   - The imported Codex home.
- The continuity design changed from one immutable export to:
   - One immutable baseline capsule.
   - An active private import.
   - Incremental validated checkpoints.

## July 18 afternoon — Browser disconnects lead to tmux and checkpoints

- The web terminal disconnected while Codex appeared stuck on “Working.”
- Investigation found that the terminal server itself had not crashed.
- The live installer had entered deep S3 suspend.
- Suspend froze the user slice and dropped the network/WebSocket connection.
- Tmux and the detached Codex process survived.
- The model/API turn in flight did not recover.
- Killing the stuck Codex/tmux process was treated as a reasonable operator
  action, not a continuity failure.
- A live sleep inhibitor was added.
- Recovery mode gained a durable sleep blocker.
- Tmux was installed in the live profile.
- The browser terminal became a viewer attached to a dedicated tmux server.
- Mobile terminal work included:
   - A larger viewport and font.
   - Bundled Nerd Font glyphs.
   - Gruvbox styling.
   - WebSocket keepalives.
   - Touch-friendly scrolling.
   - Disabling tmux mouse capture for the recovery session.
- `checkpoint-migration` was added (`0a7664b`).
- Each checkpoint included:
   - An online SQLite backup.
   - A complete-line rollout snapshot.
   - Per-file hashes.
   - An atomic timestamped publication.
   - A binding to the immutable handoff-manifest hash.
- `resume-migration` gained:
   - Active-import reuse.
   - Fresh-import mode.
   - Status validation.
   - Automatic application of the newest matching checkpoint.
- The 8 GiB rescue partition was cramped but invaluable.
- Alex described it as “this little 8gb partition is our saving grace right
  now XD.”
- The decision shifted from deleting the rescue partition immediately to
  retaining a recovery layer below the installed OS.

## July 18 afternoon — The 190 GB WSL detour is stopped

- A conservative plan began copying the entire WSL virtual disk.
- The estimate suggested hours of copying.
- Alex interrupted with:
   - “Hours??”
   - “What are we doing?”
   - “Are we sure that's not a Docker disk?”
   - “Why is Nix 190 GB?”
- The 190 GB figure represented the accumulated WSL virtual disk, not a normal
  NixOS installation.
- The full-disk copy was canceled.
- The incomplete copy was removed.
- The preservation policy was narrowed to:
   - Mount and inspect the source read-only.
   - Audit Git repositories under the WSL code directory.
   - Commit and push work that mattered.
   - Ignore a specifically disposable OBS source checkout.
   - Preserve selected non-repository data.
   - Treat Docker and rebuildable Nix state as disposable.
- The old NixOS-WSL environment could be rebuilt later.
- It might never need rebuilding if native NixOS replaced Windows development.
- The event clarified the human/AI boundary:
   - AI could inventory and propose conservative preservation.
   - Alex decided which state actually had value.

## July 18 evening — Native NixOS is installed

- The guarded installer completed against the validated target partitions.
- The native system restored:
   - The dotfiles repository and history.
   - The selected Codex conversation and authentication state.
   - Sunshine/Moonlight pairing state.
   - The native `alex` user profile.
- A native user password was set.
- The first native root was mounted from the Btrfs `@root` subvolume.
- The installed system booted successfully.
- NixOS became the active environment for the remainder of the migration.
- Windows remained preserved as a separate boot target.
- Deferred Windows repair and post-install validation were not declared
  complete.
- The Linux data disk was declared (`ec7f2c0`).
- `/data/games` and `/data/preserved` were created.
- The games directory inherited a no-copy-on-write policy.

## July 18 evening — Basic desktop parity is restored

- Initial UI scaling was adjusted repeatedly while moving between the physical
  monitor and iPad.
- The physical LG was restored to its native ultrawide resolution and scale.
- The dummy adapter was left for later once physically connected.
- Gruvbox Dark became the visual baseline.
- Plasma was used as the utilitarian first desktop.
- Native browsing and gaming utilities were added (`38f156a`).
- Mise runtime resolution was fixed (`689792a`).
- Native recovery utilities were added (`f9ea1f3`).
- Sunshine hardware integration was completed (`2b77194`).
- Creative hardware acceleration was added (`259e257`).
- Desktop applications and integration were added (`1be3c9d`).
- Developer parity was restored (`fb5cc56`).
- Initial native application set included:
   - Firefox and Chrome.
   - Steam and Proton tooling.
   - OBS.
   - Kdenlive.
   - GIMP and Krita.
   - Audacity and Ardour.
   - Discord.
   - 1Password.
   - Neovim and Neovide.
   - Codex CLI.
   - Existing development runtimes and cloud tools.
- A browser was briefly missing, causing an authentication URL to open in a
  text editor.
- 1Password was prioritized after the initial app pass.
- A recurring Discord JavaScript error was investigated and cleared.
- KWallet prompts and Discord crashes were treated as desktop-integration
  issues rather than reasons to abandon NixOS.

## July 18–19 — Terminal configuration turns into a bake-off

- WezTerm was restored from the shared dotfiles.
- Plasma and WezTerm initially drew two title bars/control sets.
- Window decoration rules were iterated until only the intended controls
  remained.
- WezTerm retained close confirmation.
- WezTerm tabs were eventually disabled entirely on Linux.
- Plasma owned normal window move/resize controls.
- Ghostty and Kitty were installed side by side (`7f87224`).
- All terminals were given:
   - Gruvbox Dark where possible.
   - BigBlueTerm Nerd Font.
   - Consistent shell/prompt behavior.
- Tmux was made portable across profiles (`b61b16b`).
- A Gruvbox tmux status line was configured.
- A local tmux cheat sheet was added.
- Tmux retained its stock `Ctrl+B` prefix.
- Alacritty was added as another trial (`30e0cc3`).
- Its desktop launcher was fixed (`c9ad28d`).
- Ghostty showed prompt/redraw artifacts.
- Kitty behaved well but did not win the preference test.
- WezTerm required a native Wayland/OpenGL adjustment under Niri.
- Alacritty was the most consistently predictable terminal.
- Alacritty became the Linux default.
- WezTerm remained installed as the feature-rich alternative.
- Ghostty and Kitty were later removed.
- Both retained terminals eventually received 90% opacity.

## July 18–19 — Wayland compositor exploration begins

- Alex asked whether the initial GUI choice had been made on his behalf.
- Plasma was explained as the conservative, recoverable baseline.
- “New hotness” compositors were investigated.
- Hyprland and Niri were installed side by side (`ad757a8`).
- The first Hyprland session reached a graphical desktop and then became
  non-interactive.
- Mouse input, clicks, and keyboard shortcuts stopped responding.
- A hard reboot was required.
- Niri initially appeared similar because the same shell dialog appeared.
- Freezes clustered around Noctalia's first-run/telemetry dialog.
- The dialog's state and telemetry behavior were removed from first-run
  ambiguity.
- Experimental session recovery was hardened (`cc19e27`, `cb50fc2`).
- Niri's horizontal scrolling model initially felt strange.
- Hyprland initially felt more intuitive because of its conventional tiling
  behavior.
- Niri became more appealing after extended use.
- Niri stacking keys were restored from upstream defaults.
- Hyprland bindings were also moved closer to upstream defaults.

## July 19 — Sunshine becomes infrastructure below the desktop

- Sunshine initially depended too much on the active graphical session.
- The goal changed to one persistent instance below all selectable desktops.
- Sunshine was moved into a system-owned service that runs under the user with
  scoped capabilities.
- The service was designed to survive:
   - SDDM.
   - Plasma.
   - Niri.
   - Mango.
   - Desktop-session handoffs.
- A temporary recovery web terminal was also declared at boot.
- Its tmux server was separated from the browser-facing service.
- A dedicated desktop switcher was planned so remote switching could happen
  without manually navigating the login screen.
- Sunshine was rebuilt with scoped CUDA support (`23d0db7`).
- NVENC was verified (`ef92d9d`).
- Heavy GPU load later exposed problems in the Linux CUDA interop path.
- The final declared Sunshine encoder returned to Vulkan.
- NVENC remained compiled as a fallback.

## July 19 — The iPad dummy display becomes a native Linux output

- The physical dummy adapter was connected.
- Its stock EDID did not advertise 2732×2048.
- An exact iPad-native EDID was generated.
- Build checks validated the EDID with `edid-decode`.
- The physical LG was declared separately at:
   - 3440×1440.
   - 160 Hz.
   - 100% scale.
- The iPad dummy was declared at:
   - 2732×2048.
   - Approximately 60 Hz.
   - 175% scale.
- Sunshine was taught to enable and size the dummy before streaming.
- The dummy was disabled when not streaming so:
   - The pointer could not disappear onto an invisible monitor.
   - Windows and workspaces could not remain stranded there.
- Moonlight successfully connected at the native iPad resolution.
- Alex confirmed: “Cool. I'm officially connected successfully with the
  proper iPad resolution :D.”
- Initial black-screen and LG-off failures were investigated.
- Sunshine's KMS capture path was stabilized.
- Stable connector selection replaced volatile numeric display indexes.
- A final-client-disconnected hook disabled the dummy after streaming.

## July 19 — Sleep is removed from the machine's policy

- Moonlight and the recovery terminal became unreachable after another idle
  period.
- Automatic sleep was again identified as the cause.
- Alex's requirement became explicit:
   - “I never want my PC to sleep. Period.”
   - “It's either on or it's off.”
- Plasma idle locking and power saving were disabled (`9499b42`).
- System suspend and hibernation paths were later disabled declaratively.
- The always-on policy became machine configuration rather than a remembered
  desktop preference.

## July 19 — Steam and native gaming are exercised

- Steam's Linux library was pointed at the Linux games filesystem.
- A large set of games was queued through Steam's console.
- Steam printed server-stat and timeout warnings during installation.
- Those warnings were treated as nonfatal unless an installation actually
  failed.
- Proton, GE-Proton, Gamescope, and GameMode were installed.
- Rust and Phasmophobia were installable.
- Installation was not treated as proof of anti-cheat or multiplayer parity.
- Windows remained the fallback for those games until real testing proved
  otherwise.
- Doom: The Dark Ages launched and played through Proton.
- During Doom testing:
   - Video occasionally froze.
   - Audio continued.
   - Game input continued.
   - Reconnecting Moonlight restored the video.
- Streaming and encoder paths were investigated.
- A separate physical cooling/airflow problem was also discovered.
- Temperature monitoring was used while relaunching the game.
- The event prevented every graphical symptom from being blamed on Linux,
  Wayland, NVIDIA, or Sunshine.

## July 20 — The desktop experiment matrix expands

- Mango and COSMIC were added for testing.
- Noctalia and DMS were tested as desktop-shell layers.
- Multiple compositor/shell combinations appeared in the login screen.
- A desktop-switch command was added (`b7177ed`).
- It could select:
   - Plasma.
   - Niri combinations.
   - Hyprland combinations.
   - Mango combinations.
   - COSMIC.
- The switcher initially exposed handoff problems.
- A trap/wait interaction could stall session transitions.
- Experimental desktop handoffs were fixed (`64d9134`).
- The dispatcher learned to recycle the user systemd manager between sessions.
- This prevented stale compositor sockets and DBus state from crossing the
  boundary.
- Repeated short failures gained an automatic Plasma fallback.
- A session surviving the stability window cleared its failure history.
- Sunshine and recovery services remained outside the recycled graphical
  session.
- Mango's dangerous `Super+M` quit behavior was remapped to minimize
  (`398b5f0`).

## July 20 — Desktop preferences emerge through actual use

- COSMIC failed to earn a permanent place.
- Hyprland remained unreliable on the machine.
- Mango became unexpectedly enjoyable.
- Favorite Mango behavior included:
   - Cycling layouts.
   - Animated window rearrangement.
   - Global windows visible across workspaces.
   - Keeping one center terminal while changing surrounding applications.
- Alex's reaction: “lol... I hate that I'm loving this so much XD.”
- Niri's horizontal strip became more practical over time.
- Niri avoided the need to explicitly populate numbered desktops before using
  them.
- Niri eventually became the preferred daily workflow.
- Mango remained worth keeping as an alternate.
- Plasma remained the known-good fallback.

## July 20 — Wallpapers and display topology become declarative

- A 21:9 pixel-art meadow wallpaper was generated for the LG.
- A second version used hex-shaped pixels.
- A native 2732×2048 version was generated for the iPad display.
- Wallpaper assignment became connector-specific.
- Niri workspace handling was extended for monitor topology changes
  (`fbf8f10`).
- When the LG turned off:
   - Workspaces associated with it moved to the iPad output.
- When the LG returned:
   - Only the workspaces previously displaced from it moved back.
- Workspaces already belonging to the iPad remained there.
- An iPad keyboard limitation was discovered:
   - The operating system intercepted `Command+H` before Moonlight could send
     the intended Super-key shortcut.
- Remapping every Super binding to Control was considered but not adopted as
  the final desktop policy.

## July 20 — Collaboration and work applications are added

- Slack was added.
- Linear was added.
- Teams was installed as a web application (`2dd186d`).
- Discord and browser integration continued to be refined.
- Launching already-open applications under Niri became a usability issue.
- Noctalia's launcher was later patched to focus existing windows.
- Firefox Picture-in-Picture exposed a window-selection edge case.
- The launcher learned to prefer the normal Firefox window.
- Discord, Slack, Steam, and most launcher entries could move focus to an
  already-running instance.
- Tray-icon activation remained unreliable because Electron/SNI identities
  were often too generic.

## July 20 — Windows Razer state is migrated read-only

- The Windows partition was mounted read-only for Razer profile extraction.
- Synapse profiles were inventoried and translated (`36361ab`).
- Migrated state included:
   - Eight Tartarus layouts.
   - Huntsman Caps Lock-to-Escape behavior.
   - Ordinary Basilisk button mappings.
   - Horizontal-wheel mappings.
- Home Manager seeded writable Input Remapper profiles without overwriting
  later local edits.
- OpenRazer and Polychromatic covered supported hardware settings.
- Input Remapper covered ordinary key/button translation.
- The Huntsman Caps Lock-to-Escape mapping was tested successfully.
- Some Synapse behavior remained outside the first migration:
   - HyperShift layers.
   - A preserved game macro.
   - Analog actuation.
   - Snap Tap.
   - Executable-driven profile switching.

## July 20–21 — The Basilisk private controls become protocol work

- Four Basilisk controls did not appear as ordinary mappable Linux input
  events.
- Existing browser/WebHID tooling could see the device interfaces.
- The wireless receiver path could not successfully open/write the required
  feature-report interface.
- Direct USB protocol testing continued.
- A helper was added to program only the volatile Linux-facing direct profile.
- The four private controls were mapped to F13–F16.
- Input Remapper translated F13–F16 into the recovered actions.
- The persistent Windows onboard profile was intentionally left untouched.
- Wired and wireless transports were handled separately.
- Native support was proposed upstream in `razerqdhid` PR #6.
- The work was not represented as complete upstream support.

## July 20–21 — Keyboard and mouse sharing moves away from Synergy

- Synergy was requested so the desktop could control a nearby Mac.
- Under Niri, Synergy/Deskflow depended on an InputCapture portal that was not
  implemented.
- Lan Mouse was selected instead.
- The NixOS side gained:
   - A declared package.
   - A user service.
   - Interface-scoped firewall policy.
   - Restart handling when the iPad dummy output was removed.
- Machine-specific peer identity and trust state remained local.
- The Mac still required:
   - Its own Lan Mouse client.
   - Accessibility permission.
   - Trust/fingerprint approval.
- End-to-end Mac control was not declared proven.
- Clipboard sharing remained unsupported by Lan Mouse.

## July 21 — Native desktop integration converges

- The persistent Sunshine service was patched to:
   - Select the dummy by stable connector name.
   - Follow display topology changes.
   - Run display teardown after the final Moonlight client disconnects.
- Noctalia was patched so launching an already-running application could focus
  its existing Niri window.
- A Firefox Picture-in-Picture preference was added.
- Tray-based focusing was abandoned as an unreliable edge case.
- Static wired-network behavior was declared.
- Lan Mouse was restarted when the rightmost dummy display disappeared.
- Native desktop integration landed in `bdbc8de`.

## July 21 — The experimental desktop list is pruned

- Alex decided to keep experimenting with Mango.
- Niri remained the preferred workflow.
- Plasma remained the recovery fallback.
- Hyprland was removed as a selectable/configured compositor.
- COSMIC was removed.
- DMS was removed.
- Removed choices disappeared from:
   - The flake configuration.
   - Home Manager.
   - SDDM sessions.
   - The desktop switcher.
   - The lockfile where applicable.
- Old mutable experiment configuration was moved to the desktop trash rather
  than silently destroyed.
- The final selectable desktop list became:
   - Plasma.
   - Niri + Noctalia.
   - Mango + Noctalia.
- The cleanup landed in `598c863`.
- The result demonstrated clean declarative removal rather than package-state
  archaeology.

## July 21 — Final terminal polish

- Alacritty remained the default terminal.
- WezTerm remained the feature-rich alternative.
- WezTerm was set to 90% background opacity (`6321409`).
- The first commit did not visibly change the running terminal.
- Inspection showed that the live Home Manager profile still pointed at the
  previous generation.
- A new NixOS generation was built and activated.
- The live WezTerm configuration was verified afterward.
- Sunshine and related services were checked after activation.
- This exposed a useful completion ladder:
   - Source changed.
   - Configuration evaluates.
   - Target builds.
   - Generation activates.
   - Process reloads.
   - Live state matches.
   - Human-visible result works.
- WezTerm was subsequently restored as the default terminal.
- Alacritty remained installed as the fast, minimal alternative.
- The change covered:
   - `$TERMINAL`.
   - `xdg-terminal-exec`.
   - Plasma's terminal service.
   - Niri's terminal bindings.
   - Mango's terminal bindings.
   - Plasma taskbar order.

## July 21 — The first long-form draft is produced

- A 7,000-word article draft was reconstructed from:
   - The complete conversation.
   - Git history.
   - Current modules.
   - Migration and recovery documentation.
   - The original Bluesky post.
- The first draft emphasized the AI/declarative-architecture thesis.
- It was published in `docs/ai-driven-nixos-migration.md` (`388ea81`).
- Alex disliked the draft and decided it would be better to write the final
  article from scratch.
- This factual timeline was requested as raw source material instead.

## Current proven state

- Native NixOS is the daily development environment.
- Windows remains installed as the intended compatibility fallback.
- Deferred Windows repair and validation are not being represented as complete.
- Niri + Noctalia is the preferred daily desktop.
- Mango + Noctalia remains available for experimentation.
- Plasma remains the known-good recovery baseline.
- WezTerm is the default terminal.
- Alacritty remains installed as an alternative.
- Tmux provides durable sessions and recovery continuity.
- The LG runs at its native 3440×1440 high-refresh mode.
- Moonlight has connected successfully at the iPad's native 2732×2048 mode.
- Sunshine persists beneath graphical session changes.
- The current declared Sunshine encoder is Vulkan.
- NVENC support remains compiled as a fallback.
- The dummy display is disabled when no Moonlight client needs it.
- Niri workspace movement across LG/iPad topology has been exercised.
- Steam and Proton are installed and working for tested titles.
- Doom: The Dark Ages launched and played.
- The Huntsman Caps Lock-to-Escape mapping is proven.
- The system can be rebuilt and activated from the repository.
- The recovery terminal no longer owns the Codex process lifecycle.
- Sleep and hibernation are disabled by machine policy.

## Current installed but incompletely validated state

- Rust and Phasmophobia on Linux.
- The complete Steam library.
- WiVRn and ALVR.
- Old-iPhone camera integration with OBS.
- Every recovered Razer game profile.
- All four private Basilisk controls across every connection mode.
- Full Lan Mouse control of the Mac.
- Every creative replacement workflow.
- Every launcher/tray focus edge case.
- Secure Boot for the native NixOS installation.

## Intentionally retained boundaries

- Windows remains for:
   - Official Quest PC Link.
   - Unproven anti-cheat games.
   - Any proprietary workflow whose Linux replacement is not yet good enough.
- Mutable/private state remains outside the public flake:
   - Authentication.
   - Sunshine pairing credentials.
   - Codex databases and local preferences.
   - Git author identity.
   - Network-peer trust state.
   - Browser profiles.
   - Steam game data.
- The rescue partition remains because failures below the installed OS still
  need an independent recovery layer.
- Nix generations can roll back system configuration.
- Nix generations cannot roll back:
   - User-data corruption.
   - Firmware changes.
   - Arbitrary EFI damage.
   - Physical cooling failures.
   - Secrets or databases not included in the generation.
