import { expect } from 'e2e';
import { access, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { test, snapshot } from '../support/authority.js';
import { Client } from '../support/factory.js';
import { git, repository, workPackage } from '../support/worktree-git.js';
import { requestPath } from '../support/retention-history.js';

const exists = async (path: string) => access(path).then(() => true, () => false);

test('dispatch hands off a real worktree, assignment and launch line, and a replay reuses the worktree and review id', async ({ processes }) => {
  const { root } = processes;
  const repo = await repository(root, 'source');
  const foreign = await repository(root, 'foreign');
  const updater = join(root, 'updater');
  await git(root, root, 'clone', '--branch', 'beta', repo.origin, updater);
  await git(root, repo.checkout, 'config', '--unset-all', 'remote.origin.fetch');
  const stale = await git(root, repo.checkout, 'rev-parse', 'origin/beta');
  await writeFile(join(updater, 'update.txt'), 'Remote base advanced\n');
  await git(root, updater, 'add', 'update.txt');
  await git(root, updater, 'commit', '-m', 'Advance remote base');
  await git(root, updater, 'push', 'origin', 'beta');
  const current = await git(root, updater, 'rev-parse', 'HEAD');
  expect(current).not.toBe(stale);
  const factory = processes.factory();
  const client = await factory.client();
  const wp = await workPackage(client, repo.origin, 'feature/owned');
  // The assignment carries prior evidence beyond the virtual document's 100-row cap.
  for (let index = 1; index <= 101; index++) await client.call('append_finding', {
    work_package_id: wp, title: `Prior finding ${index}`, body: `Prior evidence ${index}`, idempotency_key: `prior-${index}`,
  });
  const args = { work_package_id: wp, review_mode: 'fast', target_repo_root: repo.checkout };
  const refused = await client.call('dispatch_work_package', { ...args, target_repo_root: foreign.checkout });
  expect(refused.error.reason).toBe('target_repo_root_scope_mismatch');
  expect(refused.work_package.status).toBe('dispatched');
  const reviewId = refused.work_package.review_id;
  expect(reviewId).toMatch(/^rvw_[0-9a-f]{16}$/);

  const dispatched = await client.call('dispatch_work_package', args);
  const path = dispatched.worktree.path;
  expect(dispatched.replay).toBe(true);
  expect(dispatched.work_package.review_id).toBe(reviewId);
  expect(await git(root, path, 'branch', '--show-current')).toBe('feature/owned');
  expect(await git(root, path, 'rev-parse', 'HEAD')).toBe(await git(root, repo.checkout, 'rev-parse', 'origin/beta'));
  expect(await git(root, path, 'rev-parse', 'HEAD')).toBe(current);
  // The worker reads its assignment from the worktree's git dir, outside its diff.
  const file = dispatched.assignment_file;
  expect(dirname(file)).toBe(await git(root, path, 'rev-parse', '--absolute-git-dir'));
  expect(await git(root, path, 'status', '--porcelain')).toBe('');
  const assignment = await readFile(file, 'utf8');
  expect(assignment).toContain(`--id ${reviewId} --mode fast --cd ${path}`);
  for (const text of ['Prior evidence 1\n', 'Prior evidence 101', 'src/**', 'The agreed behavior is available.', 'Make no sympp MCP calls']) expect(assignment).toContain(text.trim());
  expect(dispatched.launch_line).toBe(`hc run --bg --on ${dispatched.worktree.machine} --cwd ${path} --name ${wp} --label sympp.role=worker `
    + `--label sympp.work_package_id=${wp} --label sympp.review_id=${reviewId} -- codex "Read ${file}"`);

  const replay = await client.call('dispatch_work_package', args);
  expect([replay.worktree.path, replay.work_package.review_id, replay.launch_line]).toEqual([path, reviewId, dispatched.launch_line]);
  await client.reject('dispatch_work_package', { ...args, review_mode: 'deep' }, 'review_mode_conflict');
  expect(await readFile(join(foreign.checkout, 'README.md'), 'utf8')).toBe('Initial fixture content\n');

  const divergentWp = await workPackage(client, repo.origin, 'feature/divergent');
  await git(root, repo.checkout, 'checkout', '-b', 'feature/divergent', 'origin/beta');
  await writeFile(join(repo.checkout, 'stale.txt'), 'Preserve divergent local work\n');
  await git(root, repo.checkout, 'add', 'stale.txt');
  await git(root, repo.checkout, 'commit', '-m', 'Local divergent work');
  const divergent = await git(root, repo.checkout, 'rev-parse', 'HEAD');
  await git(root, repo.checkout, 'checkout', 'beta');
  const diverged = await client.call('dispatch_work_package', { work_package_id: divergentWp, review_mode: 'none', target_repo_root: repo.checkout });
  expect(diverged.error.reason).toBe('stale_existing_branch');
  expect(await git(root, repo.checkout, 'rev-parse', 'feature/divergent')).toBe(divergent);
  const distinct: string[] = [];
  for (const branch of ['feature/a-b', 'feature-a/b']) {
    const id = await workPackage(client, repo.origin, branch);
    distinct.push((await client.call('dispatch_work_package', { work_package_id: id, target_repo_root: repo.checkout })).worktree.path);
  }
  expect(distinct[0]).not.toBe(distinct[1]);
  for (const owned of distinct) expect(await exists(owned)).toBe(true);
});

test('offline snapshot lifecycle changes leave copied live worktree paths and source history untouched', async ({ processes }) => {
  const { root } = processes;
  const repo = await repository(root, 'source');
  const source = processes.factory();
  const architect = await source.client();
  const wp = await workPackage(architect, repo.origin, 'feature/offline');
  const request = (await architect.call('list_work_requests')).work_requests[0].id;
  const args = { work_package_id: wp, target_repo_root: repo.checkout };
  const path = (await architect.call('dispatch_work_package', args)).worktree.path;
  await writeFile(join(path, 'keep.txt'), 'Source worktree content\n');
  await source.stop();
  const database = await snapshot(source);
  const offline = processes.factory('offline', { database, offline: true });
  const client = new Client(await offline.endpoint, offline.receipt);
  for (const [action, body] of [['complete', {}], ['archive', {}], ['restore', {}], ['delete', {}]] as const) {
    expect((await client.operator(`${requestPath(request)}/${action}`, body)).status).toBe(200);
    expect(await readFile(join(path, 'keep.txt'), 'utf8')).toBe('Source worktree content\n');
  }
  await offline.stop();
  const restarted = processes.factory();
  const original = await restarted.client();
  expect((await original.call('list_work_requests')).work_requests.map((row: any) => row.id)).toContain(request);
  expect(await readFile(join(path, 'keep.txt'), 'utf8')).toBe('Source worktree content\n');
});
