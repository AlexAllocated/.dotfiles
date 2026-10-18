"""Real isolated GNOME keyring regression; run with the packaged SecretStorage Python."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/nixos/keyring-unlock.py"


def worker():
    import secretstorage
    from secretstorage.collection import Collection
    from secretstorage.util import DBusAddressWrapper, format_secret, open_session
    import time

    spec = importlib.util.spec_from_file_location("keyring_unlock", SCRIPT)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    daemon = subprocess.Popen([
        "gnome-keyring-daemon", "--foreground", "--components=secrets",
        "--control-directory=" + os.environ["XDG_RUNTIME_DIR"] + "/keyring",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(.5)
        with secretstorage.dbus_init() as connection:
            session = open_session(connection)
            assert session.encrypted
            internal = DBusAddressWrapper(helper.ROOT, helper.INTERNAL, connection)
            path, = internal.call("CreateWithMasterPassword", "a{sv}(oayays)", {
                "org.freedesktop.Secret.Collection.Label": ("s", "Custom Default Keyring"),
            }, format_secret(session, b"regression-password", "text/plain"))
            service = DBusAddressWrapper(helper.ROOT, "org.freedesktop.Secret.Service", connection)
            service.call("SetAlias", "so", "default", path)
            collection = Collection(connection, path)
            item = collection.create_item("Test item", {"test": "keyring"}, b"preserved-test-secret")
            collection.lock()
            assert collection.is_locked()
            credentials = Path(os.environ["XDG_RUNTIME_DIR"]) / "credentials"
            credentials.mkdir(mode=0o700)
            (credentials / "keyring-password").write_bytes(b"regression-password")
            startup_env = os.environ.copy()
            startup_env["CREDENTIALS_DIRECTORY"] = str(credentials)
            # No graphical session exists here. The startup barrier must still
            # finish before a client first accesses its stored secret.
            subprocess.run([sys.executable, str(SCRIPT), "unlock"], env=startup_env,
                           check=True, timeout=5)
            assert not collection.is_locked()
            assert item.get_secret() == b"preserved-test-secret"
            collection.lock()
            try:
                helper.unlock(b"wrong-password", force=True)
            except Exception:
                pass
            else:
                raise AssertionError("Wrong password was accepted")
            assert collection.is_locked()
            helper.unlock(b"regression-password")
            assert not collection.is_locked()
            assert item.get_secret() == b"preserved-test-secret"
            try:
                helper.verify_copy(b"wrong-password")
            except RuntimeError:
                pass
            else:
                raise AssertionError("Isolated verification accepted a wrong password")
            helper.verify_copy(b"regression-password")
            assert not collection.is_locked(), "Validation locked the live keyring"
            assert item.get_secret() == b"preserved-test-secret"
            helper.unlock(b"ignored-when-already-unlocked")
            assert item.get_secret() == b"preserved-test-secret"
        print("Encrypted transport, custom default collection, wrong-password rejection, isolated validation and item preservation passed")
    finally:
        daemon.terminate()
        daemon.wait(timeout=5)


class KeyringIntegration(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("KEYRING_INTEGRATION") == "1", "Requires packaged SecretStorage and GNOME keyring")
    def test_encrypted_default_keyring(self):
        with tempfile.TemporaryDirectory(prefix="keyring-regression-") as tmp:
            root = Path(tmp)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            env = os.environ.copy()
            env.update(XDG_RUNTIME_DIR=str(runtime), XDG_DATA_HOME=str(root / "data"))
            for key in ("DBUS_SESSION_BUS_ADDRESS", "GNOME_KEYRING_CONTROL", "GNOME_KEYRING_PID"):
                env.pop(key, None)
            subprocess.run(["dbus-run-session", "--", sys.executable, __file__, "--worker"],
                           env=env, check=True, timeout=40)


if __name__ == "__main__":
    if sys.argv[1:] == ["--worker"]:
        worker()
    else:
        unittest.main()
