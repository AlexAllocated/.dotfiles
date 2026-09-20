# ChatGPT desktop recovery

Tracer enables `dotfiles.chatgptService` for its desktop user. The system-level
`chatgpt-desktop.service` waits for the user's graphical session and Xwayland
socket, then launches ChatGPT with that session's current display environment.
It runs as the user, not root, and keeps the existing login and conversation data.

The supervisor recognizes an already-open app without replacing it. If the app
exits, it reopens within roughly five seconds while the desktop is available.
This also applies to intentionally quitting the app. To keep it closed, run
`sudo systemctl stop chatgpt-desktop.service`; start the service to enable recovery
again. It starts automatically on the next boot.

After a graphical-session replacement, a managed app is relaunched against the
new display. Remote access is unavailable while the app or graphical session is
down; this does not make in-progress tasks survive app termination. Routine NixOS
switches do not restart this service, so package/supervisor updates take effect
after its next restart. No Codex preferences are managed by this module.

Tracer also grants its declared desktop user passwordless sudo through a
host-specific rule. It does not grant this to every member of `wheel` or apply it
to other hosts. All programs running as that user can consequently invoke sudo;
the app itself remains unprivileged until a command explicitly uses it.
