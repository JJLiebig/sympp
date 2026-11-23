import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { CHIEF_SESSIONS, chiefCheckouts, chiefFolders, chiefSession, chiefTerminalName } from './mods/sympp/chief.js';

const hostModules = {
  'gpui-kit': 'export const div = null, svg = null, image = null;',
  'gpui-base': 'export const h_flex = null, v_flex = null, InputState = null, Input = null, Button = null;',
  herdr: `
    let host;
    export const useHost = (next) => { host = next; };
    export const exec = (...args) => host.exec(...args), hc = (args) => host.hc(args);
    export const terminals = () => host.terminals, spaces = () => host.spaces;
    export const shared = (key) => host.shared.get(key), setShared = (key, value) => host.shared.set(key, value);
    export const layout = () => null, props = null, theme = null, panes = null, run = null,
      closeOverlay = null, openOverlay = null, knownAgents = null, machines = null, home = null, settings = null;
  `,
};
const hooks = registerHooks({
  resolve(name, context, next) {
    if (!Object.hasOwn(hostModules, name)) return next(name, context);
    return { url: `data:text/javascript,${encodeURIComponent(hostModules[name])}`, shortCircuit: true };
  },
});
const { ChiefStart } = await import('./mods/sympp/chiefview.js');
const { useHost } = await import('herdr');
hooks.deregister();

test('chief terminal names fit Herdr even for long or punctuation-only topics', () => {
  for (const [topic, name] of [
    ['Nextide - Misc', 'nextide-misc-chief'],
    ['tools', 'tools-chief'],
    [' / QA___2026! ', 'qa-2026-chief'],
    ['— ⚙', 'topic-chief'],
    ['ABCDEFGHIJKLMNOPQRSTUVWXYZ again', 'abcdefghijklmnopqrstuvwxyz-chief'],
    ['abcdefghijklmnopqrstuvwxy more', 'abcdefghijklmnopqrstuvwxy-chief'],
  ]) {
    assert.equal(chiefTerminalName(topic), name);
  }
});

const shell = { key: 'shell', shell: true, agent: false };
const chiefLabels = { 'sympp.role': 'chief', 'sympp.domain': 'Tools' };

// Herdr rejects a name already in use on the machine and releases it once the holder ends.
async function replaceChief(terminals, { machine = null, last, closesSpace = false, hasShellChildren = false } = {}) {
  const prefix = machine ? `${machine}/` : '';
  const existingSpace = { id: `${prefix}chief-space`, name: 'Tools chief', machine };
  const shared = new Map([[CHIEF_SESSIONS, { tools: last }],
    ['desk.topics', { groups: [{ id: 'tools', name: 'Tools', spaces: [existingSpace.id] }] }]]);
  let spaceClosed = false;
  useHost({ terminals, shared, spaces: [existingSpace],
    async hc([command, address]) {
      if (command === 'kill') {
        // The name remains held until the close completes.
        await Promise.resolve();
        terminals.find((term) => term.address === address).state = 'finished';
        spaceClosed = closesSpace;
      }
      return { code: 0 };
    },
    async exec(app, [_do, command, json]) {
      if (app === 'pgrep') return { code: hasShellChildren ? 0 : 1 };
      if (app === 'powershell.exe') return { code: hasShellChildren ? 1 : 0 };
      const { terminal_name: name } = JSON.parse(json);
      if (command === 'tab.new' && spaceClosed) {
        return { code: 1, stdout: JSON.stringify({ error: `no space "${existingSpace.id}"` }) };
      }
      if (name && terminals.some((t) => t.state === 'live' && t.name === name && t.address === `${prefix}t1`)) {
        return { code: 1, stdout: JSON.stringify({ error: `cannot start a terminal: terminal.run: a live terminal is already named "${name}"` }) };
      }
      const terminal = `${prefix}t9`;
      terminals.push({ address: terminal, state: 'live', name });
      return { code: 0, stdout: JSON.stringify({ terminal, space: command === 'tab.new' ? existingSpace.id : `${prefix}new-space` }) };
    },
  });
  const start = Object.assign(Object.create(ChiefStart.prototype), { topic: 'tools', name: 'Tools' });
  await start.place(machine, '/work', ['codex'], { agent: 'codex', session: null, cwd: '/work' });
  return terminals.find((t) => t.address === shared.get(CHIEF_SESSIONS).tools.terminal);
}

test('relaunch closes an owned idle shell and gives the replacement the chief name', async () => {
  const holder = { address: 't1', name: 'tools-chief', state: 'live', program: shell, labels: chiefLabels,
    pid: 50, foreground: { name: 'pwsh.exe' } };
  const remote = { ...holder, address: 'factory/t1', labels: undefined, foreground: { name: 'bash' } };
  const replacement = await replaceChief([holder, remote], { machine: 'factory', last: { terminal: remote.address }, closesSpace: true });
  assert.equal(remote.state, 'finished');
  assert.equal(holder.state, 'live', 'the same name on a different machine is unaffected');
  assert.equal(replacement.name, 'tools-chief');

  const localReplacement = await replaceChief([holder]);
  assert.equal(holder.state, 'finished', 'the chief labels also establish ownership');
  assert.equal(localReplacement.name, 'tools-chief');
});

test('relaunch leaves a live, unowned or depended-on name holder in place', async () => {
  for (const [program, labels, dependent] of [
    [{ key: 'codex', agent: false }, chiefLabels, false],
    [{ key: 'agent', agent: true }, chiefLabels, false],
    [shell, { ...chiefLabels, 'sympp.domain': 'Other topic' }, false],
    [shell, chiefLabels, true],
  ]) {
    const holder = { address: 't1', name: 'tools-chief', state: 'live', program, labels };
    const child = { address: 't2', state: 'live', parent: 't1', die_with_parent: true };
    const replacement = await replaceChief(dependent ? [holder, child] : [holder]);
    assert.equal(holder.state, 'live');
    assert.equal(replacement.name, undefined);
  }
});

test('relaunch keeps a shell that still has child processes before Herdr reports them', async () => {
  for (const name of ['pwsh.exe', 'bash']) {
    const holder = { address: 't1', name: 'tools-chief', state: 'live', program: shell, labels: chiefLabels,
      pid: 50, foreground: { name } };
    const replacement = await replaceChief([holder], { hasShellChildren: true });
    assert.equal(holder.state, 'live');
    assert.equal(replacement.name, undefined);
  }
});

const factory = { machine: 'build', root: '/srv/ana/Code' };
const checkout = (folder, machine = null) => ({ folder, machine });

test('a fresh native session supersedes launch arguments only for its own live process', () => {
  const launched = '11111111-1111-4111-8111-111111111111';
  const active = '22222222-2222-4222-8222-222222222222';
  const term = { address: 't1', state: 'live', program: { key: 'codex', agent: true },
    foreground: { pid: 20, argv: ['codex', '--no-daemon', 'resume', launched] } };
  const reply = { state: 'live', foreground: { pid: 20 }, status: { app: 'codex' }, resume_session: active };
  const saved = chiefSession(term, chiefSession(term), reply);
  assert.equal(saved.session, active);
  assert.equal(chiefSession(term, saved).session, active, 'the following snapshot still has the original launch arguments');
  const cleared = chiefSession(term, saved, { ...reply, resume_session: null });
  assert.equal(chiefSession(term, cleared).session, null, 'a cleared native session does not fall back to the old launch');

  const replacement = { ...term, foreground: { pid: 21, argv: ['codex'] } };
  assert.equal(chiefSession(replacement, saved, reply).session, null, 'neither a late reply nor a remembered ID belongs to the new process');
});

test('an unreported Claude conversation cannot resume from a bridge ID or a fork source', () => {
  const source = '11111111-1111-4111-8111-111111111111';
  const term = { address: 't1', state: 'live', program: { key: 'claude', agent: true },
    labels: { 'sympp.session_id': '22222222-2222-4222-8222-222222222222' },
    foreground: { pid: 20, argv: ['claude', '--resume', source, '--fork-session'] } };
  assert.equal(chiefSession(term).session, null);
});

test('a resumed Codex chief takes its conversation from the session positional', () => {
  const id = '11111111-1111-4111-8111-111111111111';
  const term = { address: 't1', state: 'live', program: { key: 'codex', agent: false } };
  const record = (args) => chiefSession({ ...term, foreground: { pid: 20, argv: ['codex', ...args] } });
  assert.equal(record(['-m', 'gpt-6.2-sol', 'resume', id]).session, id);
  assert.equal(record(['--profile=chief', 'resume', '-c', 'model="gpt-6.2-sol"', '--', id]).session, id);
  assert.equal(record(['--profile', 'resume', id]).session, null, 'a profile name does not select a subcommand');
  assert.equal(record(['resume', '--last', id]).session, null, 'a UUID supplied with --last can be a prompt');
});

test('a desktop-only topic keeps its team folder on the factory machine', () => {
  const topic = [
    checkout('C:\\Code\\nextidemedia\\capture'),
    checkout('C:\\Code\\nextidemedia\\reports'),
  ];
  assert.deepEqual(chiefFolders(topic, topic, 'build', factory),
    ['/srv/ana/Code/nextidemedia', '/srv/ana/Code']);
  assert.deepEqual(chiefFolders(topic, topic, 'unknown', factory), []);
});

test('a top-level checkout brings the topic up to the repos root', () => {
  const topic = [
    checkout('D:\\work\\herdr-core'),
    checkout('D:\\work\\nextidemedia\\capture'),
  ];
  assert.deepEqual(chiefFolders(topic.slice(1), topic, 'build', factory),
    ['/srv/ana/Code/nextidemedia', '/srv/ana/Code']);
  assert.deepEqual(chiefFolders(topic, topic, 'build', factory), ['/srv/ana/Code']);
});

test('inferred roots inside different team folders map through the shared repos ancestor', () => {
  const topic = [
    checkout('/srv/ana/Code/engineering/build-tool', 'build'),
    checkout('C:\\Code\\nextidemedia\\capture'),
  ];
  assert.deepEqual(chiefFolders(topic, topic, 'build'), ['/srv/ana/Code', '/srv/ana/Code/engineering']);
});

test('the common holder includes a local checkout outside the reported factory root', () => {
  const topic = [
    checkout('/srv/ana/scratch/tool', 'build'),
    checkout('C:\\Code\\nextidemedia\\capture'),
  ];
  assert.equal(chiefFolders(topic, topic, 'build', factory)[0], '/srv/ana');
});

test('topic checkouts can meet at a filesystem root', () => {
  const linux = [
    checkout('/srv/ana/Code/capture', 'build'), checkout('/opt/projects/reports', 'build'),
  ];
  assert.equal(chiefFolders(linux, linux, 'build', factory)[0], '/');

  const windows = [checkout('C:\\herdr-core')];
  assert.deepEqual(chiefFolders(windows, windows, null), ['C:\\']);
});

test('live checkouts under the same team give the chief their holder when space folders are stale', async () => {
  const spaces = [
    { id: 'capture', folder: '', machine: 'build', tabs: [{ id: 'a', active: false }, { id: 'shell', active: true }] },
    { id: 'reports', folder: '/srv/ana', machine: 'build', tabs: [{ id: 'b', active: true }] },
    { id: 'notes', folder: '/srv/ana', machine: 'build', tabs: [{ id: 'c', active: true }] },
    { id: 'worktree', folder: '', machine: 'build', tabs: [{ id: 'd', active: true }] },
  ];
  const panes = [
    { tab: 'a', cwd: '/srv/ana/Code/nextidemedia/capture/src' },
    { tab: 'b', cwd: '/srv/ana/Code/nextidemedia/reports' },
    { tab: 'c', cwd: '/srv/ana' },
    { tab: 'd', cwd: '/srv/ana/Code/.worktrees/capture/fix' },
    { tab: 'shell', cwd: '/srv/ana' },
  ];
  const roots = new Map([
    [panes[0].cwd, '/srv/ana/Code/nextidemedia/capture'],
    [panes[1].cwd, panes[1].cwd],
    [panes[3].cwd, panes[3].cwd],
  ]);
  const topic = await chiefCheckouts(spaces, panes, async (cwd) => roots.get(cwd));
  assert.deepEqual(chiefFolders(topic, topic, 'build', factory),
    ['/srv/ana/Code/nextidemedia', '/srv/ana/Code']);
  assert.equal(chiefFolders(topic.filter((s) => s.id === 'capture'), topic, 'build', factory)[0], '/srv/ana/Code/nextidemedia');
  const all = [...topic, checkout('/opt/projects/utility', 'build')];
  assert.deepEqual(chiefFolders(topic, all, 'build'), ['/srv/ana/Code/nextidemedia']);
});

test('a busy desk retains the checkout that changes the common holder', async () => {
  const spaces = Array.from({ length: 17 }, (_, i) => ({
    id: `space-${i}`, machine: 'build', folder: '', tabs: [{ id: `tab-${i}`, active: true }],
  }));
  const panes = spaces.map((space, i) => ({
    tab: space.tabs[0].id, cwd: `/srv/ana/Code/${i === 16 ? 'other' : 'nextidemedia'}/repo-${i}`,
  }));
  let running = 0;
  const checkouts = await chiefCheckouts(spaces, panes, async (cwd) => {
    const busy = ++running > 16;
    await Promise.resolve();
    running--;
    return busy ? null : cwd;
  });
  assert.deepEqual(chiefFolders(checkouts, checkouts, 'build', factory), ['/srv/ana/Code']);
});

test('a stalled lookup keeps the checkout evidence already available', async () => {
  const spaces = [
    { id: 'capture', machine: 'desktop', folder: '', tabs: [{ id: 'a' }] },
    { id: 'reports', machine: 'desktop', folder: '', tabs: [{ id: 'b' }] },
    { id: 'tools', machine: 'build', folder: '', tabs: [{ id: 'c' }] },
  ];
  const panes = [
    { tab: 'a', cwd: 'C:\\Code\\nextidemedia\\capture' },
    { tab: 'b', cwd: 'C:\\Code\\nextidemedia\\reports' },
    { tab: 'c', cwd: '/srv/ana/Code/engineering/tools' },
  ];
  const stalled = new Promise(() => {});
  const checkouts = await chiefCheckouts(spaces, panes, async (cwd) => cwd === panes[1].cwd ? stalled : cwd,
    (on) => on === 'desktop' ? Promise.resolve() : null);
  assert.equal(chiefFolders(checkouts, checkouts, 'build', factory)[0], '/srv/ana/Code');
});
