import { expect } from 'e2e';
import { contract } from '../support/factory.js';
import { head, pr, prUrl, progress, row, sync, test } from '../support/delivery.js';
import { git, githubOrigin, repository } from '../support/worktree-git.js';

const source = 'example/service';
const destination = 'example/client';
const canonicalDestination = 'Example/Client';
const renameUrl = (number: number) => `https://github.com/${canonicalDestination}/pull/${number}`;
const merged = { state: 'MERGED', mergedAt: '2026-11-17T21:11:14Z', mergeCommit: { oid: head('f') } };

test('moving a renamed repository keeps its attached PR and records the merge under the new name', async ({ delivery: { factory, provider, root } }) => {
  const architect = await factory.client();
  const outsider = await factory.client();
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const checkout = await repository(root, 'renamed');
  await githubOrigin(root, checkout, source);
  const request = await architect.request('Move renamed service', 'beta', checkout.checkout);
  const [ended, open, planned] = await architect.addPackages([
    contract('Earlier delivery'), contract('Tracked change'), contract('Same repo by name', { repo: source, base_branch: 'beta' }),
  ]);
  const move = { work_request_id: request, repo: ' git@github.com:example/client.git ', base_branch: 'integration', rationale: 'GitHub renamed the service repository.' };
  await githubOrigin(root, checkout, destination);
  await architect.reject('move_work_request', move, 'ambiguous_source_repository');
  await githubOrigin(root, checkout, source);
  for (const wp of [ended, open]) await architect.call('dispatch_work_package', { work_package_id: wp });
  provider.set(830, pr(830, head('a'), merged));
  await sync(architect, ended, 830, head('a'));
  provider.set(831, pr(831, head('b')));
  await sync(architect, open, 831, head('b'));

  await architect.call('record_decision', {
    work_request_id: request, source_type: 'architect', decision: 'Keep the current plan',
    rationale: 'The rename changes repository scope.', scope_impact: 'Delivery', created_by: architect.address,
  });
  const read = () => architect.call('read_work_request', { work_request_id: request, detail: 'full' });
  const original = await read();
  const endedDelivery = (await row(architect, request, ended)).delivery;
  const endedProgress = await progress(architect, ended);
  const openProgress = await progress(architect, open);

  provider.apiReplies.set(`repos/${source}`, { stdout: JSON.stringify({ id: 7301, full_name: canonicalDestination }), exitCode: 0 });
  provider.set(831, pr(831, head('b'), { url: renameUrl(831) }));
  await architect.reject('sync_pr', { work_package_id: open, url: renameUrl(831) }, 'repository_mismatch');

  await githubOrigin(root, checkout, destination);
  await outsider.reject('move_work_request', move, 'owned_by_other_terminal');
  expect(await chief.call('move_work_request', move)).toMatchObject({
    status: 'moved', repo: 'git@github.com:example/client.git', base_branch: 'integration', moved_work_package_count: 2,
  });
  // The original owner can still write and repeating the move adds no evidence.
  const moved = await read();
  expect(await architect.call('move_work_request', { ...move, repo: destination, base_branch: 'irrelevant' })).toMatchObject({
    status: 'unchanged', base_branch: 'integration', moved_work_package_count: 0,
  });
  expect(await read()).toEqual(moved);
  expect(moved.decision_log_entries).toEqual([...original.decision_log_entries, expect.objectContaining({
    source_id: 'move_work_request', decision: expect.stringContaining(`from ${checkout.checkout}`),
    rationale: move.rationale, created_by: chief.address,
  })]);
  expect(moved.decision_log_entries.at(-1).decision).toContain(destination);

  const inScope = async (repo: string) => (await architect.call('list_work_requests', { repo })).work_requests.map((work: any) => work.id);
  expect(await inScope(checkout.checkout)).not.toContain(request);
  expect(await inScope(destination)).toContain(request);
  const board = await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`);
  expect(board.work_request.repo).toBe('git@github.com:example/client.git');
  expect(board.decision_logs.find((decision: any) => decision.source_id === 'move_work_request').rationale).toBe(move.rationale);
  const tracked = moved.work_packages.find((work: any) => work.id === open);
  expect(tracked).toMatchObject({ id: open, repo: 'git@github.com:example/client.git', base_branch: 'beta', status: 'ready' });
  expect(moved.work_packages.find((work: any) => work.id === planned)).toMatchObject({
    repo: 'git@github.com:example/client.git', base_branch: 'integration',
  });
  expect(moved.work_packages.find((work: any) => work.id === ended)).toEqual(original.work_packages.find((work: any) => work.id === ended));
  expect((await row(architect, request, ended)).delivery).toEqual(endedDelivery);
  expect(await progress(architect, ended)).toEqual(endedProgress);
  expect(await progress(architect, open)).toEqual(expect.arrayContaining(openProgress));

  provider.set(831, pr(831, head('b'), { ...merged, url: renameUrl(831) }));
  expect((await architect.call('sync_pr', { work_package_id: open, url: renameUrl(831) })).pr_sync).toMatchObject({
    status: 'merged', pr_url: renameUrl(831), repository: canonicalDestination,
  });
  expect((await row(architect, request, open)).delivery).toMatchObject({
    outcome: 'pr_merged', pr_repository: canonicalDestination, merge_commit_sha: head('f'),
  });
  expect((await architect.call('sync_pr', { work_package_id: open })).pr_sync.status).toBe('already_merged');
});

test('moving imported work waits for source PRs and dispatches inherited scope from the destination', async ({ delivery: { factory, provider, root } }) => {
  const architect = await factory.client();
  const checkout = await repository(root, 'imported');
  const attachedCheckout = await repository(root, 'attached');
  await git(root, checkout.checkout, 'push', 'origin', 'beta:integration');
  await githubOrigin(root, checkout, source);
  await githubOrigin(root, attachedCheckout, source);
  const request = await architect.request('Move imported service');
  const [open, planned, alternateBase, otherRepo] = await architect.addPackages([
    contract('Source pull request', { repo: attachedCheckout.checkout, base_branch: 'beta' }),
    contract('Inherited scope'),
    contract('Release branch', { repo: checkout.checkout, base_branch: 'release' }),
    contract('Independent repository', { repo: 'example/other', base_branch: 'stable' }),
  ]);
  await architect.call('dispatch_work_package', { work_package_id: open });
  provider.set(832, pr(832, head('a')));
  await sync(architect, open, 832, head('a'));
  provider.apiReplies.set(`repos/${source}`, { stdout: JSON.stringify({ id: 7301, full_name: source }), exitCode: 0 });
  await githubOrigin(root, attachedCheckout, destination);

  const read = () => architect.call('read_work_request', { work_request_id: request, detail: 'full' });
  const before = await read();
  const move = { work_request_id: request, repo: destination, base_branch: 'integration', rationale: 'The service moved into the shared repository.' };
  await architect.reject('move_work_request', { ...move, base_branch: 'release candidate' }, 'invalid_base_branch');
  expect((await architect.reject('move_work_request', move, 'attached_pull_requests')).packages).toEqual([
    { work_package_id: open, pr_url: prUrl(832) },
  ]);
  expect(await read()).toEqual(before);

  await githubOrigin(root, attachedCheckout, source);
  provider.set(832, pr(832, head('a'), merged));
  await sync(architect, open, 832, head('a'));
  await architect.call('move_work_request', move);
  const after = await read();
  const scopes = Object.fromEntries(after.work_packages.map((work: any) => [work.id, [work.repo, work.base_branch]]));
  expect(scopes).toEqual({
    [open]: [attachedCheckout.checkout, 'beta'],
    [planned]: [destination, 'integration'],
    [alternateBase]: [destination, 'release'],
    [otherRepo]: ['example/other', 'stable'],
  });
  expect((await row(architect, request, open)).delivery.pr_repository).toBe(source);

  const dispatchArgs = { work_package_id: planned, target_repo_root: checkout.checkout };
  expect((await architect.call('dispatch_work_package', dispatchArgs)).error.reason).toBe('target_repo_root_scope_mismatch');
  await githubOrigin(root, checkout, destination);
  const dispatch = await architect.call('dispatch_work_package', dispatchArgs);
  expect(dispatch.worktree.base_branch).toBe('integration');
  expect(await git(root, dispatch.worktree.path, 'rev-parse', 'HEAD')).toBe(await git(root, checkout.checkout, 'rev-parse', 'origin/integration'));
});
