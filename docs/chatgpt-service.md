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

## Unattended keyring unlocking

Tracer's auto-login has no password to unlock the default GNOME keyring. This can
block Codex account initialization and mobile access behind a password dialog.
`dotfiles.keyringUnlock` keeps the existing keyring encrypted and unlocks its
default collection using a systemd credential sealed with the local TPM and
host key. It supports the migrated custom default keyring, not just a collection
named `login`.

Run `keyring-tpm-enroll` once from the desktop. Enter the keyring password in the
local dialog. The helper verifies an isolated copy, then writes only encrypted
credential data under `/var/lib/tracer-keyring`, outside the repository and Nix
store. Passwords are never passed in command arguments or logged; transport to
GNOME keyring uses an encrypted Secret Service session. Each compositor launcher
waits for the unlock service before starting the compositor or desktop clients,
including fresh sessions after a desktop restart. Waiting until the graphical
session is active is too late: a client's password prompt can already be blocking
keyring initialization. The persistent Codex supervisor is stopped during this
barrier and started again afterward, so its old client cannot race the fresh
keyring while the user manager is replaced. Other programs running as the
desktop user can use the unlocked keyring, as after a normal manual unlock.

Re-enroll after changing the keyring password or a firmware/Secure Boot policy
change that invalidates TPM PCR 7. Removing the encrypted credential and stopping
`tracer-keyring-unlock.service` restores manual unlocking. The isolated regression
is `KEYRING_INTEGRATION=1 python3 tests/test_keyring_unlock.py`, using a Python
environment with SecretStorage plus GNOME keyring and D-Bus on `PATH`.

Tracer also grants its declared desktop user passwordless sudo through a
host-specific rule. It does not grant this to every member of `wheel` or apply it
to other hosts. All programs running as that user can consequently invoke sudo;
the app itself remains unprivileged until a command explicitly uses it.

## Missing desktop task tools on NixOS

If desktop task tools such as `create_thread` disappear, check the app logs for
bundled-marketplace materialization failures. The vendor's Linux directory copy
preserves the Nix store's read-only modes in
`~/.codex/.tmp/bundled-marketplaces/openai-bundled.staging-*`. A subsequent plugin
metadata rewrite fails with `EACCES`; cleanup can then fail with another `EACCES`
and obscure the original write error. This can prevent the bundled desktop tools
from resolving even when the desktop IPC connection works.

`packages/chatgpt-desktop.nix` patches that copy operation to make the new staging
copy owner-writable. It preserves executable bits, leaves the source unchanged,
and never follows copied symlinks when changing permissions. The package build
fails if the expected vendor code changes, and its install checks reproduce the
read-only copy, metadata rewrite, cleanup, and symlink boundaries.

Build and activate the updated desktop package through the normal dotfiles
workflow. The running app keeps its old code until restarted; wait until active
tasks have finished before restarting it. No `~/.codex/config.toml` overrides or
plugin preference changes are required. A successful package check does not
prove the restarted app has exposed the tools; verify a real task-tool invocation
after restart.
