import { expect } from 'e2e';
import { access, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { test, snapshot } from '../support/authority.js';
import { Client } from '../support/factory.js';
import { git, repository, workPackage } from '../support/worktree-git.js';
import { requestPath } from '../support/retention-history.js';

const exists = async (path: string) => access(path).then(() => true, () => false);

test('real worktree prepare and replay preserve branch scope, current remote bases and divergent local work', async ({ processes }) => {
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
  const args = { work_package_id: wp, target_repo_root: repo.checkout };
  await client.reject('prepare_work_package_worktree', { ...args, target_repo_root: foreign.checkout }, 'target_repo_root_scope_mismatch');
  await client.reject('prepare_work_package_worktree', { ...args, branch: 'feature/wrong' }, 'branch_scope_mismatch');
  const prepared = await client.call('prepare_work_package_worktree', args);
  const path = prepared.worktree.path;
  expect(prepared.worktree.status).toBe('prepared');
  expect(prepared.work_package.worktree_path).toBe(path);
  expect(await git(root, path, 'branch', '--show-current')).toBe('feature/owned');
  expect(await git(root, path, 'rev-parse', 'HEAD')).toBe(await git(root, repo.checkout, 'rev-parse', 'origin/beta'));
  expect(await git(root, path, 'rev-parse', 'HEAD')).toBe(current);
  expect((await client.call('prepare_work_package_worktree', args)).worktree.path).toBe(path);
  expect((await client.call('prepare_work_package_worktree', args)).worktree.status).toBe('already_prepared');
  expect(await readFile(join(foreign.checkout, 'README.md'), 'utf8')).toBe('Initial fixture content\n');
  const divergentWp = await workPackage(client, repo.origin, 'feature/divergent');
  const divergentArgs = { work_package_id: divergentWp, target_repo_root: repo.checkout };
  await git(root, repo.checkout, 'checkout', '-b', 'feature/divergent', 'origin/beta');
  await writeFile(join(repo.checkout, 'stale.txt'), 'Preserve divergent local work\n');
  await git(root, repo.checkout, 'add', 'stale.txt');
  await git(root, repo.checkout, 'commit', '-m', 'Local divergent work');
  const divergent = await git(root, repo.checkout, 'rev-parse', 'HEAD');
  await git(root, repo.checkout, 'checkout', 'beta');
  await client.reject('prepare_work_package_worktree', divergentArgs, 'stale_existing_branch');
  expect(await git(root, repo.checkout, 'rev-parse', 'feature/divergent')).toBe(divergent);
  const distinct: string[] = [];
  for (const branch of ['feature/a-b', 'feature-a/b']) {
    const id = await workPackage(client, repo.origin, branch);
    distinct.push((await client.call('prepare_work_package_worktree', { work_package_id: id, target_repo_root: repo.checkout })).worktree.path);
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
  const path = (await architect.call('prepare_work_package_worktree', args)).worktree.path;
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
