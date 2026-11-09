import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, access, rm } from 'node:fs/promises';
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
