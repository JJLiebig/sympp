import test from 'node:test';
import assert from 'node:assert/strict';
import { chiefCheckouts, chiefFolders } from './mods/sympp/chief.js';

const factory = { machine: 'build', root: '/srv/ana/Code' };
const checkout = (folder, machine = null) => ({ folder, machine });

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
