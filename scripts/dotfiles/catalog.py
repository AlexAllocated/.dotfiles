"""Searchable intent and source ownership, separate from observed runtime facts.

This is an index of native configuration, not another configuration language.
The reviewed surface list is deliberately checked in: discovery never silently
approves a newly added startup hook, wrapper, patch, or executable.
"""
from __future__ import annotations

import json
import platform
import re
import subprocess
from pathlib import Path

from core import envelope, read, run

CLASSIFICATIONS = {'supported', 'experimental', 'legacy', 'retired', 'unreviewed'}
CAPABILITIES = {'foundation', 'recovery', 'development', 'editor', 'desktop', 'gaming', 'remote-streaming', 'audio'}
CUSTOMIZATION = re.compile(r'overrideAttrs|\boverride\s*\{|(?:postPatch|prePatch)\s*=|substituteInPlace|fetchpatch|\b(?:rev|tag)\s*=|\bversion\s*=\s*"|\burl\s*=\s*"github:')
PATCH_STATES = {'required', 'upstream candidate found', 'removal testing needed', 'removal validated', 'unknown'}
IGNORED = {'node_modules', 'target', '__pycache__', '.git', '.ruff_cache'}
SOURCE_ROOTS = ('scripts', 'bin', 'modules', 'packages', 'hosts', 'lib', 'patches', 'pins',
                'platforms', 'bootstrap', 'docker', 'nvim', 'neovide', 'wezterm', 'komorebi',
                'noctalia', 'razer', 'tmux', 'wayland')
TOP_SOURCES = ('flake.nix', 'flake.lock', 'dot-bootstrap', '.zshrc', '.zprofile', '.gitconfig',
               '.p10k.zsh', '.wezterm.lua', 'wezterm-shell-integration.sh', '.tool-versions')
# These are entrypoints or explicit custom dependency declarations. A changed
# revision is reviewed even if its enclosing package module already has an owner.
NIX_ANCHORS = re.compile(
    r'(?:systemd\.(?:user\.)?(?:services|timers|paths|targets)\.|launchd\.agents\.|'
    r'(?:xdg\.)?desktopEntries\.|(?:shellAliases|sessionVariables|activation)\.|'
    r'write(?:Shell(?:Application|ScriptBin|Script)|ScriptBin|Python\d*(?:Bin)?)\b|makeWrapper\b|wrapProgram\b|makeDesktopItem\b|fetchpatch\b|'
    r'\bname\s*=\s*"|'
    r'\b(?:postPatch|prePatch)\s*=|substituteInPlace|\boverrideAttrs\b|'
    r'\boverride\s*\{|\b(?:rev|tag)\s*=|\bversion\s*=\s*"|'
    r'\b[\w-]*\.?url\s*=\s*"(?:github:|https?://))')
BLOCKS = re.compile(r'(?P<name>(?:[\w-]+\.)*(?:shellAliases|desktopEntries|services|timers|paths|agents))\s*=\s*(?:lib\.mkIf\s+[^\n{]+\s+)?\{')


def _block_members(text):
    """Find immediate attribute names in known Nix declaration blocks.

    This is a conservative coverage scanner, not a Nix evaluator. It supports
    strings/comments and balanced braces; actual package facts come from Nix.
    A nested service or alias is thus detected even when the block's opening
    line and its containing source path stay unchanged.
    """
    for match in BLOCKS.finditer(text):
        tail = text[match.end():]
        depth, quote, i, line_start = 1, None, 0, True
        while i < len(tail) and depth:
            if quote:
                if quote == '"' and tail[i] == '\\':
                    i += 2
                    continue
                if tail.startswith(quote, i):
                    i += len(quote)
                    quote = None
                    continue
                i += 1
                continue
            if tail.startswith('/*', i):
                end = tail.find('*/', i + 2)
                i = len(tail) if end < 0 else end + 2
                continue
            if tail[i] == '#':
                end = tail.find('\n', i)
                i = len(tail) if end < 0 else end
                continue
            if line_start and depth == 1:
                member = re.match(r'\s*("[^"\n]+"|[\w-]+)(?:\.[\w-]+)*\s*=', tail[i:])
                if member:
                    yield match.group('name') + '.' + member.group(1).strip('"')
                line_start = False
            if tail.startswith("''", i):
                quote, i = "''", i + 2
                continue
            if tail[i] == '"':
                quote = '"'
            elif tail[i] == '{':
                depth += 1
            elif tail[i] == '}':
                depth -= 1
            elif tail[i] == '\n' or (tail[i] == ';' and depth == 1):
                line_start = True
            i += 1


def normalize_anchor(anchor):
    """Keep the declaration slot and upstream identity, not duplicate pin values.

    Native manifests own versions. Routine updates must not need a second
    hand-edited copy of each revision in the catalog; evidence fingerprints
    invalidate earlier verification when those source bytes change.
    """
    anchor = re.sub(r'(\b(?:version|rev|tag|hash|sha256)\s*=\s*)"[^"\n]*"',
                    r'\1"<native value>"', anchor)
    anchor = re.sub(r'github:([^/"?]+/[^/"?]+)(?:/[^"?]*)?(?:\?[^"\n]*)?',
                    r'github:\1/<native ref>', anchor)
    anchor = re.sub(r'(https://github\.com/[^/" ]+/[^/" ]+/commit/)[0-9a-fA-F]{7,40}',
                    r'\1<native revision>', anchor)
    anchor = re.sub(r'(https://github\.com/[^/" ]+/[^/" ]+/compare/)[^" ]+(\.diff)',
                    r'\1<native comparison>\2', anchor)
    return anchor


def discovered(root):
    """Return source files and stable reviewed operational declaration anchors."""
    root = Path(root)
    paths = [root / name for name in TOP_SOURCES if (root / name).is_file()]
    for directory in SOURCE_ROOTS:
        base = root / directory
        if not base.is_dir() or base.is_symlink():
            continue
        paths.extend(path for path in base.rglob('*')
                     if path.is_file() and not path.is_symlink()
                     and not (set(path.relative_to(root).parts) & IGNORED))
    found = {}
    def declaration(rel, anchor, kind='declaration'):
        anchor = normalize_anchor(anchor)
        key = rel + '::' + anchor
        occurrence = 2
        while key in found:
            key = rel + '::' + anchor + '::occurrence-' + str(occurrence)
            occurrence += 1
        found[key] = {'source': rel, 'type': kind, 'anchor': anchor}
    for path in sorted(set(paths)):
        rel = path.relative_to(root).as_posix()
        # Internal files are owned by their component; they are not all shown
        # as individual tools. This also catches an added executable of any type.
        found[rel] = {'source': rel, 'type': 'source'}
        if path.suffix == '.nix':
            text = path.read_text()
            for line in text.splitlines():
                anchor = line.strip()
                if not anchor.startswith('#') and NIX_ANCHORS.search(line):
                    declaration(rel, anchor)
            for member in _block_members(text):
                found[rel + '::attribute:' + member] = {'source': rel, 'type': 'entrypoint', 'anchor': member}
        elif path.name in {'.zshrc', '.zprofile', '.gitconfig'} or path.suffix in {'.sh', '.ps1'}:
            for line in path.read_text(errors='replace').splitlines():
                anchor = line.strip()
                if re.search(r'^alias\s|Register-ScheduledTask\b|\$TaskName\s*=|launchctl\s+(?:bootstrap|load)', anchor) and not anchor.startswith('#'):
                    found[rel + '::' + anchor] = {'source': rel, 'type': 'entrypoint', 'anchor': anchor}
    return found


def records(ctx):
    return read(ctx.root / 'catalog/components.json', [])


def source_owner(source, items):
    """Most-specific declared owner, so a library directory can contain tools."""
    matches = []
    for item in items:
        if item.get('classification') == 'retired':
            continue
        for owned in item.get('owns', item.get('sources', [])):
            if source == owned or source.startswith(owned.rstrip('/') + '/'):
                matches.append((len(Path(owned).parts), item['id']))
    if not matches:
        return None
    specificity = max(depth for depth, _ in matches)
    owners = {owner for depth, owner in matches if depth == specificity}
    return next(iter(owners)) if len(owners) == 1 else sorted(owners)


def _safe_source(root, source):
    if not isinstance(source, str) or not source:
        return False
    path = Path(source)
    if path.is_absolute() or '..' in path.parts or not (root / path).exists():
        return False
    try:
        (root / path).resolve().relative_to(root.resolve())
    except (ValueError, OSError):
        return False
    return True


def validate(ctx):
    items = records(ctx)
    errors, ids = [], set()
    required = {'id', 'name', 'aliases', 'purpose', 'capability', 'platforms', 'classification',
                'sources', 'owns', 'commands', 'startup', 'effects', 'state_locations',
                'installed_locations', 'disable', 'verification', 'relationships', 'runtime', 'desired'}
    for item in items:
        identity = item.get('id', '?')
        for field in sorted(required - item.keys()):
            errors.append(f'{identity}: missing {field}')
        if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', identity):
            errors.append(f'{identity}: invalid stable ID')
        if identity in ids:
            errors.append(f'duplicate ID: {identity}')
        ids.add(identity)
        if item.get('classification') not in CLASSIFICATIONS:
            errors.append(f'{identity}: invalid classification')
        if item.get('capability') not in CAPABILITIES:
            errors.append(f'{identity}: invalid capability')
        for field in ('name', 'purpose', 'disable'):
            if not isinstance(item.get(field), str) or not item.get(field, '').strip():
                errors.append(f'{identity}: empty {field}')
        for field in ('aliases', 'platforms', 'sources', 'owns', 'commands', 'startup', 'effects',
                      'state_locations', 'installed_locations', 'relationships'):
            if not isinstance(item.get(field), list):
                errors.append(f'{identity}: {field} must be an array')
        if not item.get('platforms'):
            errors.append(f'{identity}: platforms must not be empty')
        for source in set(item.get('sources', []) + item.get('owns', [])):
            if not _safe_source(ctx.root, source) and item.get('classification') != 'retired':
                errors.append(f'{identity}: missing/unsafe source {source}')
        verification = item.get('verification', {})
        if not isinstance(verification, dict) or not verification.get('procedure') or 'last_verified' not in verification or not verification.get('evidence'):
            errors.append(f'{identity}: verification needs procedure, evidence and last_verified (null when unverified)')
        desired = item.get('desired', {})
        if not isinstance(desired, dict) or not desired.get('state') or not desired.get('evidence'):
            errors.append(f'{identity}: desired state needs a state and evidence separate from runtime')
        runtime = item.get('runtime', {})
        if runtime.get('mode') not in {'manual', 'service', 'services', 'scheduled-task', 'configuration', 'unknown'}:
            errors.append(f'{identity}: invalid runtime mode')
    for item in items:
        for target in item.get('relationships', []):
            if target not in ids:
                errors.append(f'{item["id"]}: dangling relationship {target}')
    current = discovered(ctx.root)
    approved = read(ctx.root / 'catalog/surfaces.json', {})
    for key in current.keys() - approved.keys():
        errors.append(f'uncataloged operational surface: {key}')
    for key in approved.keys() - current.keys():
        errors.append(f'removed surface needs catalog review: {key}')
    for key, surface in current.items():
        owner = source_owner(surface['source'], items)
        if owner is None:
            errors.append(f'unowned source: {key}')
        elif isinstance(owner, list):
            errors.append(f'ambiguous source ownership: {key}: {", ".join(owner)}')
        if key in approved and approved[key] != {**surface, 'owner': owner}:
            errors.append(f'surface ownership/metadata changed; review catalog: {key}')
    patches = read(ctx.root / 'catalog/patches.json', [])
    patch_ids, covered_customizations = set(), set()
    for patch in patches:
        identity = patch.get('id', '?')
        if identity in patch_ids or identity in ids:
            errors.append(f'duplicate patch ID: {identity}')
        patch_ids.add(identity)
        covered_customizations.update(patch.get('review_surfaces', []))
        for key in patch.get('review_surfaces', []):
            if key not in current:
                errors.append(f'{identity}: removed customization needs review: {key}')
        for field in ('owner', 'kind', 'source', 'source_paths', 'reason', 'upstream', 'removal', 'review_state', 'enabled'):
            if field not in patch:
                errors.append(f'{identity}: missing patch {field}')
        if patch.get('owner') not in ids:
            errors.append(f'invalid patch ownership: {identity}')
        for source in set(patch.get('source_paths', []) + [patch.get('source', '')]):
            if not _safe_source(ctx.root, source):
                errors.append(f'invalid patch source: {identity}: {source}')
        if patch.get('review_state') not in PATCH_STATES:
            errors.append(f'{identity}: invalid patch review state')
        if not patch.get('reason') or not patch.get('upstream', {}).get('url') or not patch.get('upstream', {}).get('tracking'):
            errors.append(f'{identity}: patch needs reason and upstream tracking source')
        if not all(key in patch.get('removal', {}) for key in ('target', 'regression', 'requires_live')):
            errors.append(f'{identity}: patch needs removal target, regression and live-verification requirement')
    for item in items:
        for key, reason in item.get('internal_declarations', {}).items():
            covered_customizations.add(key)
            if key not in current or not reason:
                errors.append(f'{item["id"]}: invalid internal declaration exception: {key}')
    for key, surface in current.items():
        if surface['type'] == 'declaration' and CUSTOMIZATION.search(surface.get('anchor', '')) and key not in covered_customizations:
            errors.append(f'customization missing lifecycle record: {key}')
    registered = {source for p in patches for source in p.get('source_paths', [])}
    for path in (ctx.root / 'patches').glob('*.patch'):
        if path.relative_to(ctx.root).as_posix() not in registered:
            errors.append(f'unregistered patch: {path.name}')
    for path in (ctx.root / 'pins').glob('*.json'):
        if path.relative_to(ctx.root).as_posix() not in registered:
            errors.append(f'unregistered pin: {path.name}')
    return envelope('catalog-validation', ok=not errors, errors=sorted(set(errors)), components=len(items), surfaces=len(current), patches=len(patches))


def native_manifests(ctx):
    tools, brew_ids = [], set()
    for filename in ('platforms/macos-managed/Brewfile', 'platforms/macos/Brewfile', 'platforms/macos-personal/Brewfile'):
        path = ctx.root / filename
        if not path.exists():
            continue
        platforms = ['darwin'] if '/macos-personal/' in filename else (['macos-managed', 'darwin'] if '/macos/' in filename else ['macos-managed'])
        for kind, name in re.findall(r'^(brew|cask)\s+"([^"]+)"', path.read_text(), re.M):
            identity = f'brew:{kind}:{name}'
            if identity in brew_ids:
                existing = next(tool for tool in tools if tool['id'] == identity)
                existing['sources'].append(filename)
                existing['platforms'] = sorted(set(existing['platforms']) | set(platforms))
                continue
            brew_ids.add(identity)
            tools.append({'id': identity, 'name': name, 'manager': 'homebrew', 'source': filename,
                          'sources': [filename], 'platform': platforms[0], 'platforms': platforms, 'version': None,
                          'version_evidence': 'Declared in Brewfile; resolve installed and available versions on the Mac.',
                          'classification': 'legacy' if platforms == ['darwin'] else 'supported'})
    winget = read(ctx.root / 'platforms/windows/winget.json', {})
    for source in winget.get('Sources', []):
        for package in source.get('Packages', []):
            name = package['PackageIdentifier']
            tools.append({'id': 'winget:' + name, 'name': name, 'manager': 'winget',
                          'source': 'platforms/windows/winget.json', 'platform': 'windows', 'classification': 'legacy'})
    nix = ctx.load('inventory-nix.json', {})
    for item in nix.get('packages', []):
        tools.append({**item, 'manager': 'nix', 'observed_at': nix.get('observed_at')})
    return tools


def search(ctx, query='', scope=None):
    items = records(ctx)
    if scope == 'managed':
        items = native_manifests(ctx)
    elif scope == 'background':
        items = [i for i in items if i.get('runtime', {}).get('mode') in {'service', 'services', 'scheduled-task'}]
    elif scope == 'legacy':
        legacy = set(ctx.policy.get('machines', {}).get('legacy', {}).get('platforms', ['windows', 'wsl', 'darwin', 'linux-generic']))
        items = [i for i in items if i['classification'] in {'legacy', 'retired'} or set(i.get('platforms', [])) <= legacy]
    elif scope == 'storage':
        return envelope('catalog', items=[i for i in ctx.load('artifacts.json', {}).get('items', []) if query.casefold() in json.dumps(i).casefold()])
    query = query.casefold()
    return envelope('catalog', items=[i for i in items if query in json.dumps(i).casefold()])


def _platforms():
    if platform.system() == 'Darwin':
        return {'macos-managed', 'darwin'}
    if platform.system() == 'Windows':
        return {'windows'}
    if platform.system() == 'Linux':
        return {'linux', 'nixos' if Path('/etc/NIXOS').exists() else 'linux-generic',
                *({'wsl'} if 'microsoft' in platform.release().lower() else set())}
    return set()


def _service(spec):
    argv = ['systemctl'] + (['--user'] if spec.get('scope') == 'user' else [])
    try:
        result = run([*argv, 'show', spec['unit'], '--property=LoadState,ActiveState,SubState,UnitFileState'], timeout=5, check=False)
        data = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if result.returncode or data.get('LoadState') in {None, 'not-found', 'error'}:
            return {'state': 'unknown', 'evidence': data, 'error': result.stderr.strip() or 'Unit not installed or unavailable'}
        return {'state': data.get('ActiveState', 'unknown'), 'evidence': data, 'error': result.stderr.strip() or None}
    except (OSError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as exc:
        return {'state': 'unknown', 'error': str(exc)}


def runtime(item):
    spec = item.get('runtime', {})
    platforms = spec.get('platforms', item.get('platforms', []))
    if platforms and not set(platforms) & _platforms():
        return {'state': 'not-applicable', 'evidence': 'This component targets ' + ', '.join(platforms) + '; remote runtime has not been observed.'}
    if spec.get('mode') == 'manual':
        return {'state': 'on-demand', 'evidence': 'No persistent process expected; this does not prove the tool is installed.'}
    if spec.get('mode') in {'service', 'services'} and Path('/run/systemd/system').exists():
        if spec['mode'] == 'service':
            return _service(spec)
        units = {unit['unit']: _service(unit) for unit in spec.get('units', [])}
        return {'state': 'observed', 'units': units, 'evidence': 'Individual unit states; classification does not imply runtime health.'}
    if spec.get('mode') == 'scheduled-task' and platform.system() == 'Windows':
        # Explicit read-only API. Never run a helper whose default mode installs
        # or pulses activity just to determine whether its task exists.
        name = spec.get('task', '')
        if not re.fullmatch(r'[A-Za-z0-9 _.-]+', name):
            return {'state': 'unknown', 'error': 'Invalid scheduled task name'}
        command = "$t = Get-ScheduledTask -TaskName '" + name + "' -ErrorAction Stop; $t | Select-Object TaskName,State | ConvertTo-Json -Compress"
        try:
            result = run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command], timeout=5, check=False)
            if result.returncode:
                return {'state': 'unknown', 'error': result.stderr.strip()}
            data = json.loads(result.stdout)
            return {'state': str(data.get('State', 'unknown')), 'evidence': data}
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            return {'state': 'unknown', 'error': str(exc)}
    if spec.get('mode') == 'configuration':
        return {'state': 'configured', 'evidence': 'Source declaration exists; live application is not established by this inspection.'}
    return {'state': 'unknown', 'evidence': spec.get('reason', 'No verified runtime provider on this machine')}


def inspect(ctx, identity):
    items = records(ctx)
    for item in items:
        if item['id'] == identity or identity in item.get('aliases', []):
            patches = [p for p in read(ctx.root / 'catalog/patches.json', []) if p['owner'] == item['id']]
            artifacts = [a for a in ctx.load('artifacts.json', {}).get('items', [])
                         if item['id'] in (a.get('components', []) + [a.get('creator')])]
            return envelope('component', component=item, runtime=runtime(item), patches=patches,
                            related=[{'id': other['id'], 'name': other['name']} for other in items if other['id'] in item['relationships']], artifacts=artifacts)
    for item in native_manifests(ctx):
        if item.get('id') == identity:
            return envelope('managed-tool', tool=item, runtime={'state': 'unknown', 'evidence': 'Native manifest declaration or cached package evaluation; process state is not inferred.'})
    for item in ctx.load('artifacts.json', {}).get('items', []):
        if item['id'] == identity:
            return envelope('artifact', artifact=item)
    for patch in read(ctx.root / 'catalog/patches.json', []):
        if patch['id'] == identity:
            return envelope('patch', patch=patch)
    # Storage retains tombstones for cleaned candidate artifacts. Import lazily
    # because its producer/cleanup paths also use catalog metadata.
    from storage import inspect as inspect_artifact
    try:
        return inspect_artifact(ctx, identity)
    except ValueError:
        raise ValueError(f'Unknown component or artifact: {identity}; use dotctl catalog <words> or dotctl storage') from None


def machine_map(ctx):
    items = records(ctx)
    patches = read(ctx.root / 'catalog/patches.json', [])
    machines = []
    for name, spec in ctx.policy['machines'].items():
        groups = {}
        for item in items:
            if set(item['platforms']) & set(spec['platforms']) and (not item.get('hosts') or name in item['hosts']):
                groups.setdefault(item['capability'], []).append({key: item[key] for key in
                    ('id', 'name', 'purpose', 'classification', 'desired', 'sources', 'commands', 'startup', 'relationships', 'state_locations')})
                groups[item['capability']][-1]['patches'] = [p['id'] for p in patches if p['owner'] == item['id']]
        machines.append({'machine': name, **spec, 'capabilities': groups})
    return envelope('map', machines=machines)
