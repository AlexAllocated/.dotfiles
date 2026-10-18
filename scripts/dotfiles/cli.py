#!/usr/bin/env python3
"""Terminal-first map, evidence and reviewed maintenance."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from core import Context, envelope
import catalog
import maintenance
import scheduling
import status
import storage


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument('--root', type=Path, help='explicit source checkout (also DOTFILES_ROOT)')
    root.add_argument('--json', action='store_true', help='versioned machine-readable output')
    commands = root.add_subparsers(dest='command', required=True)
    commands.add_parser('map', help='machine → capability → custom component')
    cat = commands.add_parser('catalog', help='search names, purpose, aliases and sources')
    cat.add_argument('query', nargs='?', default='')
    cat.add_argument('--scope', choices=['managed', 'background', 'legacy', 'storage'])
    cat.add_argument('--validate', action='store_true')
    inspect = commands.add_parser('inspect', help='explain a component or artifact')
    inspect.add_argument('id')
    for name in ('status', 'doctor'):
        command = commands.add_parser(name, help='cached health, freshness and deployment evidence')
        command.add_argument('group', nargs='?', choices=maintenance.GROUPS)
        command.add_argument('--refresh', action='store_true')
    commands.add_parser('patches', help='patch purpose, retirement evidence and next tests')
    store = commands.add_parser('storage', help='registered backups, archives and owned artifacts')
    store.add_argument('--refresh', action='store_true')
    cleanup = commands.add_parser('cleanup', help='review or expire verified disposable scratch')
    cleanup.add_argument('--plan', action='store_true')
    cleanup.add_argument('--disposable', action='store_true')
    for name in ('prepare', 'update'):
        prepare = commands.add_parser(name, help='prepare one group in an isolated worktree')
        prepare.add_argument('group', choices=maintenance.GROUPS)
        prepare.add_argument('--no-publish', action='store_true')
        prepare.add_argument('--no-repair', action='store_true')
        prepare.add_argument('--from', dest='from_revision', help='validate a manually prepared committed group revision')
    retry = commands.add_parser('retry', help='resume a retained candidate without repeating a merge')
    retry.add_argument('id')
    retry.add_argument('--no-repair', action='store_true')
    retire = commands.add_parser('retire', help='close a candidate PR and preserve its artifacts')
    retire.add_argument('id')
    retire.add_argument('--reason', required=True)
    check = commands.add_parser('check', help='catalog and native validation')
    check.add_argument('group', nargs='?', default='system', choices=maintenance.GROUPS)
    check.add_argument('--profile')
    updoot = commands.add_parser('updoot', help='review, merge and apply one tested candidate')
    updoot.add_argument('candidate', nargs='?')
    apply = commands.add_parser('apply', help='apply this clean committed source without discovering updates')
    apply.add_argument('profile', nargs='?')
    apply.add_argument('--group', choices=maintenance.GROUPS)
    apply.add_argument('--update', action='store_true', help='compatibility alias for Updoot')
    commands.add_parser('rollback', help='activate the recorded previous NixOS system')
    schedule = commands.add_parser('schedule', help='OS jobs and native-host acceptance')
    schedule.add_argument('action', choices=['status', 'install', 'enable', 'disable', 'accept', 'daily', 'weekly'])
    legacy = commands.add_parser('codex-share', help='legacy shared-storage tooling')
    legacy.add_argument('arguments', nargs=argparse.REMAINDER)
    return root


def render(value, indent=0):
    """Plain output works in terminals and pipes; no escape codes or hidden truncation."""
    pad = ' ' * indent
    if isinstance(value, dict):
        for key, entry in value.items():
            if key == 'schema_version':
                continue
            if isinstance(entry, (dict, list)):
                print(f'{pad}{key}:')
                render(entry, indent + 2)
            else:
                print(f'{pad}{key}: {entry if entry is not None else "unknown"}')
    elif isinstance(value, list):
        for entry in value:
            if isinstance(entry, dict):
                name = entry.get('id') or entry.get('name') or entry.get('machine')
                if name:
                    print(pad + str(name))
                render({k: v for k, v in entry.items() if k not in {'id'}}, indent + 2)
            else:
                print(pad + str(entry))
    else:
        print(pad + str(value))


def concise(value, limit=110):
    """Keep summaries on one line; complete evidence remains in --json."""
    text = ' '.join(str(value).split())
    return text if len(text) <= limit else text[:limit - 3] + '...'


def names_summary(items, limit=3):
    names = [str(item) for item in items]
    return ', '.join(names[:limit]) + (f' (+{len(names) - limit} more)' if len(names) > limit else '')


def display_status(result):
    local = result.get('local', {})
    inventory = result.get('inventory', {})
    freshness = result.get('freshness', {})
    changed = inventory.get('source_changed', freshness.get('declared_inventory_changed'))
    source = ('changed since observation' if changed else
              'matches observation' if changed is False and inventory else 'not observed')
    if inventory.get('working_tree_dirty'):
        source += '; working tree was dirty at observation'
    print('Dotfiles status' + (f" — {result['selected_group']}" if result.get('selected_group') else ''))
    print(f"Observed: {result.get('observed_at') or 'never'} [{('stale' if result.get('stale') else 'cached')}]")
    print('Source: ' + source)
    degraded = freshness.get('unverified_sources', [])
    print(f'Evidence: {len(degraded)} stale or failed sources' + (': ' + concise(names_summary(degraded)) if degraded else ''))
    print()
    versions = result.get('versions', [])
    if versions:
        rows = [('Component', 'Declared', 'Installed', 'Running', 'Latest', 'Status')]
        for item in versions:
            state = 'informational' if item['id'] == 'kernel' else item.get('freshness', 'informational')
            if item['id'] == 'macos':
                state = 'company managed'
            if item.get('deployment') == 'different':
                state += '; running differs'
            if item.get('upstream_error'):
                state += '; refresh failed'
            elif item.get('upstream_stale'):
                state += '; stale'
            rows.append((item['id'], *(concise(item.get(key) or 'unknown', 27)
                                      for key in ('declared', 'installed', 'running', 'latest_upstream')), state))
        widths = [max(len(row[index]) for row in rows) for index in range(5)]
        for row in rows:
            print('  '.join(value.ljust(widths[index]) if index < 5 else value
                            for index, value in enumerate(row)))
        if any(item['id'] == 'kernel' for item in versions):
            print('Kernel latest is informational; updates follow the selected Nix channel.')
        if any(item['id'] == 'macos' for item in versions):
            print('macOS updates remain company managed; offered updates are in --json.')
        print('Unknown means unobserved; running versions require a specific probe.')
    else:
        print('Versions: not observed')
    print()
    health = result.get('health', {})
    issues, unknown = health.get('runtime_issues', []), health.get('unknown_runtime', [])
    print(f'Health: {len(issues)} runtime issues, {len(unknown)} unknown' +
          ('; runtime not observed' if not result.get('runtime') and not issues and not unknown else ''))
    if issues:
        print('  Issues: ' + concise(names_summary(issues)))
    if unknown:
        print('  Unknown: ' + concise(names_summary(unknown)))
    reboot = result.get('deployment', {}).get('reboot_required', local.get('reboot_required'))
    print('Reboot: ' + ('required' if reboot is True else 'not required' if reboot is False else 'unknown'))
    schedules = result.get('schedules', {})
    print('Schedules: ' + ('on' if schedules.get('enabled') else 'off') +
          (' — ' + concise(schedules['reason']) if schedules.get('reason') else ''))
    if not schedules.get('enabled') and not schedules.get('reason'):
        print('  Enabling requires acceptance of the same baseline on Tracer and the work Mac.')
    if schedules.get('error'):
        print('  Schedule error: ' + concise(schedules['error']))
    candidates = result.get('candidates', [])
    pending = [item for item in candidates if item.get('status') not in maintenance.TERMINAL]
    print(f'Candidates: {len(pending)} pending, {len(candidates) - len(pending)} completed or retired')
    for item in pending[:4]:
        print(f"  {item['id']} [{item.get('group', 'unknown')}: {item.get('status', 'unknown')}]" +
              (' — ' + concise(item['error'], 80) if item.get('error') else ''))
    if len(pending) > 4:
        print(f'  +{len(pending) - 4} more pending; see --json')
    errors = [(name, item['error']) for name, item in result.get('upstream', {}).items() if item.get('error')]
    for name, error in errors[:3]:
        print(f'Upstream error ({name}): ' + concise(error))
    if len(errors) > 3:
        print(f'  +{len(errors) - 3} more upstream errors; see --json')
    for name in ('local', 'inventory', 'brew', 'editor'):
        if result.get(name, {}).get('error'):
            print(f'{name.capitalize()} error: ' + concise(result[name]['error']))
    print()
    print('Refresh: dotctl status --refresh  |  Full evidence: dotctl status --json')
    if pending:
        print('Review and apply: updoot <candidate>')
    elif result.get('next_step', '').startswith('dotctl prepare'):
        print('Stage an update: dotctl prepare <group>')


def display(result):
    kind = result.get('kind')
    if kind == 'map':
        for machine in result['machines']:
            print(f"{machine['machine']} [{machine['classification']}]")
            for capability, components in machine['capabilities'].items():
                print('  ' + capability)
                for item in components:
                    print(f"    {item['id']}: {item['name']} [{item['classification']}]")
        print('Use dotctl inspect <id> for source, startup, relationships and removal instructions.')
    elif kind == 'catalog':
        for item in result['items']:
            print(f"{item['id']} [{item.get('classification', 'managed')}] {item.get('name', '')}")
            print('  ' + item.get('purpose', item.get('description', item.get('source', ''))))
        print(f"{len(result['items'])} entries. Use dotctl inspect <id> for sources, startup and verification.")
    elif kind == 'status':
        display_status(result)
    elif kind == 'storage':
        for item in result.get('items', []):
            print(f"{item['id']} {'protected' if item.get('protected', True) else 'disposable'} "
                  f"{item.get('allocated_bytes', 0):,} bytes {item['path']}")
        print(result.get('note', 'Run dotctl storage --refresh to inventory registered roots.'))
    elif kind == 'patches':
        for item in result.get('items', []):
            print(f"{item['id']} [{item.get('state', 'unknown')}] {item.get('reason', item.get('purpose', ''))}")
    else:
        render(result)


def execute(ctx, args):
    cmd = args.command
    if cmd == 'map': return catalog.machine_map(ctx)
    if cmd == 'catalog': return catalog.validate(ctx) if args.validate else catalog.search(ctx, args.query, args.scope)
    if cmd == 'inspect': return catalog.inspect(ctx, args.id)
    if cmd in {'status', 'doctor'}: return status.refresh(ctx) if args.refresh else status.cached(ctx, args.group)
    if cmd == 'patches': return status.patches(ctx)
    if cmd == 'storage': return storage.scan(ctx) if args.refresh else storage.cached(ctx)
    if cmd == 'cleanup':
        if args.disposable: return storage.cleanup(ctx)
        return storage.plan(ctx)
    if cmd in {'prepare', 'update'}: return maintenance.prepare(ctx, args.group, publish_pr=not args.no_publish, allow_repair=not args.no_repair, from_revision=args.from_revision)
    if cmd == 'retry': return maintenance.retry(ctx, args.id, allow_repair=not args.no_repair)
    if cmd == 'retire': return maintenance.retire(ctx, args.id, args.reason)
    if cmd == 'check': return maintenance.check(ctx, args.group, args.profile)
    if cmd == 'updoot': return maintenance.updoot(ctx, args.candidate)
    if cmd == 'apply': return maintenance.updoot(ctx) if args.update else maintenance.apply_revision(ctx, args.profile, args.group)
    if cmd == 'rollback': return maintenance.rollback(ctx)
    if cmd == 'schedule':
        if args.action == 'status': return ctx.load('schedules.json', envelope('schedules', enabled=False))
        if args.action == 'disable': return scheduling.disable(ctx)
        if args.action == 'accept': return scheduling.acceptance(ctx)
        if args.action in {'install', 'enable'}: return scheduling.install(ctx, enable=args.action == 'enable')
        return scheduling.run_job(ctx, args.action)
    if cmd == 'codex-share':
        result = subprocess.run([sys.executable, str(ctx.root / 'scripts/codex/share.py'), *args.arguments])
        return envelope('legacy-command', ok=result.returncode == 0, exit_code=result.returncode)
    raise ValueError('Unknown command')


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    # --json works before or after the command, as inspection commands advertise.
    json_output = '--json' in argv
    argv = [arg for arg in argv if arg != '--json']
    args = parser().parse_args(argv)
    root = args.root or os.environ.get('DOTFILES_ROOT') or Path(__file__).resolve().parents[2]
    ctx = Context(root)
    try:
        result = execute(ctx, args)
        if json_output:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            display(result)
        return 1 if result.get('ok') is False else 0
    except (Exception, KeyboardInterrupt) as exc:
        if json_output:
            print(json.dumps(envelope('error', ok=False, error=str(exc)), indent=2))
        else:
            print(f'dotctl: {exc}', file=sys.stderr)
        return 130 if isinstance(exc, KeyboardInterrupt) else 1


if __name__ == '__main__':
    raise SystemExit(main())
