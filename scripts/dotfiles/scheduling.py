"""OS scheduling and host acceptance. Preparation never activates a machine."""
from __future__ import annotations
import datetime as dt
import os
from pathlib import Path
import platform
import plistlib
import sys

import catalog
from core import atomic, envelope, now, read, run
import maintenance
import adapters
import status
import storage


def acceptance(ctx):
    profile = maintenance.local_profile()
    host = 'work-mac' if profile == 'macos-managed' else 'tracer'
    group = 'mac' if host == 'work-mac' else 'system'
    with ctx.lock('acceptance'):
        if ctx.git('status', '--porcelain'):
            raise RuntimeError('Host acceptance needs a committed clean source revision')
        revision = ctx.git('rev-parse', 'HEAD')
        tree = ctx.git('rev-parse', 'HEAD^{tree}')
        source_digest = adapters._source_digest(ctx.root)
        checks = maintenance.check(ctx, group, profile=profile)
        if not checks.get('ok'):
            raise RuntimeError('Native checks failed; host acceptance was not recorded')
        if (checks.get('revision') != revision or checks.get('dirty') is not False
                or checks.get('result', {}).get('source_digest') != source_digest):
            raise RuntimeError('Native checks describe a different source revision; acceptance was not recorded')
        if host == 'tracer':
            built = checks['result'].get('build_path')
            if not built or str(Path('/run/current-system').resolve()) != built:
                raise RuntimeError('Built revision is not the running system. Apply and verify it before accepting this host.')
        if host == 'work-mac':
            checks['live'] = adapters.acceptance(ctx, profile)
            if (checks['live'].get('kind') != 'native-mac-acceptance' or checks['live'].get('status') != 'accepted'
                    or checks['live'].get('editor_check', {}).get('source_digest') != source_digest):
                raise RuntimeError('Managed Mac installed-state acceptance did not complete')
        if (ctx.git('rev-parse', 'HEAD') != revision or ctx.git('rev-parse', 'HEAD^{tree}') != tree
                or ctx.git('status', '--porcelain') or adapters._source_digest(ctx.root) != source_digest):
            raise RuntimeError('Source changed during native acceptance; repeat acceptance for the committed revision')
        receipt = envelope('host-acceptance', host=host, platform=platform.system(), profile=profile,
                           revision=revision, tree=tree, source_digest=source_digest,
                           accepted_at=now(), checks=checks)
        ctx.save(f'acceptance/{host}.json', receipt)
        return receipt


def valid_acceptance(host, evidence):
    if not isinstance(evidence, dict) or evidence.get('kind') != 'host-acceptance' or evidence.get('host') != host:
        return False
    expected_platform = 'Darwin' if host == 'work-mac' else 'Linux'
    checks = evidence.get('checks', {})
    digest = evidence.get('source_digest')
    if (evidence.get('platform') != expected_platform or not evidence.get('revision') or not evidence.get('tree')
            or not digest or checks.get('ok') is not True or checks.get('dirty') is not False
            or checks.get('revision') != evidence['revision']
            or checks.get('result', {}).get('source_digest') != digest):
        return False
    if host == 'work-mac':
        live = checks.get('live', {})
        return (live.get('kind') == 'native-mac-acceptance' and live.get('status') == 'accepted'
                and live.get('editor_check', {}).get('source_digest') == digest)
    return bool(checks.get('result', {}).get('build_path'))


def accepted(ctx):
    results = {host: ctx.load(f'acceptance/{host}.json') for host in ('tracer', 'work-mac')}
    missing = [host for host, evidence in results.items() if not valid_acceptance(host, evidence)]
    if missing:
        raise RuntimeError('Scheduled preparation awaits actual host acceptance: ' + ', '.join(missing) +
                           '. Run dotctl schedule accept on each host; copy its local acceptance JSON to the other host.')
    if (results['tracer']['tree'] != results['work-mac']['tree']
            or results['tracer']['source_digest'] != results['work-mac']['source_digest']):
        raise RuntimeError('Hosts accepted different source trees; validate the same committed baseline on both')
    return results


def install(ctx, enable=False):
    previous = ctx.load('schedules.json', {'enabled': False})
    if enable:
        accepted(ctx)
        ctx.save('schedules.json', envelope('schedules', enabled=True, status='installing', configured_at=now()))
    try:
        if maintenance.local_profile() == 'macos-managed':
            directory = Path.home() / 'Library/LaunchAgents'
            directory.mkdir(parents=True, exist_ok=True)
            for name, calendar in [('daily', {'Hour': 9, 'Minute': 0}), ('weekly', {'Weekday': 0, 'Hour': 4, 'Minute': 0})]:
                label = 'local.dotfiles.' + name
                path = directory / (label + '.plist')
                value = {'Label': label, 'ProgramArguments': [str(Path.home() / '.local/bin/dotctl'), 'schedule', name],
                         'StartCalendarInterval': calendar, 'RunAtLoad': True,
                         'WorkingDirectory': str(Path.home()),
                         'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', 'DOTFILES_ROOT': ''},
                         'StandardOutPath': str(ctx.state / (name + '.log')),
                         'StandardErrorPath': str(ctx.state / (name + '.log'))}
                path.write_bytes(plistlib.dumps(value))
                if enable:
                    domain = f'gui/{os.getuid()}'
                    loaded = run(['launchctl', 'print', domain + '/' + label], timeout=10, check=False)
                    if loaded.returncode:
                        run(['launchctl', 'bootstrap', domain, path], timeout=30)
        elif enable:
            for timer in ('dotfiles-refresh.timer', 'dotfiles-prepare.timer'):
                run(['systemctl', '--user', 'add-wants', 'timers.target', timer], timeout=30)
                run(['systemctl', '--user', 'start', timer], timeout=30)
    except BaseException as exc:
        ctx.save('schedules.json', envelope('schedules', enabled=False, status='installation-failed',
                                          error=str(exc), note='Some OS units may be loaded; execution gate is disabled'))
        raise
    result = envelope('schedules', enabled=enable or previous.get('enabled', False), configured_at=now(),
                      daily='09:00', weekly='Sun 04:00')
    ctx.save('schedules.json', result)
    return result


def disable(ctx):
    result = envelope('schedules', enabled=False, disabled_at=now(), results=[])
    ctx.save('schedules.json', result)
    if maintenance.local_profile() == 'macos-managed':
        for name in ('daily', 'weekly'):
            r = run(['launchctl', 'bootout', f'gui/{os.getuid()}/local.dotfiles.{name}'], check=False, timeout=30)
            result['results'].append({'job': name, 'exit_code': r.returncode})
    else:
        for timer in ('dotfiles-refresh.timer', 'dotfiles-prepare.timer'):
            r = run(['systemctl', '--user', 'disable', '--now', timer], check=False, timeout=30)
            result['results'].append({'job': timer, 'exit_code': r.returncode})
    ctx.save('schedules.json', result)
    return result


def due(ctx, name, today=None):
    today = today or dt.datetime.now().astimezone()
    last = ctx.load('schedule-' + name + '.json', {})
    if name == 'daily':
        scheduled = today.replace(hour=9, minute=0, second=0, microsecond=0)
        if today < scheduled:
            scheduled -= dt.timedelta(days=1)
    elif name == 'weekly':
        days = (today.weekday() + 1) % 7
        scheduled = (today - dt.timedelta(days=days)).replace(hour=4, minute=0, second=0, microsecond=0)
        if today < scheduled:
            scheduled -= dt.timedelta(days=7)
    else:
        raise ValueError('Unknown schedule')
    slot = scheduled.isoformat()
    return last.get('slot') != slot or last.get('status') != 'completed', slot


def run_job(ctx, name):
    if not ctx.load('schedules.json', {}).get('enabled'):
        return envelope('schedule-run', status='disabled', next_step='Complete native acceptance before dotctl schedule enable')
    accepted(ctx)
    # A separate lock prevents daily and weekly jobs overlapping across their individual operations.
    with ctx.lock('scheduled-jobs'):
        should_run, slot = due(ctx, name)
        if not should_run:
            return envelope('schedule-run', status='already-ran', slot=slot)
        previous = ctx.load('schedule-' + name + '.json', {})
        receipt = envelope('schedule-run', name=name, slot=slot, started_at=now(), status='running', results=[])
        ctx.save('schedule-' + name + '.json', receipt)
        try:
            if name == 'daily':
                receipt['results'].append(status.refresh(ctx))
            elif name == 'weekly':
                receipt['results'].append(catalog.validate(ctx))
                receipt['results'].append(status.patches(ctx))
                try:
                    receipt['results'].append(maintenance.review_inventory(ctx))
                except Exception as exc:
                    receipt['results'].append({'catalog_review': 'failed', 'status': 'failed', 'error': str(exc)})
                groups = ['mac'] if maintenance.local_profile() == 'macos-managed' else ['system', 'os-release', 'drivers', 'desktop', 'editor']
                earlier = {item['group']: item for item in previous.get('results', []) if 'group' in item}
                for group in groups:
                    old = earlier.get(group, {})
                    if previous.get('slot') == slot and old.get('status') in {'ready', 'no-change'}:
                        receipt['results'].append(old)
                        ctx.save('schedule-' + name + '.json', receipt)
                        continue
                    existing = next((item for item in maintenance.candidates(ctx) if item['id'] == old.get('candidate')), None)
                    if (old.get('status') == 'held' and existing and existing.get('status') not in maintenance.TERMINAL
                            and existing.get('error') == old.get('error')):
                        receipt['results'].append(old)
                        ctx.save('schedule-' + name + '.json', receipt)
                        continue
                    try:
                        if existing and existing.get('status') in {'failed', 'publication-pending', 'validated', 'stale'}:
                            result = maintenance.retry(ctx, existing['id'])
                        else:
                            result = maintenance.prepare(ctx, group)
                        state = result['status'] if result['status'] in {'ready', 'no-change'} else 'failed'
                        receipt['results'].append({'group': group, 'candidate': result['id'], 'status': state,
                                                   'candidate_status': result['status'], 'error': result.get('error')})
                    except Exception as exc:
                        pending = [item for item in maintenance.candidates(ctx)
                                   if item['group'] == group and item['status'] not in maintenance.TERMINAL]
                        receipt['results'].append({'group': group,
                            'status': 'held' if isinstance(exc, adapters.AdapterHold) else 'failed', 'error': str(exc),
                            'candidate': pending[0]['id'] if len(pending) == 1 else None})
                    # Preserve completed groups if a later group or cleanup is interrupted.
                    ctx.save('schedule-' + name + '.json', receipt)
                receipt['results'].append(storage.cleanup(ctx))
            else:
                raise ValueError('Unknown scheduled job')
            failed = any(item.get('status') == 'failed' or item.get('ok') is False for item in receipt['results'])
            succeeded = any(item.get('status') in {'ready', 'no-change'} for item in receipt['results'])
            receipt['status'] = ('partial' if succeeded else 'failed') if failed else 'completed'
        except BaseException as exc:
            receipt.update(status='failed', error=str(exc))
            raise
        finally:
            receipt['ended_at'] = now()
            ctx.save('schedule-' + name + '.json', receipt)
        return receipt
