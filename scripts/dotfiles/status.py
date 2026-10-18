"""Explicit refreshes collect evidence; ordinary status only reads local files."""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import urllib.parse
import urllib.request

from core import age, digest, envelope, nix_source, now, read, run
from catalog import applies_here, is_background, records, runtime


def stale(timestamp, hours=48):
    try:
        return not timestamp or age(timestamp) > hours * 3600 or age(timestamp) < -300
    except (TypeError, ValueError):
        return True


def fetch(url):
    request = urllib.request.Request(url, headers={
        'User-Agent': 'dotfiles-status/1', 'Accept': 'application/json'})
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read(4 * 1024 * 1024 + 1)
        if len(body) > 4 * 1024 * 1024:
            raise ValueError('Metadata exceeded the 4 MiB response limit')
        return body.decode()


def release(repo):
    result = json.loads(fetch(f'https://api.github.com/repos/{repo}/releases/latest'))
    if result.get('draft') or result.get('prerelease'):
        raise ValueError('Release feed did not return a stable release')
    return {'version': result['tag_name'], 'url': result['html_url']}


def nixos_release():
    result = run(['git', 'ls-remote', '--tags', '--refs',
                  'https://github.com/NixOS/nixpkgs.git', '[0-9][0-9].[0-9][0-9]'], timeout=45)
    versions = re.findall(r'refs/tags/(\d{2}\.\d{2})$', result.stdout, re.M)
    if not versions:
        raise ValueError('The NixOS release feed returned no stable release tags')
    return {'version': max(versions, key=lambda x: tuple(map(int, x.split('.')))),
            'url': 'https://nixos.org/download/'}


def nvidia():
    # The official Unix page loads these exact production/new-feature queries dynamically.
    # Consume its public JSON endpoint, and verify returned branch flags and Linux platform.
    base = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?'
    channels, sources = {}, {}
    for channel, qnf in (('production', '0'), ('new-feature', '1')):
        query = dict(func='DriverManualLookup', psid='133', pfid='1075', osID='12',
                     languageCode='1033', beta='0' if qnf == '0' else 'null', isWHQL='0',
                     dltype='-1', dch='0', upCRD='null', qnf=qnf, ctk='null',
                     sort1='' if qnf == '0' else '1', numberOfResults='1')
        url = base + urllib.parse.urlencode(query)
        data = json.loads(fetch(url))
        rows = data.get('IDS', [])
        if str(data.get('Success')) != '1' or len(rows) != 1:
            raise ValueError('NVIDIA branch lookup returned an ambiguous result')
        info = rows[0]['downloadInfo']
        branch_flag = 'IsRecommended' if channel == 'production' else 'IsFeaturePreview'
        if str(info.get(branch_flag)) != '1' or str(info.get('IsBeta')) != '0' or info.get('OsCode') != 'linux64':
            raise ValueError('NVIDIA branch/platform flags changed; manual review required')
        version = info.get('DisplayVersion', '')
        if not re.fullmatch(r'\d{3}\.\d+(?:\.\d+)?', version):
            raise ValueError('NVIDIA returned an invalid version')
        channels[channel] = version
        sources[channel] = {'url': info['DetailsURL'], 'published': info.get('ReleaseDateTime'),
                            'metadata_url': url}
    return {'channels': channels, 'sources': sources, 'url': 'https://www.nvidia.com/en-us/drivers/unix/'}


def source_fingerprint(ctx):
    """Relevant source bytes, including dirty/untracked configuration, not just Git HEAD."""
    paths = [ctx.root / p for p in ('flake.nix', 'flake.lock')]
    for directory in ('hosts', 'modules', 'lib', 'pins', 'patches', 'packages', 'tests'):
        for folder, directories, filenames in os.walk(ctx.root / directory, followlinks=False):
            directories[:] = [name for name in directories if name not in {'target', 'node_modules', '__pycache__', '.git', 'dist'}
                               and not (Path(folder) / name).is_symlink()]
            paths.extend(Path(folder) / name for name in filenames
                         if Path(name).suffix in {'.nix', '.json', '.patch', '.py', '.sh', '.c', '.rs'})
    h = hashlib.sha256()
    for path in sorted(set(paths)):
        if path.exists():
            h.update(str(path.relative_to(ctx.root)).encode() + b'\0')
            h.update(path.read_bytes() + b'\0')
    return h.hexdigest()


def boot_state(current, booted):
    """A different toplevel alone is not evidence of a required reboot."""
    current, booted = Path(current), Path(booted)
    compared, missing = {}, []
    for name in ('kernel', 'kernel-modules', 'initrd'):
        if not (current / name).exists() or not (booted / name).exists():
            missing.append(name)
            continue
        compared[name] = {'installed': str((current / name).resolve()),
                          'booted': str((booted / name).resolve())}
    changed = [name for name, paths in compared.items() if paths['installed'] != paths['booted']]
    return {'reboot_required': True if changed else (None if missing else False),
            'boot_changes': changed, 'boot_comparison': compared,
            'boot_evidence_missing': missing}


def os_local():
    facts = {'platform': platform.system(), 'kernel_running': platform.release(), 'observed_at': now()}
    if Path('/etc/os-release').exists():
        facts['release'] = {key: value.strip('"') for key, value in
                            (line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                             if '=' in line)}
    if Path('/run/current-system').exists():
        current, booted = Path('/run/current-system'), Path('/run/booted-system')
        facts.update(installed_generation=str(current.resolve()), booted_generation=str(booted.resolve()))
        facts.update(boot_state(current, booted))
        kernel = re.search(r'linux-(\d[\d.]+)', str((current / 'kernel').resolve()))
        facts['kernel_installed'] = kernel[1] if kernel else None
        driver = Path('/proc/driver/nvidia/version')
        if driver.exists():
            match = re.search(r'\b(\d{3}\.\d+(?:\.\d+)?)\b', driver.read_text())
            facts['nvidia_loaded'] = match[1] if match else 'unknown'
        if shutil.which('modinfo'):
            modules = sorted((current / 'kernel-modules/lib/modules').glob('*/**/nvidia.ko*'))
            if modules:
                facts['nvidia_installed'] = run(['modinfo', '-F', 'version', modules[0]], timeout=5).stdout.strip()
    elif platform.system() == 'Darwin':
        facts['macos_installed'] = run(['sw_vers', '-productVersion'], timeout=5).stdout.strip()
        facts['os_management'] = 'Company managed; offered OS/driver updates are informational'
    if platform.system() != 'Darwin' and shutil.which('codex'):
        try:
            facts['codex_installed'] = run(['codex', '--version'], timeout=5).stdout.strip().split()[-1]
        except (OSError, RuntimeError, IndexError, subprocess.TimeoutExpired) as exc:
            facts['codex_probe_error'] = str(exc)
    return facts


def editor_local(ctx):
    """Read Mason receipts without launching Neovim or executing a helper's default mode."""
    profile = 'macos-managed' if platform.system() == 'Darwin' else 'default'
    suffix = '.macos-managed' if profile == 'macos-managed' else ''
    lock_path = 'nvim/mason-lock' + suffix + '.json'
    desired = read(ctx.root / lock_path, {}).get('packages', {})
    selected = ctx.load('active-editor.json', {}).get('profiles', {}).get(profile, {})
    selected_locks = (read(Path(selected['root']) / lock_path, {}).get('packages', {})
                      if selected.get('root') else {})
    data_home = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    packages = []
    for name, version in desired.items():
        receipt = read(data_home / 'nvim/mason/packages' / name / 'mason-receipt.json', {})
        installed = receipt.get('install_options', {}).get('version')
        if not installed:
            source = receipt.get('source', {}).get('id', '')
            installed = source.rsplit('@', 1)[1] if '@' in source else None
        packages.append({'id': 'mason:' + name, 'name': name, 'declared_version': version,
                         'selected_version': selected_locks.get(name),
                         'installed_version': installed, 'running_version': None,
                         'deployment': 'matches' if installed == version else 'different' if installed else 'unverified'})
    return {'observed_at': now(), 'mason': packages, 'profile': profile, 'selected_source': selected,
            'plugin_pins': len(read(ctx.root / ('nvim/lazy-lock' + suffix + '.json'), {})),
            'running_editor': 'unverified', 'note': 'Receipts prove installed targets, not a running language-server version.'}


def installed_nix_references():
    """References of the actual activated profiles, without evaluating desired configuration."""
    paths = [Path('/run/current-system/sw'), Path('/etc/profiles/per-user') / os.environ.get('USER', 'alx')]
    result = {'profile_paths': [], 'references': [], 'errors': []}
    refs = set()
    for path in paths:
        if not path.exists():
            continue
        result['profile_paths'].append(str(path.resolve()))
        try:
            refs.update(run(['nix-store', '--query', '--references', path.resolve()], timeout=20).stdout.splitlines())
        except (OSError, RuntimeError) as exc:
            result['errors'].append(str(exc))
    result['references'] = sorted(refs)
    return result


def group_nix_packages(packages):
    """One stable catalog ID per tool, retaining every selected package/output variant."""
    by_name = {}
    for package in packages:
        by_name.setdefault(package['name'], []).append(package)
    result = []
    for name, variants in sorted(by_name.items()):
        if len(variants) == 1:
            result.append(variants[0])
            continue
        versions = sorted({item['version'] for item in variants})
        installed = sorted({item['installed_version'] for item in variants if item['installed_version']})
        result.append({'id': 'nix:' + name, 'name': name, 'platform': 'nixos', 'source': 'flake.nix',
                       'source_attribute': variants[0]['source_attribute'],
                       'description': ' / '.join(sorted({item['description'] for item in variants})),
                       'version': ', '.join(versions), 'declared_version': ', '.join(versions),
                       'declared_versions': versions, 'installed_versions': installed,
                       'installed': 'all-exact-store-paths-present' if all(item['installed_version'] for item in variants)
                                    else 'some-exact-store-paths-present' if installed else 'unverified',
                       'installed_version': ', '.join(installed) if installed else None, 'running_version': None,
                       'variants': [{key: value for key, value in item.items() if key != 'id'} for item in variants]})
    return result


def nix_inventory(ctx, host='tracer', *, persist=True):
    # Native evaluation is authoritative. This is not a transitive closure inventory.
    if not re.fullmatch(r'[A-Za-z0-9_-]+', host):
        raise ValueError('Invalid Nix host name')
    expr = '''let f = builtins.getFlake (builtins.getEnv "DOTCTL_FLAKE");
      c = f.nixosConfigurations.${builtins.getEnv "DOTCTL_NIX_HOST"}.config;
      packages = c.environment.systemPackages ++ c.home-manager.users.alx.home.packages;
      in { packages = map (p: { id = "nix:" + (p.pname or p.name); name = p.pname or p.name;
        version = p.version or "unknown"; store_path = toString p;
        description = p.meta.description or ""; platform = "nixos"; }) packages;
        kernel_declared = c.boot.kernelPackages.kernel.version;
        nvidia_declared = c.hardware.nvidia.package.version;
        services = builtins.attrNames c.systemd.services;
        user_services = builtins.attrNames c.home-manager.users.alx.systemd.user.services;
      }'''
    result = json.loads(run(['nix', 'eval', '--impure', '--no-write-lock-file', '--json', '--expr', expr],
                           cwd=ctx.root, env={**os.environ, 'DOTCTL_FLAKE': nix_source(ctx.root),
                                             'DOTCTL_NIX_HOST': host}, timeout=240).stdout)
    # A package can be selected at multiple versions; store paths distinguish those records.
    result['packages'] = sorted({p['store_path']: p for p in result['packages']}.values(),
                                key=lambda p: (p['name'], p['store_path']))
    activated = installed_nix_references()
    for package in result['packages']:
        package['source'] = 'flake.nix'
        package['source_attribute'] = f'nixosConfigurations.{host}.config'
        package['declared_version'] = package['version']
        package['installed'] = 'exact-store-path-present' if package['store_path'] in activated['references'] else 'unverified'
        package['installed_version'] = package['version'] if package['installed'] == 'exact-store-path-present' else None
        package['running_version'] = None
    result['selected_output_count'] = len(result['packages'])
    result['packages'] = group_nix_packages(result['packages'])
    result.update(observed_at=now(), source_revision=ctx.git('rev-parse', 'HEAD'),
                  source_fingerprint=source_fingerprint(ctx), working_tree_dirty=bool(ctx.git('status', '--porcelain')),
                  activated_profiles=activated, host=host,
                  note='Declared packages come from Nix evaluation. Absent profile references do not prove a package is uninstalled; running versions require a specific probe.')
    if persist:
        ctx.save('inventory-nix.json', result)
    return result


def brew_declarations(ctx):
    result = {'brew': set(), 'cask': set()}
    for filename in ('platforms/macos-managed/Brewfile', 'platforms/macos/Brewfile'):
        path = ctx.root / filename
        if path.exists():
            for kind, name in re.findall(r'^\s*(brew|cask)\s+["\']([^"\']+)["\']', path.read_text(), re.M):
                result[kind].add(name)
    return {kind: sorted(names) for kind, names in result.items()}


def brew_snapshot(ctx):
    declarations = brew_declarations(ctx)
    result = {'observed_at': now(), 'formulae': [], 'casks': [], 'declarations': declarations,
              'semantics': 'Homebrew recipe snapshot, not a version lock; re-resolve before apply.'}
    env = {**os.environ, 'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_INSTALL_CLEANUP': '1'}
    # Explicit type avoids formula/cask name ambiguity; no update/install/upgrade here.
    for kind, names in declarations.items():
        if not names:
            continue
        data = json.loads(run(['brew', 'info', '--json=v2', '--formula' if kind == 'brew' else '--cask', *names],
                              timeout=180, env=env).stdout)
        for formula in data.get('formulae', []):
            result['formulae'].append({'name': formula['name'], 'version': formula['versions']['stable'],
                'revision': formula['revision'], 'installed': formula['installed'],
                'recipe': formula.get('ruby_source_checksum'), 'tap_git_head': formula.get('tap_git_head'),
                'running_version': None})
        for cask in data.get('casks', []):
            result['casks'].append({'name': cask['token'], 'version': cask['version'], 'installed': cask.get('installed'),
                'recipe': cask.get('ruby_source_checksum'), 'tap_git_head': cask.get('tap_git_head'),
                'running_version': None})
    result['agent_policy'] = 'Managed Mac uses the declared Homebrew claude-code cask'
    return result


def inputs(ctx):
    lock = read(ctx.root / 'flake.lock', {})
    nodes = lock.get('nodes', {})
    direct = nodes.get(lock.get('root', 'root'), {}).get('inputs', {})
    return {name: nodes[identity] for name, identity in direct.items()
            if isinstance(identity, str) and identity in nodes}


def providers(ctx):
    if platform.system() == 'Darwin':
        return {'claude': lambda: {
            'version': json.loads(fetch('https://formulae.brew.sh/api/cask/claude-code.json'))['version'],
            'url': 'https://formulae.brew.sh/cask/claude-code', 'channel': 'Homebrew cask'}}
    result = {'os-release': nixos_release, 'nvidia': nvidia,
              'kernel': lambda: {'version': json.loads(fetch('https://www.kernel.org/releases.json'))['latest_stable']['version'],
                                'url': 'https://www.kernel.org/'},
              'codex': lambda: {'version': normalize_version(json.loads(fetch('https://releases.openai.com/codex/channels/latest'))['tag_name']),
                                'url': 'https://releases.openai.com/codex/channels/latest'}}
    for name, node in inputs(ctx).items():
        original = node.get('original', {})
        if original.get('type') != 'github':
            continue
        repo = original['owner'] + '/' + original['repo']
        ref = original.get('ref', 'HEAD')
        if re.match(r'^v?\d', ref):
            result['input:' + name] = lambda repo=repo: release(repo)
        else:
            url = f'https://api.github.com/repos/{repo}/commits/{urllib.parse.quote(ref, safe="")}'
            result['input:' + name] = lambda url=url, ref=ref: {
                'revision': json.loads(fetch(url))['sha'], 'ref': ref, 'url': url}
    return result


def normalize_version(value):
    """Official Codex release tags use rust-v; pins and CLI versions use numeric versions."""
    return re.sub(r'^(?:rust-)?v(?=\d)', '', value) if isinstance(value, str) else value


def observe(previous, fn):
    """Keep successful evidence and its timestamp when a refresh fails."""
    try:
        return {'value': fn(), 'observed_at': now(), 'attempted_at': now(), 'error': None}
    except Exception as exc:
        return {**previous, 'error': str(exc), 'attempted_at': now()}


def refresh(ctx):
    with ctx.lock('refresh'):
        previous = ctx.load('status.json', {})
        active_providers = providers(ctx)
        evidence = {name: item for name, item in previous.get('upstream', {}).items() if name in active_providers}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = {pool.submit(observe, evidence.get(name, {}), fn): name
                       for name, fn in active_providers.items()}
            for future in concurrent.futures.as_completed(futures):
                evidence[futures[future]] = future.result()
        result = envelope('status', observed_at=now(), upstream=evidence)
        local = observe({'value': previous.get('local', {}),
                         'observed_at': previous.get('local', {}).get('observed_at')}, os_local)
        result['local'] = {**local.get('value', {}), 'error': local.get('error'),
                           'observed_at': local.get('observed_at'), 'attempted_at': local.get('attempted_at')}
        result['runtime'] = []
        editor = observe({'value': previous.get('editor', {})}, lambda: editor_local(ctx))
        result['editor'] = {**editor.get('value', {}), 'error': editor.get('error'),
                            'attempted_at': editor.get('attempted_at')}
        for item in records(ctx):
            if is_background(item):
                observed = observe({}, lambda item=item: runtime(item))
                result['runtime'].append({'id': item['id'], **observed.get('value', {'state': 'unknown'}),
                                          'observed_at': observed.get('observed_at'),
                                          **({'error': observed['error']} if observed.get('error') else {})})
        if shutil.which('nix') and Path('/etc/NIXOS').exists():
            observation = observe({'value': previous.get('inventory', ctx.load('inventory-nix.json', {}))},
                                  lambda: nix_inventory(ctx))
            result['inventory'] = {**observation.get('value', {}), 'error': observation.get('error'),
                                   'attempted_at': observation.get('attempted_at')}
        if platform.system() == 'Darwin':
            observation = observe({'value': previous.get('brew', {})}, lambda: brew_snapshot(ctx))
            result['brew'] = {**observation.get('value', {}), 'error': observation.get('error'),
                              'attempted_at': observation.get('attempted_at')}
            def offered():
                output = run(['softwareupdate', '--list'], timeout=120)
                return {'output': output.stdout, 'management': 'informational; company managed'}
            result['macos_offered'] = observe(previous.get('macos_offered', {}), offered)
        ctx.save('status.json', result)
    return cached(ctx)


def runtime_has_state(observation, state):
    """Grouped probes can contain both a failed unit and an unobserved unit."""
    return observation.get('state') == state or any(
        runtime_has_state(unit, state) for unit in observation.get('units', {}).values())


def cached(ctx, group=None):
    """No subprocess, network request, lock, or state write belongs in this path."""
    result = ctx.load('status.json', envelope('status', observed_at=None, upstream={}))
    observed = {item['id'] for item in result.get('runtime', [])}
    for item in records(ctx):
        if is_background(item) and applies_here(item) and item['id'] not in observed:
            result.setdefault('runtime', []).append({
                'id': item['id'], 'state': 'unknown', 'observed_at': None,
                'evidence': 'No cached runtime observation for this declared background component; run dotctl status --refresh.'})
    if platform.system() == 'Darwin':
        result['upstream'] = {name: item for name, item in result.get('upstream', {}).items() if name == 'claude'}
    hours = ctx.policy.get('metadata_stale_hours', 48)
    result['stale'] = stale(result.get('observed_at'), hours)
    for entry in result.get('upstream', {}).values():
        entry['stale'] = stale(entry.get('observed_at'), hours)
    for name in ('local', 'inventory', 'brew', 'editor'):
        if name in result:
            result[name]['stale'] = stale(result[name].get('observed_at'), hours)
    inventory = result.get('inventory', {})
    if inventory:
        inventory['source_changed'] = inventory.get('source_fingerprint') != source_fingerprint(ctx)
    result['pins'] = {p.stem: read(p) for p in sorted((ctx.root / 'pins').glob('*.json')) if p.stem != 'iloader-cargo'}
    if result.get('local', {}).get('platform') == 'Darwin':
        result['mac_review'] = read(ctx.root / 'platforms/macos-managed/review.json', {})
    result['inputs'] = {name: {'declared_ref': node.get('original', {}).get('ref', 'HEAD'),
                              'pinned_revision': node.get('locked', {}).get('rev'),
                              'upstream': result.get('upstream', {}).get('input:' + name, {})}
                         for name, node in inputs(ctx).items()}
    result['driver_policy'] = ctx.policy.get('driver_policy', {})
    result['candidates'] = [{k: c.get(k) for k in ('id', 'group', 'status', 'head', 'pr', 'error')}
                            for p in sorted((ctx.state / 'candidates').glob('*/candidate.json')) if (c := read(p))]
    result['schedules'] = ctx.load('schedules.json', {'enabled': False,
                              'reason': 'Both supported hosts need acceptance before enabling'})
    degraded = [name for name, item in result.get('upstream', {}).items() if item.get('error') or item['stale']]
    degraded += [name for name in ('local', 'inventory', 'brew', 'editor')
                 if name in result and (result[name].get('error') or result[name].get('stale'))]
    result['health'] = {'runtime_issues': [r['id'] for r in result.get('runtime', []) if runtime_has_state(r, 'failed')],
                        'unknown_runtime': [r['id'] for r in result.get('runtime', []) if runtime_has_state(r, 'unknown')]}
    result['freshness'] = {'stale': result['stale'], 'unverified_sources': degraded,
                           'declared_inventory_changed': inventory.get('source_changed', False)}
    result['deployment'] = {'reboot_required': result.get('local', {}).get('reboot_required'),
                            'installed_generation': result.get('local', {}).get('installed_generation'),
                            'booted_generation': result.get('local', {}).get('booted_generation')}
    result['versions'] = version_summary(result)
    result['next_step'] = ('dotctl status --refresh' if result['stale'] or degraded or inventory.get('source_changed')
                           else 'dotctl prepare <group> to stage an update')
    if group:
        result['selected_group'] = group
        result['candidates'] = [c for c in result['candidates'] if c['group'] == group]
    return result


def version_summary(result):
    """Keep installed/running/policy targets separate from newer upstream versions."""
    local, inventory = result.get('local', {}), result.get('inventory', {})
    upstream = result.get('upstream', {})
    def latest(name):
        value = upstream.get(name, {}).get('value', {})
        return value.get('version') if isinstance(value, dict) else value
    def comparison(installed, available):
        if not installed or not available:
            return 'unknown'
        def numeric(value):
            match = re.fullmatch(r'(\d+(?:\.\d+)*)', normalize_version(value))
            return tuple(map(int, match[1].split('.'))) if match else None
        left, right = numeric(installed), numeric(available)
        if left is None or right is None:
            return 'matches' if installed == available else 'different'
        return 'behind' if left < right else 'matches' if left == right else 'ahead'
    policy = result.get('driver_policy', {})
    driver_channels = upstream.get('nvidia', {}).get('value', {}).get('channels', {})
    definitions = [
        {'id': 'nixos-release', 'declared': result.get('inputs', {}).get('nixpkgs', {}).get('declared_ref'),
         'installed': local.get('release', {}).get('VERSION_ID'), 'running': None,
         'latest_upstream': latest('os-release'), 'policy': 'Separate reviewed OS release candidate'},
        {'id': 'kernel', 'declared': inventory.get('kernel_declared'), 'installed': local.get('kernel_installed'),
         'running': local.get('kernel_running'), 'latest_upstream': latest('kernel'),
         'policy': 'Nix channel kernel; latest upstream is informational, not an automatic target'},
        {'id': 'nvidia', 'declared': inventory.get('nvidia_declared'), 'installed': local.get('nvidia_installed'),
         'running': local.get('nvidia_loaded'), 'latest_upstream': driver_channels.get(policy.get('channel')),
         'upstream_channels': driver_channels, 'policy': policy},
        {'id': 'codex', 'declared': result.get('pins', {}).get('codex', {}).get('version'),
         'installed': local.get('codex_installed'), 'running': None, 'latest_upstream': latest('codex'),
         'policy': 'Reviewed native update; running Codex sessions are not inspected'}]
    if local.get('platform') == 'Darwin':
        claude = next((item for item in result.get('brew', {}).get('casks', []) if item.get('name') == 'claude-code'), {})
        installed = claude.get('installed')
        if isinstance(installed, list):
            installed = ', '.join(installed) if installed else None
        reviewed = result.get('mac_review', {}).get('packages', {}).get('cask:claude-code', {})
        definitions = [
            {'id': 'claude', 'declared': reviewed.get('target', 'Homebrew cask:claude-code'),
             'installed': installed, 'running': None, 'latest_upstream': latest('claude'),
             'policy': 'Company-managed Mac uses Claude Code from Homebrew; recipe changes require a reviewed Mac candidate'}]
    for item in definitions:
        item['freshness'] = comparison(item['installed'], item['latest_upstream'])
        item['deployment'] = ('matches' if item['installed'] == item['running'] else 'different') if item['running'] and item['installed'] else 'unverified'
        provider = 'os-release' if item['id'] == 'nixos-release' else item['id']
        item['upstream_observed_at'] = upstream.get(provider, {}).get('observed_at')
        item['upstream_stale'] = stale(item['upstream_observed_at'])
        item['upstream_error'] = upstream.get(provider, {}).get('error')
    if local.get('platform') == 'Darwin':
        definitions.insert(0, {'id': 'macos', 'installed': local.get('macos_installed'),
                               'policy': 'Company managed; offered updates are informational',
                               'offered': result.get('macos_offered', {}), 'deployment': 'unverified'})
    return definitions


def patch_fingerprint(ctx, patch):
    h = hashlib.sha256(json.dumps(patch, sort_keys=True).encode())
    for source in sorted(set(patch.get('source_paths', [patch['source']]))):
        if Path(source).is_absolute() or '..' in Path(source).parts:
            raise ValueError('Unsafe patch source path')
        path = ctx.root / source
        h.update(source.encode() + b'\0')
        h.update(digest(path).encode() if path.is_file() else b'MISSING')
    return h.hexdigest()


def patches(ctx):
    results = []
    target = source_fingerprint(ctx)
    states = {'required', 'upstream candidate found', 'removal testing needed', 'removal validated', 'unknown'}
    for patch in read(ctx.root / 'catalog/patches.json', []):
        evidence = ctx.load('patch-evidence/' + patch['id'] + '.json', {})
        fingerprint = patch_fingerprint(ctx, patch)
        valid = bool(evidence) and evidence.get('source_fingerprint') == fingerprint and evidence.get('target_fingerprint') == target
        state = evidence.get('state', 'unknown') if valid else 'unknown'
        if state not in states:
            state = 'unknown'
        requires_live = patch.get('removal', {}).get('requires_live', False)
        if state == 'removal validated' and (not evidence.get('build_passed') or not evidence.get('regression_passed')
                                            or requires_live and not evidence.get('live_passed')):
            state = 'removal testing needed'
        results.append({**patch, 'state': state, 'evidence': evidence, 'evidence_current': valid,
                        'source_fingerprint': fingerprint, 'target_fingerprint': target,
                        'next_step': patch.get('removal_test', patch.get('removal', {}).get('regression', 'Review removal evidence'))})
    return envelope('patches', items=results)
