"""Unlock the existing default keyring using a TPM-sealed system credential."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

import secretstorage
from secretstorage.collection import Collection
from secretstorage.util import DBusAddressWrapper, format_secret, open_session


INTERNAL = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"
ROOT = "/org/freedesktop/secrets"
CREDENTIAL = Path("/var/lib/tracer-keyring/keyring-password.cred")


def unlock(password, force=False):
    with secretstorage.dbus_init() as connection:
        service = DBusAddressWrapper(ROOT, "org.freedesktop.Secret.Service", connection)
        collection_path, = service.call("ReadAlias", "s", "default")
        if collection_path == "/":
            raise RuntimeError("No existing default keyring; refusing to create one")
        collection = Collection(connection, collection_path)
        if not force and not collection.is_locked():
            return
        session = open_session(connection)
        if not session.encrypted:
            raise RuntimeError("Keyring does not support encrypted password transport")
        internal = DBusAddressWrapper(ROOT, INTERNAL, connection)
        internal.call(
            "UnlockWithMasterPassword", "o(oayays)", collection_path,
            format_secret(session, password, "text/plain; charset=utf-8"),
        )
        if collection.is_locked():
            raise RuntimeError("Keyring remains locked")


def verify_copy(password):
    # Validate without locking the live keyring or interrupting signed-in apps.
    with tempfile.TemporaryDirectory(prefix="keyring-verify-", dir=os.environ["XDG_RUNTIME_DIR"]) as tmp:
        root = Path(tmp)
        data = root / "data"
        source = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "keyrings"
        shutil.copytree(source, data / "keyrings")
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        env = os.environ.copy()
        env.update(XDG_DATA_HOME=str(data), XDG_RUNTIME_DIR=str(runtime))
        for key in ("DBUS_SESSION_BUS_ADDRESS", "GNOME_KEYRING_CONTROL", "GNOME_KEYRING_PID"):
            env.pop(key, None)
        result = subprocess.run(
            ["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()), "verify"],
            input=password, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=25, check=False,
        )
        if result.returncode:
            raise RuntimeError("That password did not unlock the existing default keyring")


def enroll():
    dialog = subprocess.run([
        "zenity", "--password", "--title=Unlock keyring automatically on Tracer",
        "--text=Enter the password for your existing default keyring. It will be validated locally and sealed to this PC's TPM.",
    ], stdout=subprocess.PIPE, check=False)
    if dialog.returncode:
        return
    password = dialog.stdout.removesuffix(b"\n")
    if not password:
        raise RuntimeError("An empty password is not supported")
    verify_copy(password)
    subprocess.run(["/run/wrappers/bin/sudo", "-n", "install", "-d", "-m", "0700", str(CREDENTIAL.parent)], check=True)
    # Only ciphertext is written to disk; the password travels over stdin.
    temporary = str(CREDENTIAL) + ".new"
    try:
        subprocess.run([
            "/run/wrappers/bin/sudo", "-n", "systemd-creds", "encrypt", "--with-key=host+tpm2",
            "--tpm2-pcrs=7", "--name=keyring-password", "-", temporary,
        ], input=password, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/run/wrappers/bin/sudo", "-n", "chmod", "0600", temporary], check=True)
        subprocess.run(["/run/wrappers/bin/sudo", "-n", "mv", "-f", temporary, str(CREDENTIAL)], check=True)
    finally:
        subprocess.run(["/run/wrappers/bin/sudo", "-n", "rm", "-f", temporary], check=False)
    subprocess.run(["/run/wrappers/bin/sudo", "-n", "systemctl", "restart", "tracer-keyring-unlock.service"], check=True)
    subprocess.run(["zenity", "--info", "--title=Keyring setup complete",
                    "--text=The password was validated and sealed to Tracer's TPM. Automatic unlocking is enabled."], check=False)


def verify():
    daemon = subprocess.Popen([
        "gnome-keyring-daemon", "--foreground", "--components=secrets",
        "--control-directory=" + os.environ["XDG_RUNTIME_DIR"] + "/keyring",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # Wait for this isolated daemon to own the service; do not invoke a prompt.
        from jeepney import DBusAddress, new_method_call
        from jeepney.io.blocking import open_dbus_connection
        with open_dbus_connection() as connection:
            for _ in range(100):
                reply = connection.send_and_get_reply(new_method_call(
                    DBusAddress("/org/freedesktop/DBus", "org.freedesktop.DBus", "org.freedesktop.DBus"),
                    "NameHasOwner", "s", ("org.freedesktop.secrets",),
                ))
                if reply.body[0]:
                    break
                if daemon.poll() is not None:
                    raise RuntimeError("Isolated keyring exited")
                time.sleep(.05)
            else:
                raise RuntimeError("Isolated keyring did not start")
        unlock(sys.stdin.buffer.read(), force=True)
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait()


def unlock_credential():
    credential = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "keyring-password"
    # This runs synchronously before launching desktop clients. Waiting for
    # graphical-session.target is too late: a client's prompt can already be
    # holding the keyring's initialization path until someone answers it.
    unlock(credential.read_bytes())
    print("Default keyring is unlocked before desktop startup", flush=True)


def check_credential():
    credential = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "keyring-password"
    verify_copy(credential.read_bytes())
    print("TPM credential unlocks an isolated copy of the existing keyring", flush=True)


if __name__ == "__main__":
    try:
        {"enroll": enroll, "verify": verify, "unlock": unlock_credential,
         "check": check_credential}[sys.argv[1]]()
    except Exception as error:
        # Do not emit tracebacks or subprocess arguments near credential handling.
        if sys.argv[1] == "enroll":
            subprocess.run(["zenity", "--error", "--title=Keyring setup failed",
                            "--text=Keyring setup failed. Your existing keyring is unchanged; please retry setup."], check=False)
        print(f"Keyring operation failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
