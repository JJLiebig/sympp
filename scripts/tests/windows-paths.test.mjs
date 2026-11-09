import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { windowsJobs } from '../ci/windows-paths.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/make-all.yml', import.meta.url), 'utf8');
const gate = workflow.split("node --input-type=module <<'NODE'\n")[1].split('\n          NODE')[0];

test('PR selection covers Windows consumers and leaves ordinary source/docs on Linux', () => {
  for (const path of ['docs/testing.md', 'README.md', 'elixir/lib/example.ex', 'elixir/test/example_test.exs']) {
    assert.deepEqual(windowsJobs('pull_request', [path]), { runtime: false, frontend: false }, path);
  }
  for (const path of ['packages/sympp/scripts/start.js', 'skills/sympp/scripts/start.js',
    'scripts/package-portable-skills.mjs', 'nested/new.PS1', 'elixir/rel/env.bat.eex',
    'elixir/config/runtime.exs', 'elixir/mix.lock', 'elixir/priv/symphony_plus_plus/mcp_contract.json',
    'tests/support/installed-report.ts', 'e2e.config.ts']) {
    assert.deepEqual(windowsJobs('pull_request', [path]), { runtime: true, frontend: false }, path);
  }
  for (const path of ['elixir/lib/symphony_elixir/shell.ex',
    'elixir/lib/symphony_elixir/symphony_plus_plus/mcp/client_leases.ex',
    'elixir/lib/mix/tasks/workspace.before_remove.ex']) {
    assert.deepEqual(windowsJobs('pull_request', [path]), { runtime: true, frontend: false }, path);
  }
  for (const path of ['elixir/assets/src/main.tsx', 'elixir/assets/package-lock.json',
    'integrations/herdr-next/install.mjs', 'packages/sympp/herdr/dist/sympp-herdr.mjs',
    'elixir/mise.toml', 'package-lock.json', '.github/workflows/make-all.yml']) {
    assert.deepEqual(windowsJobs('pull_request', [path]), { runtime: true, frontend: true }, path);
  }
  for (const event of ['push', 'workflow_dispatch']) {
    assert.deepEqual(windowsJobs(event, ['docs/testing.md']), { runtime: true, frontend: true });
  }
});

test('actual gate accepts intentional skips and refuses failed/cancelled/missing qualifications', () => {
  const jobs = ['windows-paths', 'browser-native-acceptance', 'windows-frontend', 'native-acceptance',
    'portable-skills', 'offline-acceptance', 'single-gates', 'frontend'];
  const results = Object.fromEntries(jobs.map(job => [job, { result: 'success' }]));
  const run = value => spawnSync(process.execPath, ['--input-type=module', '-e', gate], {
    env: { ...process.env, REQUIRED_RESULTS: JSON.stringify(value) }, encoding: 'utf8',
  }).status;
  assert.equal(run(results), 0);
  for (const needed of ['true', 'false', undefined]) {
    results['windows-paths'] = { result: 'success', outputs: { frontend: needed, runtime: needed } };
    for (const job of ['windows-frontend', 'portable-skills']) {
      for (const status of ['skipped', 'failure', 'cancelled', undefined]) {
        results[job] = { result: status };
        assert.equal(run(results) === 0, status === 'skipped' && needed === 'false', `${job}/${needed}/${status}`);
      }
      results[job] = { result: 'success' };
    }
  }
  results['windows-frontend'] = { result: 'skipped' };
  for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
    results['windows-paths'] = { result: status, outputs: { frontend: 'false' } };
    assert.notEqual(run(results), 0);
  }
  results['windows-paths'] = { result: 'success', outputs: { frontend: 'false' } };
  for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
    results['native-acceptance'] = { result: status };
    assert.notEqual(run(results), 0);
  }
});

test('Git selection includes renamed-away paths and excludes base-only changes', () => {
  const root = mkdtempSync(join(tmpdir(), 'sympp-ci-paths-'));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  try {
    git('init', '-q');
    git('config', 'user.name', 'CI test');
    git('config', 'user.email', 'ci@example.invalid');
    writeFileSync(join(root, 'old.ps1'), 'launcher');
    git('add', '.');
    git('commit', '-qm', 'base');
    const base = git('rev-parse', 'HEAD');
    git('mv', 'old.ps1', 'notes.md');
    git('commit', '-qm', 'rename launcher');
    const head = git('rev-parse', 'HEAD');
    git('checkout', '-q', '--detach', base);
    writeFileSync(join(root, 'base-only.ps1'), 'base');
    git('add', '.');
    git('commit', '-qm', 'base advanced');
    const output = join(root, 'output');
    const script = new URL('../ci/windows-paths.mjs', import.meta.url);
    execFileSync(process.execPath, [script.pathname], { cwd: root, env: { ...process.env,
      GITHUB_EVENT_NAME: 'pull_request', PR_BASE_SHA: git('rev-parse', 'HEAD'), PR_HEAD_SHA: head,
      GITHUB_OUTPUT: output } });
    assert.equal(readFileSync(output, 'utf8'), 'runtime=true\nfrontend=false\n');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
