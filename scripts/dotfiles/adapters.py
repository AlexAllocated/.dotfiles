"""Native, bounded maintenance operations, independent of Git/PR orchestration.

Preparing changes never installs host packages or touches the live editor. All
network discovery belongs to prepare; apply uses reviewed pins and preflight
identities. Homebrew remains a reviewed transaction, not a fictitious lockfile.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
from urllib.parse import unquote

from core import atomic, digest, envelope, nix_source, now, read, run

GROUPS = ('system', 'os-release', 'drivers', 'desktop', 'editor', 'mac')
SYSTEM_INPUTS = ('nixpkgs', 'nixpkgs-unstable', 'home-manager', 'nix-darwin', 'lanzaboote')
RELEASE_INPUTS = ('nixpkgs', 'home-manager', 'nix-darwin')
DESKTOP_INPUTS = ('mango', 'noctalia', 'iloader')
BREWFILES = ('platforms/macos-managed/Brewfile', 'platforms/macos/Brewfile')
MAC_MANIFEST = 'platforms/macos-managed/review.json'


class AdapterHold(RuntimeError):
    """An actionable policy/platform hold, not a successful preparation."""


def _require(command):
    if not shutil.which(command):
        raise AdapterHold(f'{command} is required on this host; no maintenance was applied')


def _paths(candidate, work):
    candidate, work = Path(candidate).resolve(), Path(work).resolve()
    if not (candidate / 'flake.nix').is_file():
        raise ValueError('Adapter candidate must be an explicit dotfiles checkout')
    if work == candidate or work.is_relative_to(candidate):
        raise ValueError('Adapter runtime must be outside the candidate source tree')
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    return candidate, work


def _shell(action, candidate, work, timeout=3600, profile=None):
    command = ['bash', candidate / 'scripts/maintenance-adapter.sh', action, candidate, work]
    if profile:
        command.append(profile)
    return run(command,
               cwd=candidate, timeout=timeout)


def editor_locks(profile=None):
    suffix = '.macos-managed' if profile == 'macos-managed' else ''
    return ('nvim/lazy-lock' + suffix + '.json', 'nvim/mason-lock' + suffix + '.json')


def editor_profiles(profile=None):
    return ('macos-managed',) if profile == 'macos-managed' else ('tracer', 'macos-managed')


def _release_module(candidate):
    spec = importlib.util.spec_from_file_location('dotfiles_release_adapter', candidate / 'scripts/updates/releases.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _nix_update(candidate, inputs):
    _require('nix')
    # Explicit roots preserve recovery/AFX pins and isolate desktop inputs.
    run(['nix', 'flake', 'update', *inputs, '--flake', nix_source(candidate)], timeout=1800)


def _source_digest(candidate):
    """Check identity also works before the candidate commit is created."""
    files = run(['git', '-C', candidate, 'ls-files', '-co', '--exclude-standard', '-z']).stdout.split('\0')
    hasher = hashlib.sha256()
    for relative in sorted(set(files) - {''}):
        path = candidate / relative
        hasher.update(relative.encode() + b'\0')
        if path.is_symlink():
            hasher.update(b'link\0' + os.readlink(path).encode())
        elif path.is_file():
            # Git/Nix preserve executability, not checkout-local read/write modes.
            hasher.update(b'100755\0' if path.stat().st_mode & 0o100 else b'100644\0')
            hasher.update(digest(path).encode())
        elif not path.exists():
            hasher.update(b'deleted')
    return hasher.hexdigest()


def prepare(ctx, group, candidate, work, profile=None):
    candidate, work = _paths(candidate, work)
    evidence = envelope('adapter-preparation', group=group, started_at=now(), stages=[])
    if group == 'drivers':
        raise AdapterHold('The NVIDIA mkDriver pin has a game-specific branch constraint. Prepare a separate '
                          'driver recipe/hash change and pass --from <committed-revision>; upstream release '
                          'discovery alone cannot validate Galactic Racer, displays, or loaded kernel modules.')
    if group == 'editor':
        _require('nvim')
        evidence['locks'] = {}
        for variant in editor_profiles(profile):
            _shell('editor-prepare', candidate, work / ('editor-' + variant), profile=variant)
            evidence['locks'].update({p: digest(candidate / p) for p in editor_locks(variant)})
        evidence['runtime_isolated'] = True
    elif group in ('system', 'os-release', 'desktop'):
        _require('nix')
        release = _release_module(candidate)
        source = (candidate / 'flake.nix').read_text()
        if group == 'os-release':
            releases = release.refs('NixOS/nixpkgs', '--tags', '[0-9][0-9].[0-9][0-9]')
            stable = max((r for r in releases if re.fullmatch(r'\d{2}\.\d{2}', r)), key=release.version)
            for repo, prefix in (('NixOS/nixpkgs', 'nixos-'), ('nix-community/home-manager', 'release-'),
                                 ('nix-darwin/nix-darwin', 'nix-darwin-')):
                ref = prefix + stable
                if release.refs(repo, '--heads', ref) != [ref]:
                    raise AdapterHold(f'OS release {stable} has no matching {repo}/{ref}')
                source = release.replace_ref(source, repo, ref)
            (candidate / 'flake.nix').write_text(source)
            _nix_update(candidate, RELEASE_INPUTS)
        elif group == 'desktop':
            for repo in release.RELEASE_REPOS:
                metadata = json.loads(release.fetch(f'https://api.github.com/repos/{repo}/releases/latest'))
                tag = metadata['tag_name']
                if metadata['draft'] or metadata['prerelease'] or not release.version(tag)[1]:
                    raise AdapterHold(f'{repo} did not provide a stable published release')
                source = release.replace_ref(source, repo, tag)
            pin = release.update_desktop(read(candidate / 'pins/chatgpt-desktop.json'))
            (candidate / 'flake.nix').write_text(source)
            atomic(candidate / 'pins/chatgpt-desktop.json', pin)
            _nix_update(candidate, DESKTOP_INPUTS)
            release.update_iloader_cargo(candidate)
        else:
            _shell('codex-pin', candidate, work)
            _nix_update(candidate, SYSTEM_INPUTS)
    elif group == 'mac':
        manifest = resolve_mac(candidate, refresh=True)
        atomic(candidate / MAC_MANIFEST, manifest)
        evidence['manifest'] = MAC_MANIFEST
        evidence['packages'] = len(manifest['packages'])
    else:
        raise ValueError(f'Unknown maintenance group: {group}')
    evidence.update(completed_at=now(), status='prepared')
    atomic(work / 'adapter-prepare.json', evidence)
    return evidence


def check(ctx, group, candidate, work, profile=None):
    candidate, work = _paths(candidate, work)
    source_before = _source_digest(candidate)
    evidence = envelope('adapter-check', group=group, started_at=now(), stages=[])
    if group == 'editor':
        _require('nvim')
        before = {p: digest(candidate / p) for variant in editor_profiles(profile) for p in editor_locks(variant)}
        for index, variant in enumerate(editor_profiles(profile)):
            runtime = work / ('editor-check' if index == 0 else 'editor-check-' + variant)
            _shell('editor-check', candidate, runtime, profile=variant)
        after = {p: digest(candidate / p) for p in before}
        if before != after:
            raise RuntimeError('Restoring the editor changed reviewed locks; candidate must be prepared again')
        evidence.update(locks=after, runtime_isolated=True)
    elif group == 'mac':
        reviewed = read(candidate / MAC_MANIFEST)
        if not reviewed:
            raise AdapterHold('Managed Mac has no reviewed package manifest; run dotctl prepare mac')
        current = resolve_mac(candidate, refresh=True)
        compare_mac(reviewed, current)
        evidence['manifest_sha256'] = digest(candidate / MAC_MANIFEST)
        evidence['validation'] = 'Homebrew package versions and recipes re-resolved on this Mac; no packages installed'
    elif group in ('system', 'os-release', 'drivers', 'desktop'):
        _require('nix')
        untracked = run(['git', '-C', candidate, 'ls-files', '--others', '--exclude-standard']).stdout.splitlines()
        if untracked:
            raise AdapterHold('Nix validation refuses untracked source files: ' + ', '.join(untracked[:10]) +
                              '. Review and stage intended files in an owned candidate before checking; '
                              'the developer index was not changed.')
        if platform.system() != 'Linux' or not Path('/etc/NIXOS').exists():
            raise AdapterHold('Full NixOS host validation must run on the supported NixOS machine')
        profile = profile or 'tracer'
        if profile not in ('tracer', 'chev-desktop'):
            raise AdapterHold(f'{profile} is a legacy target; explicitly use its compatibility apply path')
        source = nix_source(candidate)
        run(['nix', 'flake', 'check', source], timeout=7200)
        evidence['stages'].append({'name': 'native-flake-check', 'status': 'passed', 'at': now()})
        run(['nix', 'flake', 'check', '--all-systems', '--no-build', source], timeout=1800)
        evidence['stages'].append({'name': 'cross-platform-evaluation', 'status': 'passed', 'at': now()})
        output = run(['nix', 'build', f'{source}#nixosConfigurations.{profile}.config.system.build.toplevel',
                      '--out-link', work / 'system', '--print-out-paths'], timeout=14400)
        paths = [line for line in output.stdout.splitlines() if line.startswith('/nix/store/')]
        if len(paths) != 1 or not (Path(paths[0]) / 'bin/switch-to-configuration').exists():
            raise RuntimeError('Nix did not return one complete, activatable system')
        evidence.update(build_path=paths[0], profile=profile,
                        hardware_validation='pending live verification' if group == 'drivers' else 'not performed')
        evidence['stages'].append({'name': 'full-host-build', 'status': 'passed', 'at': now()})
    else:
        raise ValueError(f'Unknown maintenance group: {group}')
    source_after = _source_digest(candidate)
    if source_after != source_before:
        raise RuntimeError('Candidate source changed while validation was running; discard these checks and retry')
    evidence.update(status='passed', completed_at=now(), source_digest=source_before)
    atomic(work / 'adapter-check.json', evidence)
    return evidence


def apply(ctx, group, candidate, work, profile=None):
    candidate, work = _paths(candidate, work)
    if group == 'mac':
        return apply_mac(candidate, work)
    if group != 'editor':
        raise AdapterHold('Nix activation must use the controller receipt and exact adapter-check build_path')
    path = work / 'adapter-apply.json'
    receipt = read(path, envelope('adapter-apply', group=group, started_at=now(), stages=[]))
    profile = profile or ('macos-managed' if platform.system() == 'Darwin' else 'tracer')
    source_before = _source_digest(candidate)
    locks = {p: digest(candidate / p) for p in editor_locks(profile)}
    if receipt.get('locks', locks) != locks:
        raise AdapterHold('Editor pins changed since the first apply attempt; prepare a new candidate')
    receipt['locks'] = locks
    if receipt.get('status') == 'applied':
        return receipt
    receipt['status'] = 'applying'
    atomic(path, receipt)
    try:
        _shell('editor-apply', candidate, work / 'editor-apply', profile=profile)
        if {p: digest(candidate / p) for p in locks} != locks:
            raise RuntimeError('Editor restore unexpectedly modified reviewed pins')
        if _source_digest(candidate) != source_before:
            raise RuntimeError('Editor source changed during runtime application; accepted config pointer remains unchanged')
        selected = ctx.load('active-editor.json', envelope('active-editor', profiles={}))
        selected['profiles']['macos-managed' if profile == 'macos-managed' else 'default'] = {
            'root': str(candidate), 'source_digest': source_before, 'selected_at': now(),
            'revision': run(['git', '-C', candidate, 'rev-parse', 'HEAD']).stdout.strip()}
        ctx.save('active-editor.json', selected)
        receipt['stages'].append({'name': 'editor-runtime', 'status': 'applied', 'at': now()})
        receipt['stages'].append({'name': 'accepted-editor-source', 'status': 'applied', 'root': str(candidate), 'at': now()})
        receipt.update(status='applied', completed_at=now())
    except Exception as exc:
        receipt.update(status='failed', error=str(exc), failed_at=now())
        atomic(path, receipt)
        raise
    atomic(path, receipt)
    return receipt


def _brew_env():
    return {**os.environ, 'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_INSTALL_CLEANUP': '1',
            'HOMEBREW_NO_ANALYTICS': '1', 'HOMEBREW_NO_ENV_HINTS': '1', 'HOMEBREW_NO_ASK': '1'}


def _brew(*args):
    return run(['brew', *args], env=_brew_env(), timeout=1800)


def _brew_recipe(kind, entry):
    if kind == 'formula':
        version = entry['versions']['stable']
        revision = entry.get('revision', 0)
        target = f'{version}_{revision}' if revision else version
        identity = {key: entry.get(key) for key in ('full_name', 'tap', 'versions', 'revision', 'version_scheme',
                    'urls', 'bottle', 'dependencies', 'build_dependencies', 'requirements',
                    'ruby_source_checksum', 'ruby_source_path')}
    else:
        target = entry['version']
        identity = {key: entry.get(key) for key in ('token', 'full_token', 'tap', 'version', 'url', 'sha256',
                    'depends_on', 'artifacts', 'ruby_source_checksum', 'ruby_source_path')}
    if not target or target == 'latest':
        raise AdapterHold(f'{kind} has no immutable target version; review its upstream installer manually')
    if not entry.get('ruby_source_checksum'):
        raise AdapterHold(f'{kind} {target} has no recipe checksum in brew info; update Homebrew metadata and retry')
    return target, hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def lan_mouse_pin(candidate):
    source = (Path(candidate) / 'scripts/profiles/macos-managed.sh').read_text()
    fields = {}
    for key in ('version', 'expected_build', 'expected_identifier'):
        match = re.search(r'local ' + key + r'="([^"\n]+)"', source)
        if not match:
            raise AdapterHold('Lan Mouse source pin is missing ' + key)
        fields[key] = match[1]
    return {**fields, 'source': 'scripts/profiles/macos-managed.sh',
            'recipe_sha256': digest(Path(candidate) / 'scripts/profiles/macos-managed.sh')}


def resolve_mac(candidate, refresh=False):
    if platform.system() != 'Darwin':
        raise AdapterHold('Managed Mac preparation and recipe validation must run on the work Mac')
    _require('brew')
    if refresh:
        _brew('update')  # Metadata only; no install/upgrade/cleanup or OS actions.
    packages = {}
    holds = {}
    sources = {}
    for relative in BREWFILES:
        brewfile = Path(candidate) / relative
        sources[relative] = digest(brewfile)
        for kind in ('formula', 'cask'):
            names = _brew('bundle', 'list', '--file', str(brewfile), f'--{kind}').stdout.splitlines()
            for name in names:
                name = name.strip()
                if not name:
                    continue
                key = kind + ':' + name
                if key in packages:
                    continue
                metadata = json.loads(_brew('info', '--json=v2', f'--{kind}', name).stdout)
                entries = metadata['formulae' if kind == 'formula' else 'casks']
                if len(entries) != 1:
                    raise AdapterHold(f'Expected one Homebrew recipe for {name}')
                if kind == 'cask' and name == 'wezterm@nightly' and entries[0].get('version') == 'latest':
                    holds[key] = {'name': name, 'kind': kind, 'status': 'manual-review',
                                  'reason': 'The declared nightly has no immutable version. Retain the installed app; review a specific artifact before updating.',
                                  'declared_target': 'latest', 'recipe_checksum': entries[0].get('ruby_source_checksum')}
                    continue
                target, identity = _brew_recipe(kind, entries[0])
                packages[key] = {'name': name, 'kind': kind, 'target': target, 'recipe_identity': identity}
    return envelope('mac-review', brewfiles=sources, packages=packages, manual_holds=holds,
                    native_components={'lan-mouse': lan_mouse_pin(candidate)},
                    ai_policy='Claude Code only on the managed company Mac; no Codex install or release discovery',
                    resolution_policy='Review manifest; Homebrew dependencies are resolved at apply, not locked')


def compare_mac(reviewed, current):
    for key in ('brewfiles', 'packages', 'manual_holds', 'native_components', 'ai_policy'):
        if reviewed.get(key) != current.get(key):
            raise AdapterHold(f'Managed Mac {key} changed since review; no packages were applied. Prepare and review a new candidate.')


def _installed_matches(item):
    data = json.loads(_brew('info', '--json=v2', '--' + item['kind'], item['name']).stdout)
    entry = data['formulae' if item['kind'] == 'formula' else 'casks'][0]
    installed = entry.get('installed') or []
    if item['kind'] == 'formula':
        return any(value.get('version') == item['target'] for value in installed)
    return item['target'] in (installed if isinstance(installed, list) else [installed])


def apply_mac(candidate, work):
    source_before = _source_digest(Path(candidate))
    reviewed = read(Path(candidate) / MAC_MANIFEST)
    if not reviewed:
        raise AdapterHold('No reviewed Mac transaction exists')
    # Complete preflight before first mutation. Every retry records and rechecks
    # current installed state; a partial success never claims transactional undo.
    compare_mac(reviewed, resolve_mac(candidate, refresh=True))
    path = Path(work) / 'adapter-apply.json'
    receipt = read(path, envelope('adapter-apply', group='mac', started_at=now(), stages=[]))
    identity = digest(Path(candidate) / MAC_MANIFEST)
    if receipt.get('manifest_sha256', identity) != identity:
        raise AdapterHold('Mac review manifest changed after apply began')
    receipt.update(manifest_sha256=identity, status='applying')
    atomic(path, receipt)
    try:
        for key, item in reviewed['packages'].items():
            if _installed_matches(item):
                receipt['stages'].append({'name': key, 'target': item['target'], 'status': 'already-installed', 'at': now()})
            else:
                installed = run(
                    ['brew', 'list', '--' + item['kind'], item['name']], env=_brew_env(), check=False)
                action = 'upgrade' if installed.returncode == 0 else 'install'
                _brew(action, '--' + item['kind'], item['name'])
                if not _installed_matches(item):
                    raise RuntimeError(f'{key} did not reach reviewed version {item["target"]}')
                receipt['stages'].append({'name': key, 'target': item['target'], 'status': 'applied', 'at': now()})
            atomic(path, receipt)
        for key, hold in reviewed.get('manual_holds', {}).items():
            receipt['stages'].append({'name': key, 'status': 'held', 'reason': hold['reason'], 'at': now()})
        if _source_digest(Path(candidate)) != source_before:
            raise RuntimeError('Mac source changed while applying packages; configuration links were not changed')
        _shell('mac-links', Path(candidate), Path(work) / 'mac-links')
        if _source_digest(Path(candidate)) != source_before:
            raise RuntimeError('Mac source changed during configuration application; inspect the partial receipt before retrying')
        receipt['stages'].append({'name': 'managed-config-links', 'status': 'applied', 'at': now()})
        receipt.update(status='applied-with-holds' if reviewed.get('manual_holds') else 'applied',
                       manual_holds=reviewed.get('manual_holds', {}), completed_at=now(), dependency_note='Homebrew may also change declared-package dependencies')
    except Exception as exc:
        receipt.update(status='partial-failure', error=str(exc), failed_at=now())
        atomic(path, receipt)
        raise
    atomic(path, receipt)
    return receipt


def _installed_editor_evidence(candidate, validation_data, live_data, profile=None):
    """Inspect persisted runtime identity without loading or repairing Neovim."""
    evidence = {'plugins': {}, 'mason': {}, 'parsers': {}, 'queries': []}
    plugin_lock, mason_lock = editor_locks(profile)
    reviewed = read(Path(candidate) / plugin_lock)
    manifest = read(validation_data / 'dotfiles-plugin-pins.json', {})
    if manifest.get('schema_version') != 1 or manifest.get('lock_sha256') != digest(Path(candidate) / plugin_lock):
        raise AdapterHold('Isolated editor check produced no matching active-plugin evidence')
    active = manifest.get('plugins', {})
    if set(active) | set(manifest.get('inactive', [])) != set(reviewed):
        raise AdapterHold('Isolated editor plugin evidence does not cover the reviewed lock')
    for name, expected in active.items():
        if reviewed[name]['commit'] != expected:
            raise AdapterHold(f'Isolated editor plugin {name} differs from the reviewed commit')
        directory = live_data / 'lazy' / name
        if not directory.is_dir():
            raise AdapterHold(f'Live editor plugin {name} is missing; apply the reviewed editor candidate')
        actual = run(['git', '-C', directory, 'rev-parse', 'HEAD']).stdout.strip()
        if actual != expected:
            raise AdapterHold(f'Live editor plugin {name} differs from its reviewed commit')
        evidence['plugins'][name] = actual
    evidence['inactive_plugins'] = manifest.get('inactive', [])
    pins = read(Path(candidate) / mason_lock)['packages']
    for name, expected in pins.items():
        receipt = read(live_data / 'mason/packages' / name / 'mason-receipt.json')
        if not receipt:
            raise AdapterHold(f'Live Mason tool {name} is missing')
        purl = receipt.get('source', {}).get('id', '')
        actual = unquote(purl.split('?', 1)[0].split('#', 1)[0].rsplit('@', 1)[-1])
        if actual != expected:
            raise AdapterHold(f'Live Mason tool {name} has {actual}, expected {expected}')
        evidence['mason'][name] = actual
    expected_parsers = sorted((validation_data / 'site/parser-info').glob('*.revision'))
    if not expected_parsers:
        raise AdapterHold('Isolated editor check produced no parser evidence')
    for receipt in expected_parsers:
        language = receipt.name.removesuffix('.revision')
        actual = live_data / 'site/parser-info' / receipt.name
        binary = live_data / 'site/parser' / (language + '.so')
        if not actual.is_file() or actual.read_text() != receipt.read_text() or not binary.is_file():
            raise AdapterHold(f'Live Tree-sitter parser {language} differs from the validated editor runtime')
        evidence['parsers'][language] = actual.read_text().strip()
    for expected in sorted((validation_data / 'site/queries').iterdir()):
        if not (live_data / 'site/queries' / expected.name).is_dir():
            raise AdapterHold(f'Live Tree-sitter queries for {expected.name} are missing or dangling')
        evidence['queries'].append(expected.name)
    return evidence


def acceptance(ctx, profile, work=None):
    """Native Mac acceptance is installed-state evidence, not recipe-only checks."""
    if profile != 'macos-managed' or platform.system() != 'Darwin':
        raise AdapterHold('This adapter acceptance must run on the managed work Mac')
    candidate, work = _paths(ctx.root, work or ctx.state / 'acceptance/work-mac')
    reviewed = read(candidate / MAC_MANIFEST)
    if not reviewed:
        raise AdapterHold('Apply a reviewed Mac transaction before recording acceptance')
    evidence = envelope('native-mac-acceptance', checked_at=now(), packages={}, links={},
                        limitations=['No interactive GUI or company-managed macOS upgrade is inferred from these checks'])
    for key, package in reviewed['packages'].items():
        if not _installed_matches(package):
            raise AdapterHold(f'{key} is not installed at the reviewed version {package["target"]}')
        evidence['packages'][key] = package['target']
    for key, hold in reviewed.get('manual_holds', {}).items():
        data = json.loads(_brew('info', '--json=v2', '--cask', hold['name']).stdout)
        if not data['casks'][0].get('installed'):
            raise AdapterHold(f'{key} is not installed; its immutable artifact needs manual review')
        evidence['packages'][key] = {'status': 'manual-review', 'installed': data['casks'][0]['installed'], 'reason': hold['reason']}
    pin = lan_mouse_pin(candidate)
    app = Path('/Applications/Lan Mouse.app')
    for key, field in (('version', 'CFBundleShortVersionString'), ('expected_build', 'CFBundleVersion'), ('expected_identifier', 'CFBundleIdentifier')):
        actual = run(['plutil', '-extract', field, 'raw', '-o', '-', app / 'Contents/Info.plist']).stdout.strip()
        if actual != pin[key]:
            raise AdapterHold(f'Installed Lan Mouse {field} differs from the reviewed pin')
    run(['codesign', '--verify', '--deep', '--strict', app])
    if run(['pgrep', '-x', 'lan-mouse'], check=False).returncode:
        raise AdapterHold('Lan Mouse is installed but its declared background process is not running')
    evidence['lan_mouse'] = {**pin, 'installed': True, 'running': True}
    links = {'.zprofile': '.zprofile', '.zshrc': '.zshrc', '.gitconfig': '.gitconfig',
             '.p10k.zsh': '.p10k.zsh', '.wezterm.lua': '.wezterm.lua', 'rustfmt.toml': 'rustfmt.toml',
             '.config/nvim': 'nvim', '.config/neovide/config.toml': 'neovide/config.toml',
             '.config/wezterm': 'wezterm', '.local/bin/dotctl': 'scripts/dotctl', '.local/bin/updoot': 'scripts/updoot'}
    for destination, source in links.items():
        installed_link = Path.home() / destination
        if not installed_link.is_symlink() or installed_link.resolve() != (candidate / source).resolve():
            raise AdapterHold(f'{destination} is not linked to the accepted configuration revision')
        evidence['links'][destination] = source
    evidence['editor_check'] = check(ctx, 'editor', candidate, work / 'editor', profile=profile)
    live_data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'nvim'
    validation_data = work / 'editor/editor-check/data/nvim'
    evidence['editor_runtime'] = _installed_editor_evidence(candidate, validation_data, live_data, profile=profile)
    evidence['status'] = 'accepted'
    atomic(work / 'native-acceptance.json', evidence)
    return evidence
