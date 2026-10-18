#!/usr/bin/env python3
"""Test fullscreen on an isolated Niri virtual display; requires Node 22+ and grim."""
import argparse
import collections
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import urllib.request


def executable(value, names):
    result = value or next((shutil.which(name) for name in names if shutil.which(name)), None)
    if not result:
        raise ValueError(f"Executable required: {' / '.join(names)}")
    return str(Path(result).resolve())


def parse_feedback(log, probe):
    feedback, xdg, toplevels, titles = {}, {}, {}, {}
    counts = collections.defaultdict(collections.Counter)
    stable = collections.defaultdict(collections.Counter)
    transitions = []
    start, end = probe['started'], probe['finished']
    entered = next((e['at'] for e in probe['state']['events'] if e['fullscreen']), None)
    midnight = datetime.datetime.fromtimestamp(start / 1000, datetime.timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).timestamp() * 1000
    for line in log.splitlines():
        match = re.match(r'\[(\d+):(\d+):(\d+)\.(\d+)\]', line)
        if not match:
            continue
        hour, minute, second, micros = map(int, match.groups())
        at = midnight + (hour * 3600 + minute * 60 + second) * 1000 + micros / 1000
        if at < start - 43200000:
            at += 86400000
        if match := re.search(r'get_xdg_surface\(new id xdg_surface#(\d+), wl_surface#(\d+)\)', line):
            xdg[match[1]] = match[2]
        if match := re.search(r'xdg_surface#(\d+)\.get_toplevel\(new id xdg_toplevel#(\d+)\)', line):
            toplevels[match[2]] = xdg.get(match[1])
        if match := re.search(r'xdg_toplevel#(\d+)\.set_title\("(.*)"\)', line):
            titles[toplevels.get(match[1])] = match[2]
        if match := re.search(r'feedback\(wl_surface#(\d+), new id wp_presentation_feedback#(\d+)\)', line):
            feedback[match[2]] = match[1]
        if match := re.search(r'wp_presentation_feedback#(\d+)\.(presented|discarded)\(', line):
            surface = feedback.get(match[1], 'unknown')
            if start <= at <= end:
                counts[surface][match[2]] += 1
            if entered is not None and entered + 1000 <= at <= end:
                stable[surface][match[2]] += 1
        if match := re.search(r'xdg_toplevel#(\d+)\.(set_fullscreen|unset_fullscreen)\(', line):
            if start <= at <= end:
                transitions.append({'at': at, 'toplevel': match[1], 'action': match[2]})

    def rows(values):
        return [{'surface': surface, 'title': titles.get(surface, 'subsurface/other'), **dict(count)}
                for surface, count in values.items()]
    return rows(counts), rows(stable), transitions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('niri', 'chrome', 'node', 'grim'):
        parser.add_argument('--' + flag, help='Executable path; otherwise searched on PATH')
    parser.add_argument('--egl-vendor-file', help='Override EGL vendor for isolated Niri only')
    parser.add_argument('--output-dir', type=Path, help='Parent directory for retained run artifacts')
    parser.add_argument('--seconds', type=float, default=6)
    parser.add_argument('--expect-exit', action='store_true', help='Baseline: require automatic fullscreen exit')
    parser.add_argument('--no-hidden-window', action='store_true')
    parser.add_argument('--no-capture', action='store_true', help='Negative control: do not consume virtual frames')
    args = parser.parse_args()
    if args.seconds < 5:
        parser.error('--seconds must be at least 5')
    names = {'niri': ['niri'], 'chrome': ['google-chrome', 'google-chrome-stable', 'chromium'],
             'node': ['node'], 'grim': ['grim']}
    commands = {key: executable(getattr(args, key), value) for key, value in names.items()}
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='niri-fullscreen-', dir=args.output_dir))
    runtime = run / 'runtime'
    runtime.mkdir(mode=0o700)
    (run / 'config.kdl').write_text('hotkey-overlay { skip-at-startup; }\n')
    html = '''<!doctype html><html><head><title>TITLE</title></head><body><script>
window.events=[];document.addEventListener('fullscreenchange',()=>events.push({at:Date.now(),fullscreen:!!document.fullscreenElement}));
function paint(){document.body.style.background=`hsl(${performance.now()/30} 50% 30%)`;requestAnimationFrame(paint);}paint();
</script></body></html>'''
    for title, file in [('FullscreenProbe', 'test.html'), ('HiddenProbe', 'hidden.html')]:
        (run / file).write_text(html.replace('TITLE', title))
    env = os.environ.copy()
    env.update(XDG_RUNTIME_DIR=str(runtime), NIRI_BACKEND='headless')
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'NIRI_SOCKET', 'LIBGL_ALWAYS_SOFTWARE'):
        env.pop(key, None)
    vendor = args.egl_vendor_file or next((str(path) for path in (
        Path('/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json'),
        Path('/usr/share/glvnd/egl_vendor.d/10_nvidia.json')) if path.is_file()), None)
    if vendor:
        env['__EGL_VENDOR_LIBRARY_FILENAMES'] = vendor
    procs, files, captures = [], [], []
    stop = threading.Event()
    capture_thread = None

    def spawn(command, process_env, filename):
        output = (run / filename).open('w')
        files.append(output)
        proc = subprocess.Popen(command, env=process_env, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=output, start_new_session=True)
        procs.append(proc)
        return proc

    def wait_for(callback, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = callback()
            except (OSError, json.JSONDecodeError):
                value = None
            if value:
                return value
            if any(proc.poll() is not None for proc in procs):
                raise RuntimeError('A diagnostic process exited during startup')
            time.sleep(.1)
        raise TimeoutError('Diagnostic process startup timed out')

    def capture(process_env):
        process_env = process_env.copy()
        process_env.pop('WAYLAND_DEBUG', None)
        with (run / 'capture.jsonl').open('w') as output:
            while not stop.is_set():
                started = time.time()
                try:
                    result = subprocess.run([commands['grim'], '-t', 'ppm', '-o', 'HEADLESS-1', '/dev/null'],
                                            env=process_env, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.PIPE, text=True, timeout=3)
                    record = {'at': started, 'exit': result.returncode, 'error': result.stderr[:500]}
                except subprocess.TimeoutExpired:
                    record = {'at': started, 'error': 'capture timed out'}
                captures.append(record)
                output.write(json.dumps(record) + '\n')
                output.flush()
                stop.wait(.1)

    try:
        spawn([commands['niri'], '-c', str(run / 'config.kdl')], env, 'niri.log')
        socket = wait_for(lambda: next(runtime.glob('niri.*.sock'), None))
        browser_env = env.copy()
        browser_env.pop('NIRI_BACKEND', None)
        browser_env.pop('__EGL_VENDOR_LIBRARY_FILENAMES', None)
        browser_env.update(WAYLAND_DISPLAY=socket.name.split('.')[1], WAYLAND_DEBUG='1', NIRI_SOCKET=str(socket))
        profile = run / 'profile'
        spawn([commands['chrome'], '--user-data-dir=' + str(profile), '--ozone-platform=wayland',
               '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
               '--password-store=basic', (run / 'test.html').as_uri()], browser_env, 'chrome.log')
        port_file = profile / 'DevToolsActivePort'
        wait_for(port_file.exists)
        port = port_file.read_text().splitlines()[0]
        wait_for(lambda: next((page for page in json.load(urllib.request.urlopen(
            'http://127.0.0.1:' + port + '/json/list')) if page['url'].endswith('/test.html')), None))
        if not args.no_capture:
            capture_thread = threading.Thread(target=capture, args=(browser_env,), daemon=True)
            capture_thread.start()
        result = subprocess.run([commands['node'], str(Path(__file__).with_suffix('.mjs')), port,
                                 str(run), str(args.seconds), str(not args.no_hidden_window).lower(),
                                 commands['niri']], env=browser_env, text=True, capture_output=True,
                                timeout=args.seconds + 35)
        (run / 'cdp.log').write_text(result.stdout + '\n' + result.stderr)
        if result.returncode:
            raise RuntimeError('CDP probe failed: ' + result.stderr.strip())
        probe = json.loads(result.stdout)
        (run / 'cdp.json').write_text(json.dumps(probe, indent=2))
    finally:
        stop.set()
        if capture_thread:
            capture_thread.join(timeout=4)
        for proc in reversed(procs):
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
        for output in files:
            output.close()
        print('Artifacts: ' + str(run), flush=True)

    counts, stable, transitions = parse_feedback((run / 'chrome.log').read_text(errors='replace'), probe)
    errors = []
    entered = any(event['fullscreen'] for event in probe['state']['events'])
    exited = any(not event['fullscreen'] for event in probe['state']['events'])
    if not entered:
        errors.append('The test page never entered fullscreen')
    if args.expect_exit:
        if not exited or probe['state']['fullscreen']:
            errors.append('Expected the baseline to leave fullscreen automatically')
    elif exited or not probe['state']['fullscreen']:
        errors.append('Fullscreen did not persist for the entire probe')
    if not args.no_capture and (not captures or any(record.get('exit') != 0 for record in captures)):
        errors.append('Capture failed or produced no successful attempts')
    gpu = probe['gpu']
    renderer = gpu.get('auxAttributes', {}).get('glRenderer', '')
    if gpu.get('featureStatus', {}).get('gpu_compositing') != 'enabled' or re.search(
            r'swiftshader|llvmpipe|softpipe|software', renderer, re.I):
        errors.append('Chrome used software/fallback graphics; this does not validate the affected GPU path')
    if not args.expect_exit:
        if not any('FullscreenProbe' in row['title'] and row.get('presented', 0) for row in stable):
            errors.append('Visible fullscreen window received no presented feedback')
        if not args.no_hidden_window:
            hidden = [row for row in stable if 'HiddenProbe' in row['title']]
            if not any('HiddenProbe' in window['title'] for window in probe['layouts']['fullscreen']):
                errors.append('The hidden-window control was not mapped during fullscreen')
            if any(row.get('presented', 0) for row in hidden):
                errors.append('An occluded window incorrectly received presented feedback')
    summary = {'passed': not errors, 'errors': errors, 'commands': commands, 'expect_exit': args.expect_exit,
               'seconds': args.seconds, 'capture_enabled': not args.no_capture, 'fullscreen_survived': probe['state']['fullscreen'],
               'events': probe['state']['events'], 'protocol_transitions': transitions,
               'feedback_during_probe': counts, 'feedback_after_first_second': stable,
               'capture_attempts': len(captures), 'capture_successes': sum(x.get('exit') == 0 for x in captures),
               'gpu': gpu, 'run': str(run)}
    (run / 'result.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
