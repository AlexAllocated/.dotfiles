# I Let AI Migrate My Windows Workstation To NixOS

On July 20, somewhere in the middle of rebuilding my entire computing life, I
[posted this on Bluesky](https://bsky.app/profile/alexallocated.bsky.social/post/3mr2ne5kxv22w):

> AI-driven NixOS is so powerful. There's something here with using AI in
> conjunction with declarative workflows.

My point was that AI removed much of the complication and tedium without
discarding the benefits.

We were not even finished yet.

By that point, AI and I had already audited my Windows workstation, converted
my development environment to Nix, designed a dual-boot migration, built a
custom recovery environment, preserved the state needed to continue the same
AI conversation after rebooting, and installed NixOS without surrendering my
Windows fallback. We would go on to make my iPad work as a native-resolution
remote display, build a system-level Sunshine setup, migrate Razer profiles,
try a frankly unreasonable number of terminals and Wayland compositors, patch
upstream applications, and eventually settle into a desktop workflow I like
more than the Windows setup it replaced.

There were rough waters. At one point Windows and its WSL storage were showing
corruption symptoms. At another point the recovery environment went to sleep,
the browser connection died, and the AI process survived inside tmux but never
recovered its in-flight request. We briefly started copying a roughly 190 GB
WSL virtual disk before I interrupted with the extremely reasonable question:
“Hours?? What are we doing?” Some experimental desktop sessions froze. A
streaming problem turned out to involve both a software capture path and, in a
separate incident, the ancient enemy of all abstractions: thermodynamics.

Despite all of that, the result was amazing. More importantly, doing this with
AI was far simpler than doing it all myself.

The interesting part is not that AI can install Linux. A sufficiently
determined shell script can install Linux. The interesting part is what happens
when an AI that can inspect and operate the whole machine is paired with an
operating system whose state is declared, evaluated, built, versioned, and
rolled back like software.

AI makes Nix's rigor affordable. Nix makes machine-level AI trustworthy.

That combination feels like a much bigger idea than this one migration.

## The dotfiles already wanted to become an operating system

To understand why this felt so different, it helps to understand what it
replaced.

My old dotfiles were not bad. They had accumulated over years, they worked, and
they were more portable than most people's development environments. The
[`pre-nix` tag](https://github.com/AlexAllocated/.dotfiles/tree/pre-nix) still
contains the familiar ingredients: an installation script, a script that
created symlinks, shell startup files full of platform detection, a large
Neovim configuration, WezTerm settings, Windows window-manager configuration,
and a Dockerfile that packaged the development environment.

The README advertised a 2.22 GB general development image and a smaller 300 MB
Neovim image. That was my answer to reproducibility: put the environment in a
container, mount the files I wanted to edit, and carry the same tools between
machines. On Windows, WSL provided the Linux boundary while native WezTerm and
Neovide reached into it. PowerShell and symlinks glued the host applications to
the repository. Shell code checked which operating system it had landed on and
did the appropriate thing.

That setup already expressed the right instinct. I wanted one source of truth.
I wanted my tools to follow me. I did not want to spend a day rebuilding my
editor every time I touched a new machine.

But the repository reproduced my preferences more completely than it
described the machine. Some state lived in scripts. Some lived in Docker. Some
lived in Windows application settings. Some existed because a command had been
run once three years ago and the resulting file had never been disturbed.
Some lived only in my memory.

An imperative setup tells the computer what steps to perform:

```sh
./install.sh
./create-symlinks.sh
```

That can be perfectly useful, but rerunning a sequence of operations is not the
same as proving that the system converged on a known state. If step 14 fails,
or the package manager changes something underneath you, or the host already
contains an unexpected version, the final machine is the sum of the script and
all the history that came before it.

The computer becomes archaeology.

Nix inverts that relationship. Instead of primarily recording the operations,
I describe the result I want: these packages, these services, this user
environment, this boot policy, this display behavior, these session choices.
Nix evaluates that description and builds a generation. Activating the
generation changes the running machine toward that declared result. The prior
generation still exists if I need to go back.

I understood why this was powerful long before I adopted it. I also thought it
looked like an enormous amount of homework. Systems-as-configuration seemed
like one of those hobbies for people who enjoyed configuring the computer more
than using it.

Then AI changed the price of admission.

## WSL was the rehearsal

I did not jump directly from a shell script to handing an AI my partition
table. A few weeks earlier, I had converted the development side of the setup
to NixOS-WSL.

That rewrite introduced a flake, Home Manager, reusable NixOS modules, a small
`dotctl` command, and separately composed profiles for WSL, generic Linux,
macOS, containers, and eventually the native workstation. Shared capabilities
such as the shell, Git, Neovim, development runtimes, cloud tools, terminals,
and Codex are defined once. Host-specific policy is layered on top.

The WSL profile also reconciled the Windows side. Windows-native applications
still belonged to WinGet, because pretending Nix owned software it did not own
would not make the system more declarative. The repository could declare which
Windows applications should exist, maintain the links into WSL, install the
font used by the terminal, and keep Neovide and WezTerm pointed at the right
environment.

Even the awkward state boundaries became explicit. The Windows Codex GUI and
the WSL CLI could share their logical conversation home, but live SQLite files
stayed on WSL's ext4 filesystem, where locking and write-ahead logging behaved
correctly. Authentication, model preferences, plugins, Git identity, and other
machine-local state did not get shoved into a public repository just because
Nix was available.

That distinction matters. Declarative does not mean stateless. It means the
stateful parts stop being surprises.

By the time I started considering native NixOS, the repository was already a
real architecture rather than a pile of generated configuration. The flake
could build multiple targets. Home Manager could reproduce the user
environment. The Windows integration had boundaries. The update workflow
could stage changes, evaluate them, apply them, and commit the known-good
result.

Once the development environment was declarative, the obvious question was
whether I had drawn the boundary in the wrong place. Why was Windows still the
thing owning the machine while Nix owned an increasingly elaborate Linux
island inside it?

The conversation that led to the migration actually began with me complaining
about Windows audio. From there it expanded into a proper audit. What would I
lose on Linux? Which games would work through Proton? Which ones still needed
Windows because of anti-cheat or VR? What would replace Premiere, Photoshop,
Audition, and Snagit? Could I keep my Quest 3 workflow? Could Linux reproduce
the extremely specific trick where a dummy display adapter and a custom NVIDIA
resolution let my iPad Pro act as either a second monitor or my only monitor
from another part of the house?

That last requirement is a good illustration of why “just install a distro”
was never the real task.

I wanted to preserve Windows as a progressively smaller fallback. Rust,
Phasmophobia, official Quest Link, and anything else with an unproven
anti-cheat or VR path could stay there. I wanted native Linux to earn parity
rather than declaring victory because Steam allowed a game to be installed. I
also wanted to migrate in place, using space released from the Windows system
disk rather than moving everything onto another drive.

So I gave the idea the ugliest possible test: migrate the workstation in place
without surrendering Windows, without losing the development environment, and
without losing the remote-display setup I used to reach the machine.

## Why AI and Nix fit together so well

Before getting into the migration itself, it is worth spelling out why this
pairing works.

An AI with terminal access is very good at exploration. It can inspect files,
query services, read logs, compare package options, trace a process tree,
search source code, and connect symptoms across parts of the system faster than
I can keep all those details in my head. I can describe intent at the level I
actually care about:

> Keep Windows, but make it the fallback. Do not reboot without asking me.
> Preserve my remote pairing. I want the dummy display off when I am not using
> it. I never want this computer to sleep. Make launching an already-open app
> take me to its window.

Those are policies, not commands. Converting them into a correct implementation
can involve bootloaders, filesystems, systemd, Wayland protocols, kernel
parameters, udev, package overlays, application patches, and user-level
configuration. AI is extremely useful at translating between those layers.

But an AI operating imperatively has a serious weakness: it can create a
snowflake at conversational speed. A hundred individually reasonable shell
commands can leave behind a machine nobody fully understands. The chat may
eventually be summarized. A new session may not know why a file was edited.
The package manager may later overwrite a manual fix. The AI can forget, just
like I can.

Nix provides the missing constraint system.

The configuration gives the AI a structured model of the desired machine.
Evaluation catches invalid combinations. Builds test whether the configuration
can produce a complete result before that result becomes the active system.
Git shows exactly what changed. Nix generations make experiments reversible.
Modules give successful experiments a place to live. Assertions and checks can
turn an assumption into an executable invariant.

The collaboration developed a repeatable loop:

```text
intent -> inspect -> declare -> evaluate/build -> activate -> observe -> commit
```

That loop is a declarative ratchet. Every time we learn something, the machine
can move forward and record the lesson. It does not need to slide back into the
same failure because one of us forgot an incantation.

The conversation is working memory. Git is long-term memory. A Nix generation
is a checkpoint I can boot.

This does not make every AI action correct. A perfectly valid Nix expression
can encode a terrible policy. A generation cannot roll back corrupted user
data, firmware changes, or a physically overheating GPU. Broad machine access
magnifies mistakes as readily as it magnifies useful work.

Trust came from the combination: read-only discovery first, explicit human
approval for destructive boundaries, builds and checks before activation,
reviewable diffs, known rollback paths, and a declarative destination for every
fix that was meant to persist.

The AI was the adaptive operator. Nix was the durable memory and the guardrail.

## We built a migration appliance, not an install command

The first native migration commit added more than a conventional host
configuration. It added a custom installer, a recovery environment, a Windows
handoff exporter, a machine-manifest validator, iPad display tools, bootloader
recovery, and a confirmation-gated installation script. The installer was an
output of the same flake that would define the final workstation.

Windows created the new partitions in space released from its own partition.
The Linux installer was deliberately not allowed to resize Windows, invent a
partition layout, repair the shared EFI System Partition, or reboot the
machine. It received an exact machine manifest captured from Windows and
validated the disk model, geometry, GPT identities, partition types, and
extents before any write. It would format only the two intended NixOS
partitions, and only after I typed the canonical target back to it.

The boot design preserved the existing Windows EFI partition and placed NixOS
kernels on a separate XBOOTLDR partition. The NixOS root used Btrfs subvolumes
for the root filesystem, home, the Nix store, and swap. The installer recorded
and verified the Windows bootloader state before and after installing the NixOS
loader.

The recovery image also had to carry continuity. That meant more than copying
the repository. A locally generated, hash-manifested handoff capsule contained
a verified Git bundle, the machine manifest, the selected Codex conversation
state, and the Sunshine material required to preserve the existing Moonlight
pairing. Secrets stayed out of the ISO and out of Git.

Yes, the AI helped build a mechanism for resuming the AI after the computer
rebooted. We got a little recursive.

The installer itself would not reboot. That was one of my earliest and most
repeated rules: do not reboot without asking me. The final action remained mine
because rebooting was not merely a technical transition. It could cut off the
current session, interrupt other work, or leave me standing in front of a
firmware screen with no recovery instructions.

The image was built and checked like another software artifact. We verified
the expected volume ID, the EFI loader, the initrd behavior required to locate
an ISO stored as a file, and the copied boot layout. The ISO could be rehearsed
under OVMF without exposing the host disks.

This is the first place the AI/Nix combination stopped feeling like a better
package installer. I was describing safety properties in conversation, and
those properties were turning into code that would refuse to operate if the
physical machine no longer matched the plan.

Nix did not make formatting a partition harmless. It made the dangerous edge
small, explicit, inspectable, and difficult to reach by accident.

## Then the clean model met the grubby physical world

The migration did not proceed as one triumphant green build.

The internal installer staging failed first. The recovery partition was FAT32,
the installer was being booted from an ISO stored as a file, and seemingly
small assumptions about the initrd, `findiso=`, copied GRUB entries, activation
order, and FAT permissions mattered. We iterated through several builds before
the complete boot path was correct.

Then came the scary part. After the first live-installer boot, I returned to
Windows for filesystem checks. During the sequence Windows ran CHKDSK, showed
several strange symptoms, WSL became unreliable, the machine froze, and one
boot fell into automatic diagnostics. When Windows returned, it and the WSL
storage were reporting corruption symptoms.

I am being careful with that wording because we never proved a simple causal
story. “NixOS corrupted Windows” would be dramatic and unsupported. What we
could establish from the recovery environment was narrower and more useful:
the Windows partitions had not been resized by Linux, the intended NixOS
target had not been written, the Windows volumes could be audited read-only,
and no personal-file casualty was identified. The WSL virtual disk and its
ext4 filesystem both had recovery work pending. Repair was deferred rather
than improvising Linux-side surgery against Windows data.

That was the moment when the tiny recovery partition went from a cautious
extra to, in my words, “our saving grace right now XD.”

Recovery exposed another class of problem: the agent's own continuity. The
original handoff capsule represented the conversation at export time. New work
performed inside the live environment existed in an updated private import,
but the resume command kept importing the frozen physical capsule. A fresh
Codex session could not see the main conversation because it lived in the
isolated recovery home. Paths changed from the live installer's temporary user
to my installed user. A synthetic prompt that was supposed to help resume the
work instead kept getting injected when I wanted to reconnect normally.

Then the web terminal disappeared. The terminal server had not crashed; the
live environment had automatically entered deep sleep. Suspend froze the user
slice and dropped the network. The detached tmux session and Codex process
survived, but the model request that was in flight never recovered. I eventually
killed the stuck process and reattached from a local terminal.

This is where the story could become a warning about AI. It became the
opposite.

Every one of those failures became a durable improvement:

| Failure                                   | What the machine learned                                                             |
| ----------------------------------------- | ------------------------------------------------------------------------------------ |
| The physical handoff capsule became stale | Publish validated, timestamped checkpoints tied to the original manifest             |
| A browser disconnect owned the shell      | Put the durable shell and Codex process in a separate tmux service                   |
| Suspend killed remote recovery            | Inhibit sleep during recovery, then declare the workstation's final on-or-off policy |
| Resume paths changed between environments | Normalize and validate the imported conversation paths                               |
| Windows and WSL state were uncertain      | Audit read-only and define exactly which mutable data mattered                       |
| Experimental desktops failed messily      | Add session health tracking and an automatic Plasma fallback                         |

The checkpoint tool took an online SQLite backup, captured a complete
conversation rollout, hashed every payload, and published it atomically. The
resume tool learned to reuse the active import and apply the newest checkpoint
that belonged to the immutable handoff manifest. The browser became only a
viewer. Tmux owned the process. A disconnect could detach me without destroying
the work.

The browser console was deliberately a temporary, trusted-LAN recovery tool,
not an internet-facing administration service. I would not expose it publicly;
proper authentication and transport security belong in any permanent version.

My contribution to the sleep policy was less nuanced: “I never want my PC to
sleep. Period. It's either on or it's off.”

That sentence is exactly the kind of interface I want with a machine-level AI.
I should decide the policy. The AI should know how that policy maps across
systemd, the desktop environment, the recovery environment, and remote-access
services. Nix should ensure the computer remembers the decision after both of
us have moved on.

## “Hours??” is also part of the interface

The funniest wrong turn involved the WSL virtual disk.

We wanted to preserve anything valuable before rebuilding the old WSL
environment. The initial interpretation was conservative: copy the whole
roughly 190 GB virtual disk. When the estimate arrived, I asked why on Earth we
were doing that. Was this even the development disk, or mostly Docker and Nix
store data we could reproduce?

This was the whole accumulated WSL virtual disk, not a 190 GB NixOS
installation.

The copy was stopped. The incomplete copy was removed. We mounted and inspected
the source read-only, focused on the Git repositories under my code directory,
checked for changes that needed to be committed and pushed, and preserved the
small amount of selected non-repository data that actually mattered. Docker
state was ephemeral by design. The NixOS-WSL environment could be rebuilt
later—or never, if native NixOS replaced it.

This is an important counterweight to the “autonomous AI administrator” story.
The agent can inspect a filesystem and propose the safest conservative action.
It cannot know that I value one uncommitted repository more than 180 GB of
reproducible cache unless that intent exists somewhere.

I supplied the value judgment. The AI supplied the inventory, checks, and
implementation. Nix supplied confidence that much of the discarded environment
really was reproducible.

Machine-level AI does not remove the human from systems engineering. It moves
the human up the stack. I spent less time memorizing filesystem and bootloader
commands and more time deciding what the machine was supposed to protect.

## Landing in native NixOS

Once the guarded installer ran, the native system came up with my user, the
complete dotfiles history, the development environment, the same Codex thread,
and the existing Moonlight pairing. Windows was preserved as a boot target by
design. Part of the old data-drive capacity became a Btrfs data filesystem,
with a dedicated games directory configured to avoid copy-on-write
fragmentation.

From there parity arrived in small generations.

The machine gained the NVIDIA driver stack, 32-bit graphics support, PipeWire,
Steam, GE-Proton, Gamescope, GameMode, Docker, OBS, browsers, 1Password,
Discord, Slack, Linear, and a Teams web app. The Adobe-shaped gaps were filled
with Kdenlive, GIMP, Krita, Audacity, Ardour, Flameshot, and ksnip. My existing
shell, Neovim, Codex, language runtimes, cloud tools, and Git workflow came from
the same shared Home Manager modules used by WSL and available across the
repository's macOS profiles.

Not every declared package was immediately proven. Steam being willing to
install Rust or Phasmophobia does not prove the current anti-cheat path or every
multiplayer update. Official Quest Link remained a reason to keep Windows;
WiVRn and ALVR were installed as Linux experiments, not declared victories.
Doom: The Dark Ages did launch and play on NixOS, which was a much more useful
test of this specific machine than a compatibility checkbox.

That distinction—declared, built, launched, tested under load, actually trusted
for daily use—became part of the workflow. AI is happy to collapse those states
into “done” if nobody insists on evidence. The configuration and our checks made
it easier to keep them separate.

At the snapshot represented by this article, the native migration covered 38
[commits, 81 files, and roughly 11,654 added lines](https://github.com/AlexAllocated/.dotfiles/compare/d7a5331...6321409).
The number is not impressive because more configuration is inherently better.
It is impressive because the work crossed boot, storage, recovery, graphics,
streaming, applications, desktops, input devices, and developer tooling in a
few days—and the result is reviewable source rather than a pile of forgotten
commands.

## Installing Slack was boring. The iPad was interesting.

The best example of the new relationship is the iPad display.

On Windows, I had plugged a dummy DisplayPort adapter into the RTX 3090 Ti and
created a custom 2732×2048 mode in NVIDIA Control Panel. Sunshine captured that
display and Moonlight rendered it on the iPad Pro without rescaling. When the
LG ultrawide was on, the iPad could be a second monitor. When the LG was off,
the iPad could become the whole workstation.

This requirement crossed far more of the Linux graphics stack than I initially
appreciated. The dummy adapter's stock EDID did not advertise the iPad mode.
Wayland compositors had different output-control mechanisms. KMS display
indexes could change when the physical monitor disappeared. Sunshine needed to
survive the login screen and switches between desktop sessions. The dummy
could not remain active while unused or my mouse and windows would vanish onto
an invisible monitor.

The final system generates an EDID containing the exact 2732×2048 timing and
validates it with `edid-decode` during the build. The LG is declared at its
native 3440×1440, 160 Hz, and 100% scale. The iPad output uses 175% scale. It is
disabled while idle, enabled and sized before a Moonlight stream, and disabled
again after the final client disconnects.

A simplified version of the policy looks like this:

```nix
outputs = {
  ultrawide = {
    mode = "3440x1440@160";
    scale = 1.0;
    focusAtStartup = true;
  };

  ipad = {
    enable = false; # Sunshine owns the streaming lifecycle.
    mode = "2732x2048@60";
    scale = 1.75;
  };
};
```

The actual configuration uses validated physical connectors rather than those
friendly names, but the intent is exactly that readable.

Sunshine runs as a system-level service beneath the display manager and the
selectable desktop sessions while still running under my user identity with
the capabilities it needs for KMS capture. That means switching from Niri to
Plasma does not also destroy the remote-access foundation I may need to recover
from the switch.

We patched Sunshine to select the stable connector name rather than a volatile
numeric KMS display index and to run the display teardown after the last client
disconnects. Niri and a small helper evacuate workspaces associated with the LG
when it disappears and restore those workspaces when the monitor returns.
Workspaces that already belonged to the iPad stay there.

The two displays even receive different native-resolution versions of the same
Gruvbox pixel-art meadow wallpaper, because once the machine is a codebase it
becomes dangerously easy to care about details like that.

We explored NVENC, rebuilt Sunshine with the needed CUDA support, and verified
the hardware path. Under demanding game load, however, the Linux CUDA interop
path could stall the capture consumer. The current configuration uses
Sunshine's declared Vulkan encoder and retains NVENC support as a fallback.

During Doom, the video stream repeatedly froze while audio continued and game
input remained responsive. Reconnecting Moonlight restored the picture. We
investigated the capture path, but there was also a separate physical problem:
a cooling and airflow problem inside the computer.

It turns out one of our graphics problems was not Linux, Wayland, NVIDIA, or
AI. It was airflow.

That lesson belongs here too. Declarative architecture can describe the driver,
service, encoder, display policy, and temperature-monitoring tools. It cannot
magically observe physical context the user has not exposed. I was still the
person who could walk over to the chassis and realize it was hot.

This entire display workflow began as a plain-language requirement: make the
iPad behave the way it did on Windows. The AI traced that intent through EDID,
KMS, systemd, Sunshine, compositor IPC, workspace ownership, and client
lifecycle. Nix turned the answer into a machine policy.

That is machine-level AI.

## Rollback made taste testable

Once the base system was stable, I started having fun.

Plasma was the first desktop because it was the practical, proven baseline. I
then asked what the “new hotness” was among Linux desktop nerds. We installed
Hyprland and Niri side by side. Later we added Mango, COSMIC, Noctalia, and DMS
in different combinations.

This did not all work on the first try. Hyprland became non-interactable.
Several freezes clustered around Noctalia's first-run dialog. Mango and COSMIC
handoffs occasionally produced a black screen, a mouse cursor, or one very
convenient surviving terminal. Stale compositor sockets and user services could
leak between sessions. Plasma taskbar launchers once captured generation-specific
Nix store paths, so pinned icons broke after a rebuild.

The response was not to accumulate a page of recovery commands. We built a
desktop dispatcher.

```console
desktop-switch niri
desktop-switch mango
desktop-switch plasma
```

The dispatcher remembers the selected environment, ends the current graphical
login cleanly, refreshes the user service manager so stale Wayland state does
not cross the boundary, and leaves system-level Sunshine and recovery running
underneath it. Three short failures of the same experimental desktop select
Plasma automatically. A session that stays alive long enough clears its failure
history.

The first-run ambiguity was removed declaratively. Telemetry was disabled.
Taskbar launchers became stable desktop IDs rather than paths into one Nix
generation. A compositor experiment was no longer a bet that I could remember
how to undo every file it created.

And my preferences changed through use.

Hyprland looked great but never became reliable on this machine. Mango was
immediately fun: animated layouts, layout cycling, and the ability to make a
window global across workspaces produced some genuinely slick workflows. I
still keep it installed. Niri took longer to click, but its infinite horizontal
strip and seamless relationship between windows and workspaces eventually won
me over for daily use. Plasma remains the known-good fallback.

Once I knew what I liked, Hyprland, COSMIC, and DMS came back out of the flake.
Their sessions disappeared from the login screen and the switcher. Their Home
Manager configuration disappeared, and the now-unused DMS dependencies left the
lockfile. The rejected experiment became a source deletion rather than an
archaeological dig through package-manager state.

The terminal contest followed the same pattern. I tried Ghostty, Kitty,
Alacritty, WezTerm, and Konsole. Ghostty had prompt redraw artifacts on this
setup. Kitty behaved well but did not give me a compelling reason to keep it.
WezTerm needed a specific native-Wayland/OpenGL configuration under Niri but
remains the feature-rich alternative. Alacritty—the one I expected to dismiss
for being too minimal—was consistently fast and predictable, so it became the
default. Tmux owns durable sessions and optional panes; both remaining
terminals use Gruvbox Dark, the same ridiculous blue Nerd Font, and 90% opacity.

I cannot believe I am saying this, but the boring terminal won.

Rollback did more than protect me from broken configurations. It made taste
cheap to explore. Instead of deciding which compositor sounded best from a
YouTube video, I could ask the AI to express several complete choices in the
same architecture, use them on my real hardware, keep the parts I liked, and
delete the rest cleanly.

## The machine boundary kept expanding

Package installation turned out to be the least interesting part of the work.

My Razer setup, for example, contained years of Synapse profiles across a
Huntsman keyboard, Tartarus keypad, and Basilisk mouse. The Windows data was
extracted read-only. Ordinary mappings and eight Tartarus layouts were
translated into tracked Input Remapper profiles. The Caps Lock/Escape swap on
the Huntsman was migrated and verified. OpenRazer and Polychromatic handle the
supported lighting, DPI, polling, and battery functions.

The Basilisk's private controls were a deeper problem. The receiver exposed
interfaces that existing Linux tooling could see but could not fully program.
The eventual design modifies only the volatile Linux-facing profile, maps four
private controls to F13 through F16, and lets Input Remapper translate those
events. It leaves the persistent Windows onboard profile alone. That protocol
work became an [upstream pull request](https://github.com/geezmolycos/razerqdhid/pull/6)
rather than remaining an opaque local hack.

The migration is intentionally described as partial. Synapse-only features such
as executable-driven profile switching, some macros, analog actuation, and
Snap Tap do not become equivalent merely because we wrote a Nix module.

For sharing the desktop keyboard and mouse with a nearby Mac, we initially
looked at Synergy. Niri does not implement the InputCapture portal that Synergy
and Deskflow expect, so the NixOS side moved to Lan Mouse and its Wayland-friendly
capture path. The service and host capability are declared; the Mac still owns
its local client, permissions, and pairing ceremony. Private peer identity
correctly remains outside Git.

Even the application launcher crossed into source-level behavior. In Niri, I
wanted choosing an already-running application to take me to its existing
window rather than quietly doing nothing. We patched Noctalia's launcher to
resolve the application against Niri's window metadata and focus it. Firefox
needed a preference for its main window over Picture-in-Picture. Most launcher
cases now behave the way I expect. Electron tray icons remain an unreliable SNI
identity edge, so we stopped pretending that part was solved.

These are small examples individually. Together they show why “AI configured
my dotfiles” undersells what happened. The agent moved between Nix modules,
system services, Wayland protocols, application source, USB HID behavior,
firewall policy, desktop launchers, and physical testing. Successful discoveries
flowed back into the repository or, where appropriate, toward upstream.

## The computer became durable shared memory

The most surprising lesson was not about Nix syntax. It was about memory.

AI conversations feel continuous while they are working, but their context is
not an operating-system database. Sessions disconnect. Context gets compacted.
Processes hang. A new model invocation may understand the repository better
than it understands the three hours of troubleshooting that led to the current
state.

Humans have the same problem on a longer timescale. I have absolutely fixed a
Linux issue, moved on with my life, and discovered six months later that I had
no idea why a weird line existed in a startup file.

The solution is not a larger chat transcript. The solution is to promote
knowledge out of the conversation.

When we learned that the machine should never sleep, that became system policy.
When a browser disconnect threatened recovery, process ownership moved into
tmux and systemd. When the dummy display's numeric identity changed with
topology, connector identity became part of the Sunshine patch. When Plasma
launchers captured Nix store paths, stable desktop IDs became an invariant.
When an experimental session froze repeatedly, the dispatcher learned when to
fall back. When the agent's recovery state could become stale, checkpoints
became hashed artifacts.

That is the declarative ratchet in practice: observation becomes policy, policy
becomes a tested generation, and the verified result becomes history instead
of another thing we have to remember.

The repository is not merely a backup of configuration files. It is the shared
model through which the AI and I understand the machine.

This also explains why declarative architecture makes broad AI access feel
less reckless than it otherwise would. The goal is not to let a chatbot
freestyle as root. The goal is to route durable changes through a control plane
that can be inspected, evaluated, built, compared, and reversed.

There are still mutable boundaries:

- Browser profiles, Steam libraries, documents, and databases are data, not
  Nix expressions.
- Authentication, Sunshine keys, Git identity, and peer fingerprints belong
  in machine-local state or a secret system, not a public flake.
- Firmware and persistent peripheral profiles need explicit safety models.
- A Nix rollback cannot undo filesystem corruption or cool a graphics card.
- A locally pinned patch is reproducible, but it still creates future rebase
  work.

The architecture is powerful because those boundaries are intentional, not
because they have been wished away.

## Declared is not the same as live

Nix also gave us a much clearer definition of “done.”

AI has a dangerous tendency to treat the file edit as the result. The code is
there, the syntax looks plausible, and the response says the work is complete.
But there are several different states hiding inside that sentence:

1. The repository contains the intended declaration.
2. The declaration evaluates.
3. The target builds.
4. The new generation is activated.
5. Any affected process has reloaded or restarted.
6. The running system reports the expected state.
7. The behavior actually feels correct to the person using it.

We hit a wonderfully small example while finishing this article's source
material. I asked for WezTerm to use 90% opacity. The configuration changed,
validated, committed, and pushed. I opened WezTerm and said, essentially, “It
doesn't look like it took.”

It had not.

The repository was correct, but my live Home Manager profile still pointed at
the previous immutable generation, where the setting remained commented out.
The AI inspected the live symlink, saw the mismatch, built a new system
generation, activated it, and verified that the active file contained the new
value. Sunshine was checked afterward because keeping the remote path alive was
part of the machine policy, not an optional courtesy.

That tiny incident contains the whole model. Git state, build state, activation
state, process state, and human-visible behavior are related, but they are not
interchangeable. Nix makes those boundaries unusually observable. A future
agent should be able to report them explicitly:

```text
declared revision: current
built generation: current
running generation: current
service health: passing
human validation: pending
rollback generation: available
```

The final line matters. Machine-readable checks can confirm that an EDID
contains the requested timing, a service is active, or a configuration file has
the right value. They cannot tell me whether the scale is comfortable from the
couch, whether Niri's movement model has finally clicked in my brain, or whether
a terminal redraw glitch is annoying enough to reject the application.

The AI could verify the system. I still verified the experience.

## What AI actually changed

None of the individual technologies here are new. NixOS could already build
generations. Home Manager could already manage a user environment. Git could
already review diffs. Systemd could already supervise services. Linux hackers
could already reverse-engineer hardware and patch applications.

AI changed the latency between intent and implementation.

Without it, this migration would have required me to become temporarily expert
in every layer it crossed. I would have needed to research NixOS installation,
systemd-boot, XBOOTLDR, Btrfs subvolumes, NVIDIA on Wayland, KMS capture, EDID
construction, Sunshine internals, several compositor configuration languages,
systemd user-session behavior, USB HID reports, Input Remapper formats, and the
state layout of every application I wanted to preserve.

I could learn all of those things. I like this stuff. That is precisely why I
know how much time it would take.

Instead, I spent most of my attention on intent and verification:

- Windows must remain available.
- Do not reboot without my explicit approval.
- Do not copy hundreds of gigabytes when the valuable state is a handful of
  repositories.
- The iPad must receive its native resolution.
- The dummy display must disappear when it is not in use.
- Sunshine must survive desktop changes.
- This desktop feels good; that one does not.
- Caps Lock should be Escape.
- The computer should be on or off, never asleep.

The AI handled an enormous amount of research, code generation, source
inspection, build iteration, log correlation, and verification between those
decisions. When it was wrong, I could challenge the premise rather than debug
every command myself. “Why are we copying 190 GB?” was enough to redirect an
entire preservation strategy.

This is not less systems engineering. It is systems engineering at the speed
of conversation.

The declarative substrate kept that speed from turning into chaos. Every time
the agent produced a durable change, it had to fit into the same configuration
graph as everything else. The build either evaluated or it did not. The diff
either represented my intent or it did not. The service came back after
activation or we investigated. The old generation remained available.

AI made the rigor cheap enough to use everywhere.

## Why the rough edges make me more optimistic

It would be easy to look at the recovery story and conclude that this approach
is premature. I came away with the opposite reaction.

The hard parts were not mystical limitations of intelligence. They were
interfaces.

The agent needed a better durable session boundary, so we gave it tmux and
systemd. It needed state that could survive a reboot, so we built a verified
capsule and incremental checkpoints. It needed to distinguish immutable
configuration from mutable data, so we made that boundary explicit. It needed
safe authority around disks and reboots, so we wrote manifests, typed
confirmations, and human gates. It needed stable hardware identities, so the
configuration stopped relying on transient numeric indexes.

Those are tractable engineering problems. More importantly, we solved useful
versions of them during the migration itself.

Future machine-level agents will have better structured access to hardware
inventory, Nix evaluation results, generations, service health, recovery
checkpoints, and permission boundaries. They will be able to propose a complete
candidate generation, explain the policy-level diff, run acceptance tests, and
activate or roll back through narrower capabilities. Long-running work will
not depend on one browser tab or one model request surviving forever.

Reusable modules and upstream fixes will make the next machine easier. The
custom EDID logic, session dispatcher, recovery model, and hardware mappings no
longer need to be rediscovered from zero. The rough water becomes part of the
chart.

And the important point is that the future-facing version is not required to
make this useful. It was already useful enough to move my primary workstation
to NixOS, preserve Windows, restore my development environment, improve my
remote workflow, and let me explore a completely new desktop model over the
course of a few days.

I did not spend those days alone in documentation, afraid to touch the next
layer. I described what I wanted, approved the dangerous boundaries, tested the
result, and corrected the machine when reality disagreed.

That was infinitely simpler than doing all of it myself.

## What is actually proven

One thing this process cured me of is parity theater. A package appearing in a
launcher is not the same as a workflow being trustworthy. A game installing is
not the same as its multiplayer anti-cheat working. A service marked active is
not the same as the client on the other machine being paired and usable.

The native development environment is proven in daily work. Windows remains
installed beside NixOS as the intended fallback; I am not pretending its
deferred repair and validation work is complete. Niri with Noctalia is working
as my primary desktop, Mango is a working alternate, and Plasma is the recovery
baseline. The custom iPad mode, Sunshine stream lifecycle,
physical-monitor-off behavior, and native-resolution Moonlight connection have
all been exercised on the real hardware. Doom ran through Proton. The central
Huntsman Caps Lock-to-Escape mapping works, and the recovered Tartarus profiles
are installed for continued validation. The system can be rebuilt and activated
from the repository, and the recovery path no longer depends on one browser
connection surviving forever.

Other capabilities are intentionally described as experimental or incomplete.
The whole Steam library has not been proven. WiVRn and ALVR are available for
Linux VR experiments, while official Quest Link stays on Windows. The Mac side
of Lan Mouse still owns its client installation, Accessibility permission, and
trust handshake. Some old iPhone camera and creative workflows need more real
use. The Razer migration covers the ordinary profiles and the private-button
bridge, not every Synapse-only macro, analog feature, or automatic
per-executable switch.

Windows remains responsible for anything whose Linux replacement has not earned
trust yet. That is not a failure of the migration. It is the reason the
migration could be ambitious without becoming reckless.

I did not move to Linux to win an argument about Linux. I moved because NixOS
became the better primary environment, and declarative architecture let Windows
remain a narrow compatibility layer instead of an all-or-nothing decision.

## Where I landed

The workstation now boots native NixOS for development, normal desktop use,
and an expanding share of gaming. Windows remains intentionally installed for
the things whose compatibility I have not proven or whose official tooling is
still Windows-only.

Niri with Noctalia is my preferred daily desktop. Mango remains available
because its layouts and global-window behavior are too much fun to throw away.
Plasma remains the reliable fallback and recovery baseline. Alacritty is the
default terminal; WezTerm is the feature-rich alternative; tmux provides
durable sessions when I need them.

Sunshine can survive the login and compositor boundaries, bring up the iPad
dummy at the correct resolution, and tear it down when streaming ends. Niri can
move the relevant workspaces when the physical display disappears. The machine
has a recovery path beneath the graphical desktop. Razer mappings, creative
tools, development runtimes, communications applications, and much of the game
stack are represented in the same architecture.

Routine maintenance is now intentionally boring:

```sh
updoot
```

That command stages updates, evaluates the supported configurations, exercises
the editor automation, applies the validated result, commits it, reconciles any
late upstream changes, validates again, and pushes. The exact implementation
will continue to evolve, but the principle is the point: maintenance is itself
part of the system design.

This machine is not finished, because no personal workstation is ever
finished. Windows still needs its own care. Some games and VR paths remain
fallback territory. The Mac side of keyboard sharing still has a local
permission ceremony. Razer's proprietary features are not all reproduced.
Pinned patches will eventually need rebasing or upstream releases.

But I no longer have an AI-maintained snowflake. I have the opposite: a boring,
versioned, rebuildable system whose unusual behavior is encoded close to the
reason it exists.

I started by asking AI to migrate a Windows workstation. I ended with a machine
architected so that both of us can understand it.

The computer stopped being the sum of everything I had ever done to it and
started being the result of a build.

That is why this feels bigger than NixOS, and bigger than one successful Linux
migration. The future of machine-level AI is not a chatbot improvising commands
with unlimited authority. It is agents working through declarative systems
that preserve human intent, expose meaningful diffs, validate assumptions, and
offer real recovery.

AI did not replace the architecture. It made the architecture accessible at
the speed I wanted to use it.

And the architecture is what made the AI feel powerful.
