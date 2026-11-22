import { expect } from 'e2e';
import { access, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { test, snapshot } from '../support/authority.js';
import { Client, contract } from '../support/factory.js';
import { git, githubOrigin, repository, workPackage } from '../support/worktree-git.js';
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
  // The assignment carries prior progress beyond the virtual document's 100-row cap.
  for (let index = 1; index <= 101; index++) await client.call('set_blocker', {
    work_package_id: wp, blocker_id: `prior-${index}`, active: true, summary: `Prior evidence ${index}`,
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


  // Agents that read only the text content still see the whole launch line.
  expect((await client.tool('dispatch_work_package', args)).result.content[0].text).toContain(JSON.stringify(dispatched.launch_line));
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

for (const mode of ['factory', 'local']) {
  test(`dispatch reuses the repaired worktree and its base in ${mode} mode`, async ({ processes }) => {
    const { root } = processes;
    const reposRoot = join(root, 'repos');
    await mkdir(reposRoot);
    const old = await repository(reposRoot, 'original');
    await githubOrigin(root, old, 'example/service');
    const factory = processes.factory('worktree-move', { env: mode === 'factory' ? { SYMPP_REPOS_ROOT: reposRoot } : {} });
    const architect = await factory.client();
    const request = await architect.request('Move factory checkout');
    const [wp] = await architect.addPackages([contract('Continue existing checkout')]);
    const original = await architect.call('dispatch_work_package', { work_package_id: wp, target_repo_root: old.checkout });

    const checkout = join(reposRoot, 'renamed');
    await rename(old.checkout, checkout);
    await githubOrigin(root, { ...old, checkout }, 'example/client');
    await git(root, checkout, 'worktree', 'repair', original.worktree.path);
    const move = await architect.call('move_work_request', {
      work_request_id: request, repo: 'example/client', base_branch: 'integration', rationale: 'The checkout moved with the repository.',
    });

    const args = { work_package_id: wp, target_repo_root: checkout };
    const relativeMirror = 'example/client.git';
    await git(root, checkout, 'clone', '--bare', old.origin, relativeMirror);
    await git(root, checkout, 'remote', 'set-url', 'origin', relativeMirror);
    const denied = await architect.call('dispatch_work_package', args);
    expect(denied.error?.reason).toBe(mode === 'factory' ? 'target_repo_root_required' : 'target_repo_root_scope_mismatch');
    expect(denied.launch_line).toBeUndefined();
    await githubOrigin(root, { ...old, checkout }, 'example/client');

    const replay = await architect.call('dispatch_work_package', args);
    expect(move.base_branch).toBe('integration');
    expect(replay.replay).toBe(true);
    expect(replay.worktree).toMatchObject({ path: original.worktree.path, base_branch: 'beta' });
    expect(await readFile(replay.assignment_file, 'utf8')).toContain('example/client');

    await git(root, checkout, 'config', 'protocol.https.allow', 'never');
    await git(root, checkout, 'remote', 'set-url', 'origin', 'https://fixture-user:fixture-password@github.com/example/client.git');
    const retry = await architect.call('dispatch_work_package', args);
    expect(retry.worktree).toMatchObject({ path: replay.worktree.path });
  });
}
