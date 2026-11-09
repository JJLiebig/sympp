// The UI studio shows only previews a worker published, and sweeps only its own preview copies.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as M from './mods/sympp/model.js';
import * as S from './mods/sympp/studio.js';
import { boardPayload } from './fixture.mjs';

const board = () => M.parseBoard(boardPayload());
const job = (id) => board().jobs.find((j) => j.id === id);
// A worker as `hc run` starts it from a dispatch's launch line, in Herdr's terminal list.
const worker = (address, labels = {}, extra = {}) => ({
  address, state: 'live', cwd: 'C:/code/wt/wp-build', labels: { 'sympp.role': 'worker', 'sympp.work_package_id': 'wp-build', ...labels }, ...extra,
});

test('only an http(s) preview a worker published is shown', () => {
  const url = (value) => S.previewUrlOf({ labels: { 'sympp.preview_url': value } });
  assert.equal(url(' http://localhost:5173/fresh?x=1 '), 'http://localhost:5173/fresh?x=1');
  assert.equal(url('https://preview.example.test'), 'https://preview.example.test');
  for (const value of ['', 'javascript:alert(1)', 'file:///C:/x.html', 'http://', 'http://a b', `https://a.test/${'x'.repeat(2100)}`]) assert.equal(url(value), null, value);
  assert.equal(S.previewUrlOf({ labels: {} }), null, 'no label means no preview yet');
});

test('only preview copies no open studio uses or shows are swept, never another mod', () => {
  const registry = { tb1: { job: 'j', pkg: 'a', dev: 'sympp-dev-a' }, closed: { job: 'j', pkg: 'b', dev: 'sympp-dev-b' } };
  const names = ['sympp', 'sympp-lab', 'desk-tabs', 'sympp-dev-a', 'sympp-dev-b', 'sympp-dev-c', 'sympp-dev-d'];
  assert.deepEqual(S.strayCopies(names, registry, ['tb1'], [{ pane: 'p', tab: 'x', mod: 'sympp-dev-d' }]), ['sympp-dev-b', 'sympp-dev-c']);
  assert.equal(S.devName('wp_7Z2/pf'), 'sympp-dev-wp_7z2-pf');
});

async function scratch(t) {
  const root = await mkdtemp(join(tmpdir(), 'spp preview '));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}
