import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { boardPayload, NOW } from './fixture.mjs';
import { withCurrentLanes } from './mods/sympp/model.js';

// Run the view's real init, timer and read paths without the native renderer.
const hostModules = {
  'gpui-kit': 'export class View {} export const div = null, svg = null, image = null;',
  'gpui-base': 'export const v_flex = null, h_flex = null, Button = null, Input = null, Textarea = null, InputState = null, TextareaState = null;',
  herdr: `
    const values = new Map();
    let homePath;
    export const shared = (key) => values.get(key) ?? null;
    export const setShared = (key, value) => values.set(key, value);
    export const setAppHome = (path) => { homePath = path; };
    export const appHome = () => homePath;
    export const spaces = () => [], panes = () => [], terminals = () => [];
    export const window = () => ({ active: true });
    export const hc = async () => ({ stdout: '{}' });
    export const props = null, theme = null, focused = null, notify = null, run = null, exec = null,
      watchFolder = null, closeOverlay = null, openOverlay = null, knownAgents = null,
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
const { setAppHome } = await import('herdr');
hooks.deregister();

class BoardView extends Lens {
  input() {}
  sweep() {}
  holdLease(...args) { if (this.enableLeases) super.holdLease(...args); }
}

let hostOwner = null;
function open(props, { leases = false } = {}) {
  const tasks = [];
  const view = new BoardView();
  view.enableLeases = leases;
  function call(task, owner) {
    const previous = hostOwner;
    hostOwner = owner;
    try { return task(cx); }
    finally { hostOwner = previous; }
  }
  const cx = {
    timer: { every() {}, after(_delay, task, options) {
      const owner = options?.owner === null ? null : view;
      tasks.push(Promise.resolve().then(() => owner?.closed ? undefined : call(task, owner)));
    } },
    focus_handle() {},
    spawn: (task) => tasks.push(call(task, view)),
    notify() {},
  };
  view.init(props, cx);
  return { view, cx, async finish() {
    while (tasks.length) await Promise.all(tasks.splice(0));
  } };
}

Object.defineProperty(globalThis, 'localStorage', { value: { getItem: () => null }, configurable: true });
const response = (url) => ({ ok: true, status: 200, url, json: async () => boardPayload() });
const jobTitle = (view) => view.net.data?.jobs.find((job) => job.id === 'wr-pr')?.title;
const openAsk = (view) => view.net.data?.jobs.find((job) => job.id === 'wr-pr')?.asks.some((ask) => ask.id === 'q1');
const answerPath = '/api/v1/sympp/herdr/asks/q1/answer';

test('a panel and job tab share a 200, a bodyless 304, and a change after the initiating panel closes', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: NOW });
  const day = 24 * 60 * 60 * 1000;
  const nearBoundary = (days) => new Date(NOW - days * day + 60_000).toISOString();
  const payload = { ...boardPayload(), etag: '"first"' };
  payload.work_request_details.push(
    { work_request: { id: 'landed', phase: 'done', inserted_at: nearBoundary(1) } },
    { work_request: { id: 'resting', phase: 'planned', inserted_at: nearBoundary(14) }, work_packages: [
      { id: 'finished', status: 'ended', delivery: { outcome: 'finished', recorded_at: nearBoundary(14) } },
    ] },
  );
  const gets = [], leases = [];
  let parses = 0, next = payload, hold = null;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (url.endsWith('/client-lease')) {
      leases.push(JSON.parse(options.body).action);
      return response(url);
    }
    const owner = hostOwner;
    const tag = options.headers['If-None-Match'];
    gets.push(tag);
    if (hold) {
      hold.started.resolve();
      await hold.release.promise;
      if (owner?.closed) throw new Error('Herdr dropped the fetch owned by the closed view');
    }
    if (tag === next.etag) return { ok: false, status: 304, url, json: async () => { parses++; throw new Error('304 has no JSON'); } };
    return { ...response(url), json: async () => { parses++; return next; } };
  });
  const endpoint = 'http://127.0.0.1:4006';
  const panel = open({ endpoint, role: 'panel' }, { leases: true });
  const tab = open({ endpoint, job: 'wr-pr' }, { leases: true });
  await Promise.all([panel.finish(), tab.finish()]);
  const board = tab.view.net.data;
  assert.equal(panel.view.net.data, board);
  const lane = (id) => withCurrentLanes(tab.view.net.data, Date.now()).jobs.find((job) => job.id === id).lane;
  assert.equal(lane('landed'), 'landed');
  assert.equal(lane('resting'), 'moving');

  t.mock.timers.tick(60_000);
  panel.view.tick(panel.cx);
  tab.view.tick(tab.cx);
  await Promise.all([panel.finish(), tab.finish()]);
  assert.deepEqual(gets, [undefined, '"first"']);
  assert.equal(parses, 1);
  assert.equal(tab.view.net.data, board, 'the parsed board survives a successful 304');
  assert.equal(tab.view.net.error, null);
  assert.equal(tab.view.net.receivedAt, NOW + 60_000);
  assert.equal(lane('landed'), 'settled');
  assert.equal(lane('resting'), 'dormant');
  assert.deepEqual(leases, ['attach', 'attach', 'heartbeat', 'heartbeat']);

  next = structuredClone(payload);
  next.etag = '"second"';
  next.work_request_details[0].work_request.title = 'Changed by the factory';
  hold = { started: Promise.withResolvers(), release: Promise.withResolvers() };
  t.mock.timers.tick(15_000);
  panel.view.tick(panel.cx);
  tab.view.tick(tab.cx);
  await hold.started.promise;
  await panel.view.close();
  hold.release.resolve();
  await Promise.all([panel.finish(), tab.finish()]);
  assert.deepEqual(gets, [undefined, '"first"', '"first"']);
  assert.equal(parses, 2);
  assert.equal(jobTitle(tab.view), 'Changed by the factory');
  assert.equal(panel.view.net.data, board, 'the closed panel never applies the late result');
  assert.deepEqual(leases, ['attach', 'attach', 'heartbeat', 'heartbeat', 'detach']);
});

test('a post-write read bypasses the older in-flight read and a 304 keeps an unconfirmed answer hidden', async (t) => {
  const initial = { ...boardPayload(), etag: '"unanswered"' };
  const oldRead = { started: Promise.withResolvers(), release: Promise.withResolvers() };
  const tags = [];
  let staleParses = 0;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (options.method === 'POST') return { ...response(url), json: async () => ({}) };
    tags.push(options.headers['If-None-Match']);
    if (tags.length === 1) return { ...response(url), json: async () => initial };
    if (tags.length === 2) {
      oldRead.started.resolve();
      await oldRead.release.promise;
      return { ...response(url), json: async () => { staleParses++; return initial; } };
    }
    if (tags.length === 3) return { ok: false, status: 304, url };
    const confirmed = structuredClone(initial);
    confirmed.etag = '"answered"';
    confirmed.work_request_details[0].asks = [];
    return { ...response(url), json: async () => confirmed };
  });
  const endpoint = 'http://127.0.0.1:4007';
  const panel = open({ endpoint, role: 'panel' });
  const tab = open({ endpoint, job: 'wr-pr' });
  await Promise.all([panel.finish(), tab.finish()]);
  assert.equal(openAsk(panel.view), true);
  panel.view.retry(panel.cx);
  await oldRead.started.promise;
  await panel.view.send(answerPath, { answer: 'Ready' }, panel.cx);
  assert.equal(openAsk(panel.view), false);
  panel.view.retry(panel.cx);
  tab.view.tick(tab.cx);
  await tab.finish();

  assert.deepEqual(tags, [undefined, '"unanswered"', '"unanswered"']);
  assert.equal(openAsk(tab.view), true, 'the 304 confirms the old server state');
  assert.equal(openAsk(panel.view), false, 'the panel keeps its unconfirmed action');
  assert.equal(panel.view.taken.length, 1);
  oldRead.release.resolve();
  await panel.finish();
  assert.equal(staleParses, 0, 'the pre-write response is ineligible even though it finished last');

  panel.view.retry(panel.cx);
  await panel.finish();
  tab.view.tick(tab.cx);
  await tab.finish();
  assert.equal(tags.length, 4, 'the tab also adopts a completed peer read');
  assert.equal(openAsk(tab.view), false);
  assert.equal(panel.view.taken.length, 0, 'the changed response confirmed the answer');
});

test('credential rotation starts a separate read and a refusal invalidates the authenticated board', async (t) => {
  const home = await mkdtemp(join(tmpdir(), 'sympp-panel-remote-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  setAppHome(home);
  const endpoint = 'http://127.0.0.1:4008';
  const config = join(home, 'sympp-remote.json');
  const configure = (token, origin = endpoint) => writeFile(config, JSON.stringify({ endpoint: origin, token }));
  const reads = [];
  let refused = false;
  const oldRead = { started: Promise.withResolvers(), release: Promise.withResolvers() };
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(options.method, undefined, 'a board action using replaced credentials stays local');
    const credential = options.headers.Authorization === 'Bearer sample-first' ? 'first'
      : options.headers.Authorization === 'Bearer sample-second' ? 'second' : 'local';
    reads.push([credential, options.headers['If-None-Match']]);
    if (credential === 'first' && reads.length === 3) {
      oldRead.started.resolve();
      await oldRead.release.promise;
    }
    if (refused && credential === 'second') return { ok: false, status: 401, url };
    const payload = { ...boardPayload(), etag: `"${credential}"` };
    payload.work_request_details[0].work_request.title = credential;
    return { ...response(url), json: async () => payload };
  });
  await open({ endpoint }).finish();
  await configure('sample-first');
  const panel = open({ endpoint, role: 'panel', remote: true });
  await panel.finish();
  assert.equal(jobTitle(panel.view), 'first');
  panel.view.retry(panel.cx);
  await oldRead.started.promise;

  await configure('sample-second');
  await assert.rejects(panel.view.send(answerPath, { answer: 'Ready' }, panel.cx), /Refresh the board/);
  const tab = open({ endpoint, job: 'wr-pr', remote: true });
  await tab.finish();
  assert.equal(jobTitle(tab.view), 'second');
  oldRead.release.resolve();
  await panel.finish();
  assert.deepEqual(reads, [['local', undefined], ['first', undefined], ['first', '"first"'], ['second', undefined]]);

  refused = true;
  tab.view.retry(tab.cx);
  await tab.finish();
  assert.match(tab.view.net.error, /401/);
  assert.equal(tab.view.net.data, null);
  refused = false;
  const reopened = open({ endpoint, job: 'wr-pr', remote: true });
  assert.equal(reopened.view.net.data, null);
  await reopened.finish();
  assert.deepEqual(reads.slice(-2), [['second', '"second"'], ['second', undefined]]);

  await configure('sample-second', 'http://127.0.0.1:4009');
  const calls = reads.length;
  reopened.view.retry(reopened.cx);
  await reopened.finish();
  assert.match(reopened.view.net.error, /server changed/);
  assert.equal(reopened.view.net.data, null);
  assert.equal(reads.length, calls, 'credentials never follow an endpoint change');
});

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

test('a changed runtime process at the same origin gets a cold read while an old response is still pending', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'sympp-panel-reconnect-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const runtime = join(dir, 'runtime.json');
  const endpoint = 'http://127.0.0.1:4013';
  const record = (pid) => writeFile(runtime, JSON.stringify({ backend: { url: endpoint, pid } }));
  await record(100);
  const oldRead = { started: Promise.withResolvers(), release: Promise.withResolvers() };
  const gets = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    gets.push(options.headers['If-None-Match']);
    const title = gets.length < 3 ? 'First factory' : 'Replacement factory';
    if (gets.length === 2) {
      oldRead.started.resolve();
      await oldRead.release.promise;
    }
    const payload = { ...boardPayload(), etag: '"previous"' };
    payload.work_request_details[0].work_request.title = title;
    return { ...response(url), json: async () => payload };
  });
  const panel = open({ endpoint, role: 'panel', hosts: { local: { runtime } } });
  await panel.finish();
  panel.view.retry(panel.cx);
  await oldRead.started.promise;

  await record(101);
  const tab = open({ endpoint, job: 'wr-pr', hosts: { local: { runtime } } });
  await tab.finish();
  oldRead.release.resolve();
  await panel.finish();
  assert.deepEqual(gets, [undefined, '"previous"', undefined]);
  assert.equal(jobTitle(tab.view), 'Replacement factory');
  const reopened = open({ endpoint, job: 'wr-pr' });
  await reopened.finish();
  assert.equal(jobTitle(reopened.view), 'Replacement factory');
  assert.equal(gets.length, 3, 'the late read cannot warm the replacement factory');
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

  const path = '/api/v1/sympp/herdr/asks/q1/answer';
  const answer = { answer: 'Ready' };
  await assert.rejects(first.view.send(path, answer, first.cx));
  const afterFailure = open(props);
  await afterFailure.finish();
  assert.equal(afterFailure.view.net.data, board, 'a failed write and refresh preserve the shared read');
  await assert.rejects(afterFailure.view.send(path, answer, afterFailure.cx), /Refresh the board/);

  available = true;
  const write = first.view.send(path, answer, first.cx);
  const whilePending = open(props);
  assert.equal(whilePending.view.net.data, board);
  assert.equal(whilePending.view.reading, false);
  await assert.rejects(whilePending.view.send(path, answer, whilePending.cx), /Refresh the board/);
  await write;
  await first.view.close();
  whilePending.view.tick(whilePending.cx);
  assert.equal(whilePending.view.reading, true);
  await whilePending.finish();
  assert.equal(whilePending.view.needsControlRead(), false);
});

test('folded tasks stay folded in the next view, and Collapse all covers tasks folded by neither', async (t) => {
  const stored = new Map();
  const before = globalThis.localStorage;
  Object.defineProperty(globalThis, 'localStorage', { value: { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value) }, configurable: true });
  t.after(() => Object.defineProperty(globalThis, 'localStorage', { value: before, configurable: true }));
  t.mock.method(globalThis, 'fetch', async (url) => response(url));
  const props = { role: 'panel', endpoint: 'http://127.0.0.1:4005' };
  const first = open(props);
  await first.finish();
  first.view.foldAll(true, first.cx);
  first.view.toggleFold('wr-pr', first.cx);
  const next = open(props);
  assert.equal(next.view.folded('wr-pr'), false);
  assert.equal(next.view.folded('wr-cross'), true);
  next.view.foldAll(false, next.cx);
  assert.equal(open(props).view.folded('wr-cross'), false);
});
