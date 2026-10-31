import test from 'node:test';
import assert from 'node:assert/strict';
import { scaleForSteam, scalePayload, scaleExpression, evaluate } from '../scripts/nixos/steam-display-scale.mjs';

const outputs = { LG: { logical: { scale: 1 } }, Moonlight: { logical: { scale: 1.75 } } };
const workspaces = [{ id: 1, output: 'LG' }, { id: 2, output: 'Moonlight' }];
const steam = { app_id: 'steam', title: 'Steam', workspace_id: 1 };

test('follows Steam across displays independently of focus and games', () => {
  const others = [
    { app_id: 'steam_app_123', title: 'Steam', workspace_id: 2, is_focused: true },
    { app_id: 'steam', title: 'Settings', workspace_id: 2, is_focused: true },
  ];
  assert.equal(scaleForSteam([...others, steam], workspaces, outputs).scale, 1);
  assert.equal(scaleForSteam([...others, { ...steam, workspace_id: 2 }], workspaces, outputs).scale, 1.75);
});

test('handles workspace evacuation and live output scale changes', () => {
  assert.equal(scaleForSteam([steam], [{ id: 1, output: 'Moonlight' }], outputs).scale, 1.75);
  assert.equal(scaleForSteam([steam], workspaces, { LG: { logical: { scale: 1.5 } } }).scale, 1.5);
  assert.equal(scaleForSteam([], workspaces, outputs), null);
  assert.equal(scaleForSteam([steam], [], outputs), null);
  assert.equal(scaleForSteam([steam], workspaces, { LG: { logical: { scale: NaN } } }), null);
});

test('respects Steam slider limits', () => {
  assert.equal(scaleForSteam([steam], workspaces, { LG: { logical: { scale: 3 } } }).scale, 2);
  assert.throws(() => scalePayload(NaN));
  assert.throws(() => scalePayload(2.1));
});

test('protobuf changes only the desktop accessibility scale field', () => {
  const bytes = Buffer.from(scalePayload(1.75), 'base64');
  let tag = 0, shift = 0, index = 0;
  do { tag |= (bytes[index] & 127) << shift; shift += 7; } while (bytes[index++] & 128);
  assert.equal(tag >>> 3, 26010);
  assert.equal(tag & 7, 5);
  assert.equal(bytes.readFloatLE(index), 1.75);
  assert.equal(bytes.length, index + 4);
});

test('uses Steam setting API only when current value differs', async () => {
  const calls = [];
  const expression = scaleExpression(1.75);
  const fn = new Function('window', 'SteamClient', `return ${expression}`);
  const api = { Settings: { SetSetting: value => calls.push(value) } };
  const window = { settingsStore: { clientSettings: { accessibility_desktop_ui_scale: 1.75 } } };
  assert.equal((await fn(window, api)).changed, false);
  assert.equal(calls.length, 0);
  window.settingsStore.clientSettings.accessibility_desktop_ui_scale = 1;
  assert.equal((await fn(window, api)).changed, true);
  assert.deepEqual(calls, [scalePayload(1.75)]);
});

test('rejects debugger targets outside the Steam loopback endpoint', () => {
  assert.throws(() => evaluate('ws://example.com:8080/', '1'));
  assert.throws(() => evaluate('ws://127.0.0.1:9222/', '1'));
});
