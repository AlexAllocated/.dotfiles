// Drive Steam's desktop accessibility slider from its main window's Niri output.
// This deliberately leaves X11/Wine DPI and game windows alone.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const run = promisify(execFile);
const endpoint = 'http://127.0.0.1:8080/json/list';

export function scaleForSteam(windows, workspaces, outputs) {
  const candidates = windows.filter(w => w.app_id === 'steam' && w.workspace_id != null);
  // Auxiliary dialogs and game windows must not choose the client's scale.
  const main = candidates.find(w => w.title === 'Steam');
  if (!main) return null;
  const workspace = workspaces.find(w => w.id === main.workspace_id);
  const scale = outputs[workspace?.output]?.logical?.scale;
  if (!Number.isFinite(scale) || scale <= 0) return null;
  return { output: workspace.output, requested: scale, scale: Math.max(0.5, Math.min(2, scale)) };
}

export function scalePayload(scale) {
  if (!Number.isFinite(scale) || scale < 0.5 || scale > 2) throw new Error('Invalid Steam scale');
  // CMsgClientSettings.accessibility_desktop_ui_scale: field 26010, wire type float.
  let tag = 26010 * 8 + 5;
  const bytes = [];
  while (tag > 127) {
    bytes.push((tag & 127) | 128);
    tag >>>= 7;
  }
  bytes.push(tag);
  const value = Buffer.alloc(4);
  value.writeFloatLE(scale);
  return Buffer.concat([Buffer.from(bytes), value]).toString('base64');
}

export function scaleExpression(scale) {
  const payload = scalePayload(scale);
  return `(async () => {
    const settings = window.settingsStore?.clientSettings;
    if (!settings || typeof SteamClient?.Settings?.SetSetting !== 'function')
      throw new Error('Steam desktop settings API is unavailable');
    const before = settings.accessibility_desktop_ui_scale ?? 1;
    if (Math.abs(before - ${scale}) < 0.001) return { before, changed: false };
    await SteamClient.Settings.SetSetting(${JSON.stringify(payload)});
    return { before, changed: true };
  })()`;
}

export function evaluate(url, expression) {
  // Never follow a target supplied by an unrelated host or a remote debugger.
  const address = new URL(url);
  if (address.protocol !== 'ws:' || address.hostname !== '127.0.0.1' || address.port !== '8080')
    throw new Error('Unexpected Steam debugger address');
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    let settled = false;
    const timer = setTimeout(() => finish(new Error('Steam debugger timed out')), 3000);
    function finish(error, value) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.close();
      error ? reject(error) : resolve(value);
    }
    socket.onopen = () => socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: {
      expression, returnByValue: true, awaitPromise: true,
    } }));
    socket.onerror = () => finish(new Error('Steam debugger connection failed'));
    socket.onclose = () => finish(new Error('Steam debugger closed'));
    socket.onmessage = event => {
      const message = JSON.parse(event.data);
      if (message.id !== 1) return;
      if (message.error || message.result?.exceptionDetails)
        finish(new Error('Steam desktop scaling API failed'));
      else finish(null, message.result?.result?.value);
    };
  });
}

export async function applyScale(scale) {
  const response = await fetch(endpoint, { signal: AbortSignal.timeout(3000) });
  if (!response.ok) throw new Error('Steam debugger is unavailable');
  const targets = await response.json();
  const target = targets.find(t => t.title === 'SharedJSContext'
    && new URL(t.url).hostname === 'steamloopback.host');
  if (!target) throw new Error('Steam shared settings context is unavailable');
  return evaluate(target.webSocketDebuggerUrl, scaleExpression(scale));
}

async function niri(command) {
  const { stdout } = await run('niri', ['msg', '--json', command], { timeout: 3000 });
  return JSON.parse(stdout);
}

async function main() {
  let previous = null;
  let lastError = null;
  for (;;) {
    try {
      const [windows, workspaces, outputs] = await Promise.all(
        ['windows', 'workspaces', 'outputs'].map(niri));
      const desired = scaleForSteam(windows, workspaces, outputs);
      if (desired) {
        const result = await applyScale(desired.scale);
        const key = JSON.stringify(desired);
        if (key !== previous || result.changed)
          console.log(`Steam UI: ${desired.scale * 100}% on ${desired.output} (Niri ${desired.requested * 100}%)`);
        previous = key;
      } else previous = null;
      lastError = null;
    } catch (error) {
      if (error.message !== lastError) console.error(`Waiting for Steam/Niri: ${error.message}`);
      lastError = error.message;
    }
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main();
