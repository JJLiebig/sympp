import test from 'node:test';
import assert from 'node:assert/strict';
import { chiefCheckouts, chiefFolders, chiefSession, chiefTerminalName } from './mods/sympp/chief.js';

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
