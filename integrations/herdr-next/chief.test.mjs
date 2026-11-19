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

test('live checkouts under the same team give the chief their holder when space folders are stale', async () => {
  const spaces = [
    { id: 'capture', folder: '', machine: 'build', branch: 'main', tabs: [{ id: 'a', active: true }] },
    { id: 'reports', folder: '/srv/ana', machine: 'build', branch: 'main', tabs: [{ id: 'b', active: true }] },
    { id: 'notes', folder: '/srv/ana', machine: 'build', branch: null, tabs: [{ id: 'c', active: true }] },
    { id: 'worktree', folder: '', machine: 'build', branch: 'fix', tabs: [{ id: 'd', active: true }] },
  ];
  const panes = [
    { tab: 'a', cwd: '/srv/ana/Code/nextidemedia/capture/src', branch: 'main' },
    { tab: 'b', cwd: '/srv/ana/Code/nextidemedia/reports', branch: 'main' },
    { tab: 'c', cwd: '/srv/ana', branch: null },
    { tab: 'd', cwd: '/srv/ana/Code/.worktrees/capture/fix', branch: 'fix' },
  ];
  const roots = new Map([
    [panes[0].cwd, '/srv/ana/Code/nextidemedia/capture'],
    [panes[1].cwd, panes[1].cwd],
    [panes[3].cwd, panes[3].cwd],
  ]);
  const topic = await chiefCheckouts(spaces, panes, async (cwd) => roots.get(cwd));
  assert.deepEqual(chiefFolders(topic, topic, 'build', factory),
    ['/srv/ana/Code/nextidemedia', '/srv/ana/Code']);
  const all = [...topic, checkout('/opt/projects/utility', 'build')];
  assert.deepEqual(chiefFolders(topic, all, 'build'), ['/srv/ana/Code/nextidemedia']);
});
