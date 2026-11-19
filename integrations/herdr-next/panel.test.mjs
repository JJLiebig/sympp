import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { boardPayload } from './fixture.mjs';

// Run the view's real init, timer and read paths without the native renderer.
const hostModules = {
  'gpui-kit': 'export class View {} export const div = null, svg = null, image = null;',
  'gpui-base': 'export const v_flex = null, h_flex = null, Button = null, Input = null, Textarea = null, InputState = null, TextareaState = null;',
  herdr: `
    const values = new Map();
    export const shared = (key) => values.get(key) ?? null;
    export const setShared = (key, value) => values.set(key, value);
    export const spaces = () => [], panes = () => [], terminals = () => [];
    export const window = () => ({ active: true });
    export const hc = async () => ({ stdout: '{}' });
    export const props = null, theme = null, focused = null, notify = null, run = null, exec = null,
      appHome = null, watchFolder = null, closeOverlay = null, openOverlay = null, knownAgents = null,
      machines = null, home = null, layout = null, settings = null;
  `,
};
const hooks = registerHooks({
  resolve(name, context, next) {
    if (!Object.hasOwn(hostModules, name)) return next(name, context);
    return { url: `data:text/javascript,${encodeURIComponent(hostModules[name])}`, shortCircuit: true };
  },
});
const { default: Lens } = await import('./mods/sympp/main.js');
hooks.deregister();

class BoardView extends Lens {
  input() {}
  sweep() {}
  holdLease() {}
}

function open(props) {
  const tasks = [];
  const cx = {
    timer: { every() {} },
    focus_handle() {},
    spawn: (task) => tasks.push(task(cx)),
    notify() {},
  };
  const view = new BoardView();
  view.init(props, cx);
  return { view, cx, async finish() {
    while (tasks.length) await Promise.all(tasks.splice(0));
  } };
}

Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => null }, configurable: true });
const response = (url) => ({ ok: true, status: 200, url, json: async () => boardPayload() });

test('recreated panels and new tabs show the last successful board before a GET is due', async (t) => {
  let refreshed = false;
  let switching;
  let switchedBeforeRead = false;
  const unreachable = 'http://127.0.0.1:4012';
  const get = t.mock.method(globalThis, 'fetch', async (url) => {
    if (new URL(url).origin === unreachable) {
      if (switching) switchedBeforeRead = switching.endpoint === unreachable && switching.net.data === null;
      return { ok: false, status: 503, url };
    }
    const result = response(url);
    const payload = await result.json();
    if (refreshed) payload.work_request_details[0].work_request.title = 'Renamed on the factory';
    return { ...result, json: async () => payload };
  });
  const endpoint = 'http://127.0.0.1:4001';
  const activeEndpoint = 'http://127.0.0.1:4011';
  const dir = await mkdtemp(join(tmpdir(), 'sympp-panel-runtime-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const runtime = join(dir, 'runtime.json');
  await writeFile(runtime, JSON.stringify({ backend: { url: activeEndpoint } }));
  const localPanel = { endpoint, role: 'panel', hosts: { local: { runtime } } };
  const first = open(localPanel);
  assert.equal(first.view.net.data, null);
  await first.finish();
  await first.view.close();

  for (const props of [
    { role: 'panel' }, { scope: { topic: 't-herdr' } }, { job: 'wr-pr' },
    { studio: { job: 'wr-pr', pkg: 'wp-review' } }, { endpoint: activeEndpoint },
  ]) {
    const next = open(props);
    await next.finish();
    assert.equal(next.view.endpoint, activeEndpoint);
    assert.ok(next.view.net.data.jobs.some((job) => job.id === 'wr-pr'));
    assert.equal(next.view.reading, false);
  }
  assert.equal(get.mock.callCount(), 1);

  refreshed = true;
  const tab = open({ endpoint: activeEndpoint });
  tab.view.retry(tab.cx);
  await tab.finish();
  for (const runtimeFile of [runtime, join(dir, 'other-runtime.json')]) {
    await writeFile(runtimeFile, JSON.stringify({ backend: { url: activeEndpoint } }));
    const next = open({ endpoint, role: 'panel', hosts: { local: { runtime: runtimeFile } } });
    await next.finish();
    assert.equal(next.view.net.data.jobs.find((job) => job.id === 'wr-pr').title, 'Renamed on the factory');
  }
  assert.equal(get.mock.callCount(), 2, 'an endpoint read warms both an established runtime and one opened for the first time');

  const otherEndpoint = 'http://127.0.0.1:4002';
  const other = open({ endpoint: otherEndpoint });
  assert.equal(other.view.net.data, null, 'another factory has its own board');
  await other.finish();
  assert.ok(open({ endpoint: otherEndpoint, role: 'panel' }).view.net.data, 'a tab can warm the panel too');

  await open(localPanel).finish();
  const inherited = open({ job: 'wr-pr' });
  await inherited.finish();
  assert.equal(inherited.view.endpoint, activeEndpoint, 'a warm configured panel publishes its own connection');

  const callsBeforeFallback = get.mock.callCount();
  const fallback = open({ endpoint: activeEndpoint, hosts: { local: { runtime: join(dir, 'missing.json') } } });
  await fallback.finish();
  assert.ok(fallback.view.net.data);
  assert.equal(get.mock.callCount(), callsBeforeFallback + 1, 'an unreadable runtime verifies its fallback with a GET');

  await writeFile(runtime, JSON.stringify({ backend: { url: unreachable } }));
  switching = inherited.view;
  inherited.view.retry(inherited.cx);
  await inherited.finish();
  assert.ok(switchedBeforeRead, 'the previous board is cleared before a GET at a different origin');
  switching = null;
  const moved = open(localPanel);
  assert.equal(moved.view.net.data, null, 'the previous origin’s controls wait for runtime resolution');
  await moved.finish();
  assert.equal(moved.view.endpoint, unreachable);
  assert.equal(moved.view.net.data, null, 'a changed origin cannot keep the previous endpoint’s board');
});

test('a failed refresh retains the board in the current view and the next one', async (t) => {
  let available = true;
  t.mock.method(globalThis, 'fetch', async (url) => {
    if (!available) throw new Error('offline');
    return response(url);
  });
  const props = { role: 'panel', endpoint: 'http://127.0.0.1:4003' };
  const first = open(props);
  await first.finish();
  const board = first.view.net.data;

  available = false;
  first.view.retry(first.cx);
  await first.finish();
  assert.ok(first.view.net.error);
  assert.equal(first.view.net.data, board);
  assert.equal(open(props).view.net.data, board);

  available = true;
  await first.view.send('/api/v1/sympp/herdr/asks/q1/answer', { answer: 'Ready' }, first.cx);
  const afterWrite = open(props);
  assert.equal(afterWrite.view.net.data, null, 'the pre-write read cannot restore old controls');
  await afterWrite.finish();
});
