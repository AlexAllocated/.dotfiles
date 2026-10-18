"""Small, standard-library control plane. Local evidence is never Git content."""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import unquote

SCHEMA = 1


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def age(timestamp):
    return (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(timestamp)).total_seconds()


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def mason_receipt_purl(receipt):
    """The resolved source is authoritative; install_options records the request."""
    if not isinstance(receipt, dict):
        return None
    try:
        schema = int(str(receipt.get('schema_version', '2.0')).split('.', 1)[0])
    except ValueError:
        return None
    source = receipt.get('source' if schema >= 2 else 'primary_source', {})
    purl = source.get('id') if isinstance(source, dict) else None
    return purl if isinstance(purl, str) else None


def mason_receipt_version(receipt):
    """Extract Mason's PURL version, excluding qualifiers and subpath metadata."""
    purl = mason_receipt_purl(receipt)
    if not purl or not purl.startswith('pkg:'):
        return None
    # Match Mason's component order: subpath, qualifiers, then version. Decode
    # only after splitting, so an encoded delimiter remains part of the version.
    package, separator, version = purl.rsplit('#', 1)[0].rsplit('?', 1)[0].rpartition('@')
    if (not separator or not version or '/' in version or '/' not in package[4:]
            or not package.rsplit('/', 1)[-1]):
        return None
    return unquote(version)


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def run(argv, *, cwd=None, timeout=60, env=None, check=True):
    result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env,
                            text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{argv[0]} exited {result.returncode}: {result.stderr[-3000:]}')
    return result


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def nix_source(root):
    """Local Git source includes tracked working changes, excluding ignored runtime files."""
    return 'git+' + Path(root).resolve().as_uri()


class Context:
    def __init__(self, root, state=None):
        self.root = Path(root).resolve()
        self.state = Path(state or os.environ.get('DOTCTL_STATE_HOME',
                          str(Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'dotfiles'))).expanduser().absolute()
        self.policy = read(self.root / 'catalog/policy.json', {})

    def git(self, *args, **kwargs):
        return run(['git', '-C', self.root, *args], **kwargs).stdout.strip()

    @contextlib.contextmanager
    def lock(self, name='maintenance'):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state / (name + '.lock')).open('a') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError(f'{name} is already running; inspect status before retrying') from exc
            yield

    def save(self, name, value):
        atomic(self.state / name, value)

    def load(self, name, default=None):
        return read(self.state / name, default)


def envelope(kind, **data):
    return {'schema_version': SCHEMA, 'kind': kind, **data}
