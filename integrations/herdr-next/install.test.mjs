import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, access, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const install = (home, ...args) => spawnSync(process.execPath,
  [join(here, 'install.mjs'), '--home', home, ...args], { encoding: 'utf8', windowsHide: true });

test('rejects credentials, unknown flags and invalid open mode before changing a home', async t => {
  const root = await mkdtemp(join(tmpdir(), 'spp native invalid '));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, 'not-created');
  for (const args of [
    ['--endpoint', 'http://person:private@localhost:19998'],
    ['--endpoint', 'http://localhost:19998/sympp/board'],
    ['--endpoint', 'http://localhost:19998', '--opne', 'overview'],
    ['--endpoint', 'http://localhost:19998', '--open', 'bogus'],
    ['--endpoint', 'http://localhost:19998', '--mark', '../mods/sympp'],
    ['--lab', '--mark', 'a'],
    ['--chrome'],
    ['--auto-chrome'],
    ['--remove-chrome'],
  ]) {
    const result = install(home, ...args);
    assert.equal(result.status, 2, result.stdout + result.stderr);
    assert.doesNotMatch(result.stdout, /person:private/);
    await assert.rejects(access(home));
  }
});

test('installs into a home with spaces without replacing personal layout or topics', async t => {
  const home = await mkdtemp(join(tmpdir(), 'spp native install '));
  t.after(() => rm(home, { recursive: true, force: true }));
  await mkdir(join(home, 'layouts'));
  const layout = '{"id":"root","children":[{"content":{"terminal":"t5"}}]}\n';
  const shared = '{"desk.topics":{"groups":[{"id":"my-topic","spaces":["s1"]}]}}\n';
  await writeFile(join(home, 'layouts', 'personal.json'), layout);
  await writeFile(join(home, 'shared.json'), shared);
  await mkdir(join(home, 'tools'));
  await mkdir(join(home, 'data', 'sympp-requests'), { recursive: true });
  await writeFile(join(home, 'tools', 'sympp-http.cjs'), '// obsolete bridge');
  await writeFile(join(home, 'data', 'sympp-requests', 'old.json'), '{}');
  const desk = join(home, 'owned-desk');
  await mkdir(desk);
  await writeFile(join(desk, 'main.js'), '// personal desk');
  await mkdir(join(home, 'mods'), { recursive: true });
  for (const name of ['desk-tabs', 'desk-agents', 'desk-topics']) {
    await symlink(desk, join(home, 'mods', name), process.platform === 'win32' ? 'junction' : 'dir');
  }
  const backup = join(home, 'data', 'sympp-chrome', 'old.json');
  await mkdir(dirname(backup), { recursive: true });
  await writeFile(backup, 'old backup');
  const result = install(home, '--endpoint', 'http://127.0.0.1:19999');
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(await readFile(join(home, 'layouts', 'personal.json'), 'utf8'), layout);
  const published = JSON.parse(await readFile(join(home, 'shared.json'), 'utf8'));
  assert.equal(published['sympp.connection'].endpoint, 'http://127.0.0.1:19999');
  delete published['sympp.connection'];
  assert.deepEqual(published, JSON.parse(shared));
  assert.match(result.stdout, /19999/);
  await assert.rejects(access(join(home, 'tools', 'sympp-http.cjs')));
  await assert.rejects(access(join(home, 'data', 'sympp-requests')));
  await access(join(home, 'tools', 'sympp-herdr.js'));
  assert.deepEqual(await readFile(join(home, 'mods', 'sympp', 'mark.png')), await readFile(join(here, 'mods', 'sympp', 'mark.png')));
  assert.equal(install(home, '--endpoint', 'http://127.0.0.1:19999').status, 0);

  const edited = '// personal edit\n';
  await writeFile(join(home, 'mods', 'sympp', 'main.js'), edited);
  const beforeModel = await readFile(join(home, 'mods', 'sympp', 'model.js'), 'utf8');
  const refused = install(home, '--endpoint', 'http://127.0.0.1:19999');
  assert.equal(refused.status, 1);
  assert.match(refused.stdout, /no files were changed/);
  assert.equal(await readFile(join(home, 'mods', 'sympp', 'main.js'), 'utf8'), edited);
  assert.equal(await readFile(join(home, 'mods', 'sympp', 'model.js'), 'utf8'), beforeModel);
  assert.equal(install(home, '--endpoint', 'http://127.0.0.1:19999', '--replace').status, 0);
  assert.notEqual(await readFile(join(home, 'mods', 'sympp', 'main.js'), 'utf8'), edited);
  assert.equal(await readFile(join(desk, 'main.js'), 'utf8'), '// personal desk');
  assert.equal(await readFile(backup, 'utf8'), 'old backup');

});
