"""Inventory registered roots; only explicitly owned disposable scratch can expire."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import time

from core import age, envelope, now, run


PROTECTED_CATEGORIES = {'backup', 'archive', 'recovery', 'migration', 'candidate', 'worktree',
                        'nix-generation', 'nix-root', 'media', 'unclassified'}


def absolute(path):
    # Normalize lexical '..' without resolving (and thereby traversing) a symlink.
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def identity(path):
    s = Path(path).lstat()
    return {'device': s.st_dev, 'inode': s.st_ino, 'mtime_ns': s.st_mtime_ns,
            'ctime_ns': s.st_ctime_ns, 'mode': s.st_mode, 'size': s.st_size}


def mount_table():
    """Read the mount registry before touching paths that might trigger an automounter."""
    if Path('/proc/self/mountinfo').exists():
        result = []
        for line in Path('/proc/self/mountinfo').read_text().splitlines():
            fields = line.split()
            separator = fields.index('-')
            path = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4])
            result.append({'path': absolute(path), 'type': fields[separator + 1]})
        return result
    # macOS has no procfs. mount only lists its kernel registry; it does not mount anything.
    if platform.system() == 'Darwin':
        output = run(['/sbin/mount'], timeout=5).stdout
        result = []
        for line in output.splitlines():
            match = re.match(r'.* on (.+) \(([^, )]+)', line)
            if match:
                result.append({'path': absolute(match[1]), 'type': match[2]})
        if not result:
            raise RuntimeError('Could not read the macOS mount registry; storage scan skipped')
        return result
    raise RuntimeError('No mount registry provider; storage scan skipped to avoid automounts')


def check_path(path, mounts, *, allow_missing=False):
    """Reject automount ancestry and symlinked ancestors before walking a registered path."""
    path = absolute(path)
    if path == Path('/nix/store') or Path('/nix/store') in path.parents:
        raise ValueError('Nix store paths are managed by Nix, not artifact deletion')
    for mount in mounts:
        if mount['type'] == 'autofs' and (mount['path'] == path or mount['path'] in path.parents):
            raise ValueError(f'Skipped automounted path: {path}')
    for component in reversed((path, *path.parents)):
        try:
            mode = component.lstat().st_mode
        except FileNotFoundError:
            if allow_missing:
                return False
            raise
        if stat.S_ISLNK(mode):
            raise ValueError(f'Skipped symlink ancestry: {component}')
    return True


def measure(path, budget=200000, *, mounts=None, seen=None):
    """No symlinks, mount points, cross-device traversal, or duplicate hardlink allocation.

    File descriptors bind each opened directory while it is traversed. The digest describes
    filesystem metadata for cleanup revalidation; it is not a content checksum or restore test.
    """
    path = absolute(path)
    mounts = mount_table() if mounts is None else mounts
    seen = set() if seen is None else seen
    total = count = 0
    complete = True
    errors, flags = [], set()
    latest_mtime = 0
    digest = hashlib.sha256()
    mounted = {m['path'] for m in mounts}
    device = path.lstat().st_dev
    open_flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0)

    def walk(parent_fd, name, lexical):
        nonlocal total, count, complete, latest_mtime
        if lexical != path and lexical in mounted:
            complete = False
            flags.add('nested-mount')
            return
        s = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if s.st_dev != device:
            complete = False
            flags.add('cross-device')
            return
        count += 1
        if count > budget:
            complete = False
            flags.add('entry-budget')
            return
        relative = str(lexical.relative_to(path))
        digest.update(json.dumps((relative, s.st_dev, s.st_ino, s.st_mode, s.st_size,
                                  s.st_mtime_ns, s.st_ctime_ns)).encode() + b'\0')
        latest_mtime = max(latest_mtime, s.st_mtime)
        key = (s.st_dev, s.st_ino)
        if key not in seen:
            total += getattr(s, 'st_blocks', 0) * 512
            seen.add(key)
        if lexical.name == '.git':
            flags.add('git-data')
        if stat.S_ISLNK(s.st_mode):
            flags.add('symlink')
            return
        if not stat.S_ISREG(s.st_mode) and not stat.S_ISDIR(s.st_mode):
            flags.add('special-file')
            return
        if stat.S_ISDIR(s.st_mode):
            fd = os.open(name, open_flags, dir_fd=parent_fd)
            try:
                actual = os.fstat(fd)
                if (actual.st_dev, actual.st_ino) != (s.st_dev, s.st_ino):
                    raise RuntimeError(f'Directory changed during inventory: {lexical}')
                for child in sorted(os.listdir(fd)):
                    if count > budget:
                        break
                    walk(fd, child, lexical / child)
            finally:
                os.close(fd)

    try:
        # Roots and ancestors have already been checked by scan, check again for direct callers.
        check_path(path.parent, mounts)
        parent_fd = os.open(path.parent, open_flags)
        try:
            walk(parent_fd, path.name, path)
        finally:
            os.close(parent_fd)
    except (OSError, ValueError, RuntimeError) as exc:
        complete = False
        errors.append(str(exc))
    return {'allocated_bytes': total, 'entries': count, 'complete': complete,
            'tree_fingerprint': digest.hexdigest(), 'latest_mtime': latest_mtime,
            'flags': sorted(flags), 'errors': errors}


def roots(ctx):
    paths = [absolute(p) for p in ctx.policy.get('artifact_roots', [])]
    paths += [absolute(ctx.state / directory) for directory in ('scratch', 'candidates', 'checks', 'applications')]
    # The outermost root owns totals. Nested registrations remain discoverable inside it.
    return [p for p in sorted(set(paths)) if not any(other != p and other in p.parents for other in paths)]


def register(ctx, path, *, purpose, category, creator, revision=None, disposable=False, references=None):
    """Artifact producer API. Register after creation, before exposing the artifact to users."""
    path = absolute(path)
    mounts = mount_table()
    check_path(path, mounts)
    if not any(root in path.parents for root in roots(ctx)):
        raise ValueError('Artifact must be inside a registered root')
    if disposable and (category != 'scratch' or path.parent != absolute(ctx.state / 'scratch')):
        raise ValueError('Only direct controller scratch directories can be disposable')
    if disposable and not path.is_dir():
        raise ValueError('Disposable scratch must be a directory')
    with ctx.lock('artifacts'):
        ownership = ctx.load('artifact-ownership.json', {})
        old = ownership.get(str(path), {})
        current_identity = identity(path)
        same = old.get('identity', {}).get('device') == current_identity['device'] and old.get('identity', {}).get('inode') == current_identity['inode']
        item = {'purpose': purpose, 'category': category, 'creator': creator,
                'source_revision': revision, 'created_at': old.get('created_at') if same else now(),
                'identity': current_identity, 'disposable': disposable, 'references': references or [],
                'verification': old.get('verification', 'unverified') if same else 'unverified',
                'replacement': old.get('replacement') if same else None,
                'retention_days': max(30, ctx.policy.get('disposable_retention_days', 30)) if disposable else None,
                'active': True if disposable else False}
        ownership[str(path)] = item
        ctx.save('artifact-ownership.json', ownership)
    return item


def update_registration(ctx, path, *, active=None, references=None, verification=None, replacement=None):
    """Explicit lifecycle changes do not retroactively grant disposal to unknown artifacts."""
    path = absolute(path)
    with ctx.lock('artifacts'):
        ownership = ctx.load('artifact-ownership.json', {})
        item = ownership.get(str(path))
        current = identity(path)
        if not item or any(current[key] != item['identity'][key] for key in ('device', 'inode')):
            raise ValueError('Artifact is no longer the registered filesystem object')
        for key, value in {'active': active, 'references': references, 'verification': verification,
                           'replacement': replacement}.items():
            if value is not None:
                item[key] = value
        item['updated_at'] = now()
        ctx.save('artifact-ownership.json', ownership)
    return item


def referenced(ctx, path, exclude=None):
    """Unresolved or unrecognized candidate state protects its artifact references."""
    target = str(absolute(path))
    for candidate in (ctx.state / 'candidates').glob('*/candidate.json'):
        if exclude and candidate.parent.name == exclude:
            continue
        try:
            data = json.loads(candidate.read_text())
        except (OSError, ValueError):
            return True
        if not isinstance(data, dict):
            return True
        # Candidate artifacts are never auto-deleted; scratch cited anywhere is conservatively held.
        if target in json.dumps(data, sort_keys=True) or (exclude and exclude in data.get('references', [])):
            return True
    return False


def _store_paths(value):
    """Extract exact store references from receipts, never treat a closure as unique bytes."""
    return set(re.findall(r'/nix/store/[a-z0-9]{32}-[^\s"/]+', json.dumps(value)))


def managed_symlink_references(ctx, artifact):
    """Inspect only declared operational link locations, without walking the home directory."""
    links = {str(Path.home() / relative) for relative in (
        '.zprofile', '.zshrc', '.gitconfig', '.p10k.zsh', '.wezterm.lua', 'rustfmt.toml',
        '.config/nvim', '.config/neovide/config.toml', '.config/wezterm', '.local/bin/dotctl', '.local/bin/updoot')}
    try:
        records = json.loads((ctx.root / 'catalog/components.json').read_text())
    except FileNotFoundError:
        records = []
    for record in records:
        for location in record.get('installed_locations', []):
            if location.startswith(('~/', '/')) and not any(character in location for character in '*?{}$'):
                links.add(os.path.expanduser(location))
    result = []
    mounts = mount_table()
    for name in sorted(links):
        link = absolute(name)
        try:
            if not check_path(link.parent, mounts, allow_missing=True) or not link.is_symlink():
                continue
            target = Path(os.readlink(link))
            target = absolute(target if target.is_absolute() else link.parent / target)
            if target == artifact or artifact in target.parents:
                result.append(str(link))
        except FileNotFoundError:
            continue
    return result


def candidate_eligibility(ctx, item):
    """Only terminal owned candidates, independently confirmed clean and unreferenced.

    Offline GitHub, unknown state, missing worktrees, protected generation references, and
    ignored files all hold cleanup. This function never removes a worktree or GC root.
    """
    path = absolute(item['path'])
    if not item.get('owned') or item.get('creator') != 'dotctl' or path.parent != absolute(ctx.state / 'candidates'):
        return False, 'Candidate ownership or location is not verified', None
    try:
        candidate = json.loads((path / 'candidate.json').read_text())
        identity = candidate['id']
        if identity != path.name or candidate.get('status') not in {'no-change', 'closed', 'superseded', 'applied'}:
            return False, 'Candidate is not terminal', None
        # The producer owns only its receipt, registered checkouts and declared
        # workspace. A clean Git checkout says nothing about a backup or notes
        # someone placed beside it; never sweep those into recursive cleanup.
        expected_children = {'candidate.json'}
        for key, name in (('checkout', 'repo'), ('activation_checkout', 'merged-repo'), ('work', 'work')):
            if candidate.get(key):
                if absolute(candidate[key]) != path / name:
                    return False, 'Candidate producer paths do not match the owned layout', None
                expected_children.add(name)
        unknown = sorted(child.name for child in path.iterdir() if child.name not in expected_children)
        if unknown:
            return False, 'Unclassified candidate siblings require explicit review: ' + ', '.join(unknown), None
        if (path / 'candidate.json').is_symlink() or (candidate.get('work') and (path / 'work').is_symlink()):
            return False, 'Candidate receipt or workspace was replaced with a symlink', None
        if item.get('active') or set(item.get('references', [])) - {identity} or referenced(ctx, path, exclude=identity):
            return False, 'Active or referenced candidate', None
        retention = max(30, ctx.policy.get('disposable_retention_days', 30)) * 86400
        timestamps = [candidate.get(key) for key in ('created_at', 'updated_at', 'applied_at', 'retired_at') if candidate.get(key)]
        if not timestamps or min(age(value) for value in timestamps) < retention or time.time() - item.get('latest_mtime', time.time()) < retention:
            return False, 'Candidate changed within the retention period', None
        if not item.get('complete') or set(item.get('flags', [])) - {'git-data', 'symlink'}:
            return False, 'Candidate scan is incomplete or contains a mount/special file', None
        all_candidates = []
        for filename in (ctx.state / 'candidates').glob('*/candidate.json'):
            data = json.loads(filename.read_text())
            if data.get('status') == 'applied':
                all_candidates.append(data)
        recent = sorted(all_candidates, key=lambda c: c.get('applied_at', c.get('updated_at', '')), reverse=True)[:2]
        if identity in {entry['id'] for entry in recent}:
            return False, 'One of the two most recently applied candidates', None
        protected = set()
        for reference in ('/run/current-system', '/run/booted-system'):
            if Path(reference).exists():
                protected.add(str(Path(reference).resolve()))
        for filename in ('last-application.json', 'last-system-application.json', 'pending-system-application.json', 'last-good.json', 'last-confirmed-good.json', 'active-editor.json', 'active-source.json'):
            receipt = ctx.load(filename, {})
            if receipt.get('candidate') == identity:
                return False, 'Last application or last confirmed good candidate', None
            if filename in {'active-editor.json', 'active-source.json', 'last-system-application.json', 'pending-system-application.json'} and str(path) in json.dumps(receipt, sort_keys=True):
                return False, 'Candidate provides the active editor or controller configuration', None
            protected.update(_store_paths(receipt))
        references = managed_symlink_references(ctx, path)
        if references:
            return False, 'Live managed configuration links reference this candidate: ' + ', '.join(references), None
        if _store_paths(candidate) & protected:
            return False, 'Candidate references a current, booted, rollback, or confirmed good generation', None
        pr_proof = None
        if candidate.get('pr'):
            repository = candidate.get('repository', '')
            if not re.fullmatch(r'[\w.-]+/[\w.-]+', repository):
                return False, 'Candidate repository identity is invalid', None
            result = run(['gh', 'pr', 'view', candidate['pr'], '--repo', repository,
                          '--json', 'state,headRefOid,mergeCommit'], timeout=20)
            pr_proof = json.loads(result.stdout)
            if pr_proof.get('state') not in {'MERGED', 'CLOSED'}:
                return False, 'Candidate has an open or unverified PR', None
            if candidate.get('head') and pr_proof.get('headRefOid') != candidate['head']:
                return False, 'PR head differs from the owned candidate', None
        env = {**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}
        worktrees = []
        for key in ('checkout', 'activation_checkout'):
            if not candidate.get(key):
                continue
            tree = absolute(candidate[key])
            if tree.parent != path or tree.is_symlink() or not tree.exists():
                return False, 'Candidate worktree path is missing or not directly owned', None
            command = ['git', '-C', tree]
            porcelain = run([*command, 'status', '--porcelain', '--untracked-files=all'], env=env, timeout=20).stdout
            ignored = run([*command, 'ls-files', '--others', '--ignored', '--exclude-standard'], env=env, timeout=20).stdout
            if porcelain.strip() or ignored.strip():
                return False, 'Candidate worktree has changes, untracked files, or ignored files', None
            expected = candidate.get('merged_revision') if key == 'activation_checkout' else candidate.get('head', candidate.get('base'))
            expected = expected or candidate.get('base')
            head = run([*command, 'rev-parse', 'HEAD'], env=env, timeout=20).stdout.strip()
            if not expected or head != expected:
                return False, 'Candidate worktree HEAD changed', None
            common = run([*command, 'rev-parse', '--path-format=absolute', '--git-common-dir'], env=env, timeout=20).stdout.strip()
            actual_common = run(['git', '-C', ctx.root, 'rev-parse', '--path-format=absolute', '--git-common-dir'], env=env, timeout=20).stdout.strip()
            if common != actual_common:
                return False, 'Candidate worktree belongs to a different repository', None
            listing = run(['git', '-C', ctx.root, 'worktree', 'list', '--porcelain'], env=env, timeout=20).stdout
            entries = [entry for entry in listing.split('\n\n') if entry.splitlines()[:1] == ['worktree ' + str(tree)]]
            if len(entries) != 1 or any(line.startswith(('locked', 'prunable')) for line in entries[0].splitlines()):
                return False, 'Worktree registration is missing, locked, or prunable', None
            worktrees.append({'path': str(tree), 'head': head})
        if not worktrees:
            return False, 'No owned Git worktree could be verified', None
        return True, 'Terminal candidate older than 30 days with closed/merged PR and clean owned worktrees', {
            'candidate': identity, 'status': candidate['status'], 'worktrees': worktrees, 'pr': pr_proof,
            'build_references': sorted(_store_paths(candidate))}
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as exc:
        return False, 'Candidate cleanup evidence unavailable: ' + str(exc), None


def eligibility(ctx, item):
    path = absolute(item['path'])
    if not item.get('owned'):
        return False, 'No verified producer ownership'
    if item.get('category') == 'candidate':
        allowed, reason, _ = candidate_eligibility(ctx, item)
        return allowed, reason
    if item.get('category') != 'scratch' or not item.get('disposable'):
        return False, 'Backups, archives, recovery data, candidates and unknown artifacts require explicit review'
    if path.parent != absolute(ctx.state / 'scratch'):
        return False, 'Outside the controller scratch directory'
    if item.get('references') or referenced(ctx, path):
        return False, 'An artifact or candidate references this path'
    if item.get('active', True):
        return False, 'Producer has not marked the artifact inactive'
    if not item.get('complete') or item.get('flags'):
        return False, 'Incomplete scan, nested mount, symlink, Git data, or special file'
    try:
        retention = max(30, ctx.policy.get('disposable_retention_days', 30)) * 86400
        if age(item['created_at']) < retention or time.time() - item.get('latest_mtime', time.time()) < retention:
            return False, 'Retention period has not elapsed since creation and last modification'
    except (ValueError, TypeError, KeyError):
        return False, 'Creation or modification evidence is invalid'
    return True, 'Owned inactive unreferenced disposable scratch, unchanged for at least 30 days'


def eligible(ctx, item):
    return eligibility(ctx, item)[0]


def scan(ctx):
    """Explicit scan writes an inventory. Default storage/inspect only read that snapshot."""
    ownership = ctx.load('artifact-ownership.json', {})
    items, errors, seen = [], [], set()
    try:
        mounts = mount_table()
    except (OSError, RuntimeError) as exc:
        return envelope('storage', observed_at=None, items=[], errors=[str(exc)], complete=False)
    for root in roots(ctx):
        try:
            if not check_path(root, mounts, allow_missing=True):
                continue
            # Listing an explicitly mounted registered root is allowed; walking into child mounts is not.
            children = sorted(root.iterdir())
        except (OSError, ValueError) as exc:
            errors.append(str(exc))
            continue
        for path in children:
            try:
                if any(m['path'] == path for m in mounts):
                    errors.append(f'Skipped nested mount: {path}')
                    continue
                info = identity(path)
                metadata = ownership.get(str(path), {})
                owned = bool(metadata) and all(info[k] == metadata.get('identity', {}).get(k) for k in ('device', 'inode'))
                entry = {'id': 'artifact:' + hashlib.sha256(str(path).encode()).hexdigest()[:16],
                         'path': str(path), 'identity': info, 'observed_at': now(),
                         'category': 'unclassified', 'purpose': 'Existing artifact; provenance needs review',
                         'protected': True, 'verification': 'unverified', 'owned': owned,
                         'mtime_is_last_used': False, **(metadata if owned else {}),
                         **measure(path, mounts=mounts, seen=seen)}
                # The original ownership identity is not a current observation.
                entry['identity'] = info
                allowed, reason = eligibility(ctx, entry)
                entry.update(protected=not allowed, protection_reason=reason)
                if allowed and entry.get('category') == 'candidate':
                    allowed, reason, proof = candidate_eligibility(ctx, entry)
                    entry.update(protected=not allowed, protection_reason=reason, cleanup_proof=proof)
                nested = [p for p in ownership if path in absolute(p).parents]
                entry['registered_children'] = nested
                if nested:
                    entry['protected'] = True
                    entry['protection_reason'] = 'Contains separately registered artifacts; outer total includes them'
                items.append(entry)
            except (OSError, ValueError) as exc:
                errors.append(f'{path}: {exc}')
    # A registered backup nested in a preexisting folder still needs its own discoverable
    # metadata. The enclosing artifact already accounts for these bytes in the total.
    known_paths = {item['path'] for item in items}
    for name, metadata in sorted(ownership.items()):
        path = absolute(name)
        parents = [item for item in items if absolute(item['path']) in path.parents]
        if name in known_paths or not parents:
            continue
        parent = max(parents, key=lambda item: len(Path(item['path']).parts))
        try:
            check_path(path, mounts)
            if any(m['path'] == path or m['path'] in path.parents and absolute(parent['path']) in m['path'].parents
                   for m in mounts):
                errors.append(f'Skipped nested mounted registration: {path}')
                continue
            info = identity(path)
            owned = all(info[key] == metadata.get('identity', {}).get(key) for key in ('device', 'inode'))
            entry = {'id': 'artifact:' + hashlib.sha256(str(path).encode()).hexdigest()[:16],
                     'path': str(path), 'category': 'unclassified', 'purpose': 'Artifact ownership needs review',
                     **(metadata if owned else {}), **measure(path, mounts=mounts),
                     'identity': info, 'owned': owned, 'observed_at': now(), 'mtime_is_last_used': False,
                     'accounted_bytes': 0, 'included_in': parent['id']}
            allowed, reason = eligibility(ctx, entry)
            entry.update(protected=not allowed, protection_reason=reason)
            if allowed and entry.get('category') == 'candidate':
                allowed, reason, proof = candidate_eligibility(ctx, entry)
                entry.update(protected=not allowed, protection_reason=reason, cleanup_proof=proof)
            items.append(entry)
        except (OSError, ValueError) as exc:
            errors.append(f'{path}: {exc}')
    result = envelope('storage', observed_at=now(), items=items, errors=errors, complete=not errors,
                      allocated_bytes=sum(i.get('accounted_bytes', i['allocated_bytes']) for i in items),
                      reclaimable_bytes=sum(i['allocated_bytes'] for i in items if not i['protected']),
                      note='Allocated bytes are not promised freed space. Hardlinks count once; Nix closure size is not exclusive storage. Modification time is not last use, and checksums are not restore tests.')
    ctx.save('artifacts.json', result)
    return result


def cached(ctx):
    result = ctx.load('artifacts.json', envelope('storage', observed_at=None, items=[], errors=[]))
    result['next_step'] = 'dotctl storage --refresh to inventory registered local roots'
    return result


def inspect(ctx, identifier):
    for item in cached(ctx)['items']:
        if item['id'] == identifier:
            return envelope('artifact', artifact=item)
    for filename in (ctx.state / 'retired-candidates').glob('*.json'):
        candidate = json.loads(filename.read_text())
        path = candidate.get('artifact_path', '')
        if 'artifact:' + hashlib.sha256(path.encode()).hexdigest()[:16] == identifier:
            return envelope('artifact', artifact={'id': identifier, 'path': path, 'category': 'candidate',
                            'lifecycle': 'cleaned', 'present': False, 'tombstone': candidate})
    raise ValueError(f'Unknown artifact: {identifier}; run dotctl storage --refresh')


def plan(ctx):
    inventory = scan(ctx)
    selected = [i for i in inventory['items'] if not i['protected'] and eligible(ctx, i)]
    result = envelope('cleanup-plan', created_at=now(),
                      items=[{'id': i['id'], 'path': i['path'], 'identity': i['identity'],
                              'tree_fingerprint': i['tree_fingerprint'], 'allocated_bytes': i['allocated_bytes'],
                              'category': i['category'], 'cleanup_proof': i.get('cleanup_proof')}
                             for i in selected],
                      protected_count=sum(i['protected'] for i in inventory['items']), errors=inventory.get('errors', []))
    ctx.save('cleanup-plan.json', result)
    return result


def cleanup(ctx):
    """Expire proven disposable scratch/resolved candidates with an exact durable receipt."""
    with ctx.lock('maintenance'), ctx.lock('artifacts'):
        proposal = plan(ctx)
        receipt = envelope('cleanup-receipt', started_at=now(), plan=proposal, removed=[], status='running')
        ctx.save('cleanup-last.json', receipt)
        try:
            for item in proposal['items']:
                path = absolute(item['path'])
                mounts = mount_table()
                check_path(path, mounts)
                if identity(path) != item['identity']:
                    raise RuntimeError(f'Artifact changed during cleanup: {path}')
                current = measure(path, mounts=mounts)
                accepted_flags = {'git-data', 'symlink'} if item.get('category') == 'candidate' else set()
                if not current['complete'] or set(current['flags']) - accepted_flags or current['tree_fingerprint'] != item['tree_fingerprint']:
                    raise RuntimeError(f'Artifact contents changed during cleanup: {path}')
                metadata = ctx.load('artifact-ownership.json', {}).get(str(path), {})
                if not eligible(ctx, {**metadata, **current, 'path': str(path), 'owned': True}):
                    raise RuntimeError(f'Artifact became protected during cleanup: {path}')
                if not shutil.rmtree.avoids_symlink_attacks:
                    raise RuntimeError('Safe recursive deletion is unavailable on this platform')
                if item.get('category') == 'candidate':
                    allowed, reason, proof = candidate_eligibility(ctx, {**metadata, **current, 'path': str(path), 'owned': True})
                    if not allowed or proof != item['cleanup_proof']:
                        raise RuntimeError('Candidate cleanup proof changed: ' + reason)
                    receipt.setdefault('worktrees_removed', [])
                    for tree in proof['worktrees']:
                        # Git owns worktree metadata. Never force removal or delete its .git entry ourselves.
                        run(['git', '-C', ctx.root, 'worktree', 'remove', tree['path']], timeout=30)
                        receipt['worktrees_removed'].append(tree['path'])
                        ctx.save('cleanup-last.json', receipt)
                    # Retain a searchable tombstone after releasing resolved build roots and scratch logs.
                    ctx.save('retired-candidates/' + proof['candidate'] + '.json', {
                        **json.loads((path / 'candidate.json').read_text()), 'cleaned_at': now(),
                        'cleanup_proof': proof, 'artifact_path': str(path)})
                shutil.rmtree(path)
                receipt['removed'].append(str(path))
                ctx.save('cleanup-last.json', receipt)
            receipt.update(status='complete', completed_at=now())
        except Exception as exc:
            receipt.update(status='failed', error=str(exc), completed_at=now())
            ctx.save('cleanup-last.json', receipt)
            raise
        ctx.save('cleanup-last.json', receipt)
        return receipt
