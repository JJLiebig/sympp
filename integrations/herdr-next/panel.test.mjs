import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
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
  return { view, cx, finish: () => Promise.all(tasks.splice(0)) };
}

Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => null }, configurable: true });
const response = (url) => ({ ok: true, status: 200, url, json: async () => boardPayload() });

test('recreated panels and new tabs show the last successful board before a GET is due', async (t) => {
  const get = t.mock.method(globalThis, 'fetch', async (url) => response(url));
  const endpoint = 'http://127.0.0.1:4001';
  const first = open({ endpoint, role: 'panel' });
  assert.equal(first.view.net.data, null);
  await first.finish();
  await first.view.close();

  for (const props of [{ role: 'panel' }, { scope: { topic: 't-herdr' } }, { job: 'wr-pr' }, { studio: { job: 'wr-pr', pkg: 'wp-review' } }]) {
    // No explicit endpoint: these views use the connection published after the first read.
    const next = open(props);
    assert.ok(next.view.net.data.jobs.some((job) => job.id === 'wr-pr'));
    assert.equal(next.view.reading, false);
  }
  assert.equal(get.mock.callCount(), 1);

  const otherEndpoint = 'http://127.0.0.1:4002';
  const other = open({ endpoint: otherEndpoint });
  assert.equal(other.view.net.data, null, 'another factory has its own board');
  await other.finish();
  assert.ok(open({ endpoint: otherEndpoint, role: 'panel' }).view.net.data, 'a tab can warm the panel too');
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
});
