import { expect } from 'e2e';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { contract } from '../support/factory.js';
import { close, head, installReviewSuite, pr, prUrl, row, sync, test } from '../support/delivery.js';

test('deployment observations cover every delivered revision and preserve completion through rollback and unavailable history', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Deployment truth');
  const ids = (await architect.addPackages([contract('First revision'), contract('Second revision')]));
  const configRoot = join(factory.home, '.agents', 'splusplus');
  await mkdir(configRoot, { recursive: true });
  const configure = (workflow: string) => writeFile(join(configRoot, 'operator-board.json'), JSON.stringify({
    repos: { 'example/service': { deploy_workflows: { dev: workflow } } },
  }));
  const api = (path: string, value: object, exitCode = 0) => provider.apiReplies.set(path, { stdout: JSON.stringify(value), exitCode });
  api('repos/example/service', { default_branch: 'trunk' });
  const hydrated = async () => {
    const response = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
    return response.work_request_details.find((detail: any) => detail.work_request.id === request).work_request;
  };
  await configure('unfinished.yml');
  expect((await hydrated()).deployments['example/service'].dev.reason).toBe('unfinished');
  // An open ask does not hold back delivered work.
  const ask = (await architect.call('ask', { work_request_id: request, question: 'Has the delivered scope answered the remaining operator choice?' })).ask.id;
  for (const [index, wp] of ids.entries()) {
    await architect.call('dispatch_work_package', { work_package_id: wp });
    const number = 710 + index;
    const sha = head(index === 0 ? 'a' : 'b');
    provider.set(number, pr(number, sha, { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: sha } }));
    await sync(architect, wp, number, sha);
  }
  const completed = (await hydrated()).completed_at;
  expect(completed).toBeTruthy();
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.phase).toBe('done');
  await architect.call('resolve_ask', { ask_id: ask, to: 'withdrawn' });
  expect((await hydrated()).completed_at).toBe(completed);
  const run = (id: number, sha: string, conclusion: string | null, hour = 11, patch: object = {}) => ({
    id, head_sha: sha, conclusion, status: 'completed', event: 'push',
    updated_at: `2026-10-10T${hour}:00:00Z`, repository: { full_name: 'example/service' },
    head_repository: { full_name: 'example/service' }, ...patch,
  });
  for (const sha of ['a', 'b']) {
    api(`repos/example/service/compare/${head(sha)}...${head('c')}?per_page=1`, { status: 'ahead' });
    api(`repos/example/service/compare/${head(sha)}...${head('e')}?per_page=1`, { status: 'ahead' });
  }
  api(`repos/example/service/compare/${head('a')}...${head('d')}?per_page=1`, { status: 'ahead' });
  api(`repos/example/service/compare/${head('b')}...${head('d')}?per_page=1`, { status: 'diverged' });
  const observe = async (workflow: string, runs: object[], total = runs.length) => {
    api(`repos/example/service/actions/workflows/${workflow}/runs?per_page=100&page=1`, { workflow_runs: runs, total_count: total });
    await configure(workflow);
    const current = await hydrated();
    expect(current.completed_at).toBe(completed);
    expect(current.default_branch).toBe('trunk');
    return current.deployments['example/service'].dev;
  };
  const deployed = await observe('deployed.yml', [run(1, head('c'), 'success')]);
  expect(deployed.status).toBe('ok');
  expect(deployed.revision).toBe(head('c'));
  expect((await observe('missing-revision.yml', [run(2, head('d'), 'success')])).status).toBe('pending');
  const old = run(3, head('c'), 'success');
  const rollback = run(4, head('d'), 'success', 12);
  const failed = run(5, head('e'), 'failure', 13);
  expect((await observe('rollback.yml', [old, rollback, failed])).status).toBe('failed');
  expect((await observe('failed-after-success.yml', [failed, old])).status).toBe('ok');
  const retry = run(1, head('d'), 'success', 14, { run_attempt: 2 });
  const foreign = run(6, head('c'), 'success', 15, { head_repository: { full_name: 'outsider/service' } });
  const pullRequest = run(7, head('c'), 'success', 16, { event: 'pull_request' });
  expect((await observe('retry.yml', [pullRequest, foreign, old, retry])).status).toBe('pending');
  const pages = Array.from({ length: 100 }, (_, index) => run(index + 20, head('c'), 'success'));
  api('repos/example/service/actions/workflows/pages.yml/runs?per_page=100&page=2', { workflow_runs: [retry], total_count: 101 });
  expect((await observe('pages.yml', pages, 101)).status).toBe('pending');
  const calls = provider.calls.filter((call) => call.argv[0] === 'api').length;
  await hydrated();
  expect(provider.calls.filter((call) => call.argv[0] === 'api')).toHaveLength(calls);
  for (const [workflow, page] of [
    ['duplicate-page.yml', { workflow_runs: [pages[0]], total_count: 101 }],
    ['changing-total.yml', { workflow_runs: [retry], total_count: 102 }],
    ['incomplete.yml', { workflow_runs: [], total_count: 101 }],
  ] as const) {
    api(`repos/example/service/actions/workflows/${workflow}/runs?per_page=100&page=2`, page);
    expect((await observe(workflow, pages, 101)).reason).toBe('unavailable');
  }
  await configure('permission.yml');
  api('repos/example/service/actions/workflows/permission.yml/runs?per_page=100&page=1', { message: 'Unavailable synthetic provider' }, 1);
  expect((await hydrated()).deployments['example/service'].dev.reason).toBe('unavailable');
  expect((await observe('missing-comparison.yml', [run(8, head('f'), 'success')])).reason).toBe('unavailable');
});

test('separate repository deployments preserve live attempt time and no-PR work has no invented revision', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Independent deployments');
  const [service, client, noPr] = (await architect.addPackages([
    contract('Service deployment'), contract('Client deployment', { repo: 'example/client', base_branch: 'integration' }),
    contract('Accepted investigation', { kind: 'investigation' }),
  ]));
  for (const wp of [service, client, noPr]) await architect.call('dispatch_work_package', { work_package_id: wp });
  await close(architect, noPr);
  for (const [wp, number, repo, base] of [[service, 720, 'example/service', 'beta'], [client, 721, 'example/client', 'integration']] as const) {
    provider.set(number, pr(number, head('a'), { url: `https://github.com/${repo}/pull/${number}`, baseRefName: base,
      state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('a') } }));
    await architect.call('sync_pr', { work_package_id: wp, url: `https://github.com/${repo}/pull/${number}`, head_sha: head('a') });
  }
  const configRoot = join(factory.home, '.agents', 'splusplus');
  await mkdir(configRoot, { recursive: true });
  await writeFile(join(configRoot, 'operator-board.json'), JSON.stringify({ repos: {
    'example/service': { deploy_workflows: { dev: 'service.yml' } }, 'example/client': { deploy_workflows: { prod: 'client.yml' } },
  } }));
  for (const [repo, workflow, live] of [['example/service', 'service.yml', false], ['example/client', 'client.yml', true]] as const) {
    provider.apiReplies.set(`repos/${repo}`, { stdout: JSON.stringify({ default_branch: 'trunk' }), exitCode: 0 });
    provider.apiReplies.set(`repos/${repo}/actions/workflows/${workflow}/runs?per_page=100&page=1`, { exitCode: 0, stdout: JSON.stringify({ total_count: 1, workflow_runs: [{
      id: 1, head_sha: head('a'), event: 'push', status: live ? 'in_progress' : 'completed', conclusion: live ? null : 'success',
      updated_at: '2026-10-10T11:00:00Z', run_started_at: '2026-10-10T10:30:00Z', repository: { full_name: repo }, head_repository: { full_name: repo },
    }] }) });
  }
  const response = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  const current = response.work_request_details.find((detail: any) => detail.work_request.id === request).work_request;
  expect(current.completed_at).toBeTruthy();
  expect(current.deployments['example/service'].dev.status).toBe('ok');
  expect(current.deployments['example/client'].prod.status).toBe('pending');
  expect(current.deployments['example/client'].prod.at).toBe('2026-10-10T10:30:00Z');
  expect(current.deployments['example/client'].dev).toBeUndefined();
  const onlyNoPr = await architect.request('No deployed revision');
  const [investigation] = (await architect.addPackages([contract('No code delivery', { kind: 'investigation' })]));
  await architect.call('dispatch_work_package', { work_package_id: investigation });
  await close(architect, investigation);
  const final = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  expect(final.work_request_details.find((detail: any) => detail.work_request.id === onlyNoPr).work_request.deployments).toBeUndefined();
});

test('installed Review Suite state for the review id gates qualification', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Reviewed delivery');
  const [wp] = (await architect.addPackages([contract('Reviewed change')]));
  const reviewId = (await architect.call('dispatch_work_package', { work_package_id: wp, review_mode: 'fast' })).work_package.review_id;
  expect(reviewId).toMatch(/^rvw_[0-9a-f]{16}$/);
  provider.set(110, pr(110, head('a')));

  // No provider installed: the review state is unknown and names where to look.
  const unknown = await architect.call('sync_pr', { work_package_id: wp, url: prUrl(110) });
  expect(unknown.pr_sync.readiness_reasons).toContain('review_unknown');
  expect(unknown.pr_sync.next_action).toMatch(/^review state unknown: check /);

  const review = await installReviewSuite(factory.home);
  await review.answer({ error: `unknown review cycle id: ${reviewId}`, status: 'usage_error' }, 2);
  const notStarted = await architect.call('sync_pr', { work_package_id: wp, url: prUrl(110) });
  expect(notStarted.pr_sync.readiness_reasons).toContain('review_not_done');
  expect((await row(architect, request, wp)).raw_status).toBe('dispatched');

  await review.answer({ review: reviewId, done: true, status: 'done', head: head('b'), progress: '1/1' });
  const otherHead = await architect.call('sync_pr', { work_package_id: wp, url: prUrl(110) });
  expect(otherHead.pr_sync.readiness_reasons).toContain('review_not_done');

  await review.answer({ review: reviewId, done: true, status: 'done', head: head('a'), progress: '1/1' });
  const done = await architect.call('sync_pr', { work_package_id: wp, url: prUrl(110) });
  expect(done.work_package.status).toBe('ready');
  for (const argv of await review.calls()) expect(argv).toEqual(['--id', reviewId, '--show-status', '--json']);
});

test('ordinary PR handoff observes pending qualification then reconciles an exact external merge once', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Qualified delivery');
  const [wp] = (await architect.addPackages([contract('Service change')]));
  const dispatch = await architect.call('dispatch_work_package', { work_package_id: wp, future_field: 'ignored' });
  expect(dispatch.work_package.status).toBe('dispatched');
  const detail = () => architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`);
  const completion = async () => (await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at;
  expect(await completion()).toBeNull();

  provider.set(101, pr(101, head('a'), {
    statusCheckRollup: [{ status: 'IN_PROGRESS', conclusion: null }], reviewDecision: 'REVIEW_REQUIRED', mergeStateStatus: 'BLOCKED',
  }));
  const tools = await architect.rpc('tools/list', {});
  const syncSchema = tools.result.tools.find((tool: any) => tool.name === 'sync_pr').inputSchema;
  expect(syncSchema.properties.head_sha.type).toBe('string');
  expect(syncSchema.required).not.toContain('head_sha');
  await architect.call('sync_pr', { work_package_id: wp, url: prUrl(101) });
  const waiting = await detail();
  expect(waiting.metadata.pr.check_summary.status).toBe('pending');
  expect(waiting.metadata.pr.review_state.status).toBe('review_required');
  expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  expect(await completion()).toBeNull();
  // Pending CI keeps the package dispatched until its checks pass.
  const pending = await row(architect, request, wp);
  expect(pending.raw_status).toBe('dispatched');
  expect(pending.merge_eligibility.next_action).toBe('wait');

  provider.set(101, pr(101, head('a')));
  await architect.call('sync_pr', { work_package_id: wp, number: 101, repository: 'example/service' });
  const qualified = await detail();
  expect(qualified.metadata.pr.check_summary.status).toBe('passing');
  expect(qualified.metadata.pr.review_state.status).toBe('approved');
  expect(qualified.metadata.pr.head_sha).toBe(head('a'));
  expect(qualified.metadata.pr.head_changed_at).toBe(waiting.metadata.pr.head_changed_at);
  expect(qualified.metadata.pr.checks_changed_at).not.toBe(waiting.metadata.pr.checks_changed_at);
  await sync(architect, wp, 101, head('a'));
  const repeated = await detail();
  expect(repeated.metadata.pr.head_changed_at).toBe(qualified.metadata.pr.head_changed_at);
  expect(repeated.metadata.pr.checks_changed_at).toBe(qualified.metadata.pr.checks_changed_at);
  const ready = await row(architect, request, wp);
  expect(ready.raw_status).toBe('ready');
  expect(ready.merge_eligibility.eligible).toBe(true);
  expect(await completion()).toBeNull();

  const mergeTime = new Date().toISOString();
  provider.set(101, pr(101, head('a'), { state: 'MERGED', mergedAt: mergeTime, mergeCommit: { oid: head('f') } }));
  await architect.call('sync_pr', { work_package_id: wp, url: prUrl(101) });
  const delivered = await row(architect, request, wp);
  expect(delivered.raw_status).toBe('ended');
  expect(delivered.delivery_outcome).toBe('pr_merged');
  expect(delivered.delivery.pr_number).toBe(101);
  expect(delivered.delivery.merge_commit_sha).toBe(head('f'));
  expect(Date.parse(delivered.delivery.pr_merged_at)).toBe(Date.parse(mergeTime));
  expect(await completion()).toBeTruthy();
  const revision = (await architect.call('read_work_request', { view: 'plan', detail: 'full', work_request_id: request })).plan.latest_revision;
  const replay = await architect.call('sync_pr', { work_package_id: wp });
  expect(replay.pr_sync.status).toBe('already_merged');
  expect((await row(architect, request, wp)).delivery).toEqual(delivered.delivery);
  expect((await architect.call('read_work_request', { view: 'plan', detail: 'full', work_request_id: request })).plan.latest_revision).toEqual(revision);
  const calls = provider.calls.filter(({ argv }) => argv[0] === 'pr');
  expect(calls.length).toBeGreaterThan(0);
  for (const { argv } of calls) {
    expect(argv.slice(0, 6)).toEqual(['pr', 'view', '101', '--repo', 'example/service', '--json']);
    for (const field of ['headRefOid', 'files', 'statusCheckRollup', 'reviewDecision', 'mergedAt', 'mergeCommit']) expect(argv[6].split(',')).toContain(field);
  }
});

test('provider errors and incomplete or wrong-head evidence cannot complete a dispatched package', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Untrusted delivery evidence');
  const [wp] = (await architect.addPackages([contract('Evidence refusal')]));
  await architect.call('dispatch_work_package', { work_package_id: wp });
  const handoff = { work_package_id: wp, url: prUrl(102), head_sha: head('a') };
  await architect.reject('sync_pr', { ...handoff, url: 'https://example.invalid/not-a-pr' }, 'invalid_pr_url');
  for (const [stdout, exitCode, reason] of [
    ['HTTP 401 private synthetic diagnostics', 1, 'gh_unauthorized'], ['HTTP 404 private synthetic diagnostics', 1, 'gh_not_found'],
    ['no such file private synthetic diagnostics', 1, 'gh_unavailable'], ['unexpected private synthetic diagnostics', 2, 'request_failed'],
    ['not JSON', 0, 'invalid_github_response'], ['[]', 0, 'invalid_github_response'],
  ] as const) {
    provider.replies.set(102, { stdout, exitCode });
    const response = await architect.rpc('tools/call', { name: 'sync_pr', arguments: handoff });
    expect(response.error?.data?.code).toBe(reason);
    expect(provider.calls.at(-1)?.reply.exitCode).toBe(exitCode);
    expect(JSON.stringify(response)).not.toContain('private synthetic diagnostics');
    expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  }
  for (const patch of [
    { headRefOid: null }, { headRefOid: head('b') }, { baseRefName: 'other' },
    { changedFiles: 2 }, { changedFiles: undefined, files: [] }, { files: undefined }, { files: [] }, { files: [{ path: '', changeType: 'MODIFIED' }] },
    { files: [{ path: 'src/new.ts', changeType: 'RENAMED' }] }, { files: [{ path: 'src/service.ts' }] },
    { files: [{ path: 'src/service.ts', changeType: {} }] }, { url: prUrl(999), number: 999 },
  ]) {
    provider.set(102, pr(102, head('a'), patch));
    const rejected = await architect.rpc('tools/call', { name: 'sync_pr', arguments: handoff });
    expect(rejected.error).toBeTruthy();
    expect((await row(architect, request, wp)).raw_status).toBe('dispatched');
    expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  }
  provider.set(102, pr(102, head('a'), { changedFiles: undefined, files: [{ path: 'src/new.ts', changeType: 'RENAMED', previous_filename: 'src/old.ts' }], additional_field: true }));
  await sync(architect, wp, 102, head('a'));
  const initial = await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`);
  expect(initial.metadata.pr.changed_files[0].previous_path).toBe('src/old.ts');
  expect(initial.metadata.pr.changed_files_count).toBe(1);
  provider.set(102, pr(102, head('a'), {
    state: 'CLOSED', mergeable: 'UNKNOWN', mergeStateStatus: 'UNKNOWN',
    statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'STARTUP_FAILURE' }],
  }));
  await sync(architect, wp, 102, head('a'));
  const failed = await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`);
  expect(failed.metadata.pr.check_summary.status).toBe('failing');
  expect(failed.metadata.pr.merge_state).toEqual({ merged: false, status: 'blocked' });
  expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  for (const missing of [{ mergedAt: new Date().toISOString(), mergeCommit: null }, { mergedAt: null, mergeCommit: { oid: head('f') } }]) {
    provider.set(102, pr(102, head('a'), { state: 'MERGED', ...missing }));
    await architect.reject('sync_pr', { work_package_id: wp }, 'missing_strong_pr_evidence');
    expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  }
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeNull();
  // An explicitly supplied head still refuses a mismatch, including after merge.
  provider.set(102, pr(102, head('b'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await architect.reject('sync_pr', handoff, 'provider_head_mismatch');
  await architect.reject('sync_pr', { work_package_id: wp, head_sha: head('a') }, 'provider_head_mismatch');
  expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  // GitHub's merge evidence closes the attached PR even when the handoff head is old.
  expect((await architect.call('sync_pr', { work_package_id: wp })).pr_sync.status).toBe('merged');
  expect((await row(architect, request, wp)).raw_status).toBe('ended');
  expect((await row(architect, request, wp)).delivery_outcome).toBe('pr_merged');
  expect((await architect.call('sync_pr', { work_package_id: wp })).pr_sync.status).toBe('already_merged');
});

test('typed no-PR closeout resolves blockers once and terminal packages cannot reactivate', async ({ delivery: { factory } }) => {
  const architect = await factory.client();
  const request = await architect.request('No code needed');
  const [wp, abandoned, remaining] = (await architect.addPackages([contract('Findings', { repo: 'example/client', base_branch: 'integration' }), contract('Unstarted attempt'), contract('Remaining work')]));
  for (const id of [wp, abandoned]) {
    await architect.call('dispatch_work_package', { work_package_id: id });
    await architect.call('set_blocker', { work_package_id: id, blocker_id: 'prerequisite', active: true, summary: 'An explicit prerequisite is missing.' });
    expect((await row(architect, request, id)).work_package.blocker_state['active?']).toBe(true);
  }
  // Merges are recorded from GitHub; close_work_package ends a package without one.
  for (const [args, reason] of [
    [{ outcome: 'merged' }, 'invalid_outcome'],
    [{ outcome: 'pr_merged' }, 'invalid_outcome'],
    [{ outcome: 'completed_no_pr' }, 'missing_evidence'],
    [{ outcome: 'completed_no_pr', evidence: '   ' }, 'missing_evidence'],
    [{ outcome: 'superseded', rationale: 'Replaced.' }, 'missing_successor_work_package_id'],
    [{ outcome: 'abandoned' }, 'missing_rationale'],
    [{ outcome: 'completed_no_pr', evidence: 'Done.', rationale: 'Not used.' }, 'argument_not_used'],
    [{ outcome: 'completed_no_pr', evidence: 'Done.', pr_url: prUrl(105) }, 'unexpected_argument'],
  ] as const) {
    const refused = await architect.reject('close_work_package', { work_package_id: wp, ...args }, reason);
    expect(refused).toMatchObject({ state: 'dispatched', next_action: 'fix_arguments' });
    expect(typeof refused.message).toBe('string');
    expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
    expect((await row(architect, request, wp)).work_package.blocker_state['active?']).toBe(true);
  }
  await architect.call('dispatch_work_package', { work_package_id: remaining });
  expect((await row(architect, request, remaining)).delivery_outcome).toBeNull();
  const result = await close(architect, wp);
  const scoped = await row(architect, request, wp);
  expect(scoped.work_package.repo).toBe('example/client');
  expect(scoped.work_package.base_branch).toBe('integration');
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: request })).work_request.base_branch).toBe('beta');
  const revision = (await architect.call('read_work_request', { view: 'plan', detail: 'full', work_request_id: request })).plan.latest_revision;
  expect((await close(architect, wp)).work_package_delivery.id).toBe(result.work_package_delivery.id);
  expect((await architect.call('read_work_request', { view: 'plan', detail: 'full', work_request_id: request })).plan.latest_revision).toEqual(revision);
  const conflict = await architect.reject('close_work_package', { work_package_id: wp, outcome: 'completed_no_pr', evidence: 'Replace original evidence' }, 'delivery_outcome_conflict');
  expect(conflict).toMatchObject({ outcome: 'completed_no_pr', state: 'ended', next_action: 'none' });
  expect((await row(architect, request, wp)).delivery).toEqual(scoped.delivery);
  await close(architect, abandoned, 'abandoned', { rationale: 'No implementation was started.' });
  for (const [id, status] of [[wp, 'ended'], [abandoned, 'ended']]) {
    const before = await row(architect, request, id);
    expect(before.raw_status).toBe(status);
    expect(before.work_package.blocker_state['active?']).toBe(false);
    await architect.reject('set_blocker', { work_package_id: id, blocker_id: 'prerequisite', active: false, summary: 'Already resolved.' }, 'work_package_ended');
    expect((await row(architect, request, id)).raw_status).toBe(status);
    await architect.reject('edit_plan', { ops: [{ op: 'update_package', work_package_id: id, expected_revision: 1, patch: { title: 'Reactivate' } }] }, 'work_package_ended');
    await architect.reject('close_work_package', { work_package_id: id, outcome: 'skipped' }, 'delivery_outcome_conflict');
    expect((await row(architect, request, id)).delivery).toEqual(before.delivery);
  }
  await close(architect, remaining);
  // An abandoned required scope is still unresolved, even though all statuses are terminal.
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeNull();
});

test('blocked handoff accepts new PR and head observations without reviving an older candidate', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Replacement PR observation');
  const [wp] = (await architect.addPackages([contract('Changing candidate')]));
  await architect.call('dispatch_work_package', { work_package_id: wp });
  await architect.call('set_blocker', { work_package_id: wp, blocker_id: 'scope', active: true, summary: 'Resolve scope before accepting handoff.' });
  let priorHeadChanged: string | undefined;
  for (const [number, sha] of [[103, head('a')], [103, head('b')], [104, head('c')], [104, head('a')]] as const) {
    provider.set(number, pr(number, sha));
    const waiting = await sync(architect, wp, number, sha);
    expect(waiting.pr_sync.readiness_reasons).toContain('no_active_blockers');
    const detail = await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`);
    expect(detail.metadata.pr.head_sha).toBe(sha);
    expect(detail.metadata.pr.number).toBe(number);
    expect(detail.metadata.pr.head_changed_at).not.toBe(priorHeadChanged);
    priorHeadChanged = detail.metadata.pr.head_changed_at;
    expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  }
  await architect.call('set_blocker', { work_package_id: wp, blocker_id: 'scope', active: false, summary: 'Scope accepted; continue handoff.' });
  expect((await sync(architect, wp, 104, head('a'))).pr_sync.readiness_reasons).toEqual([]);
  expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(true);
  provider.set(103, pr(103, head('b'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('e') } }));
  await architect.reject('sync_pr', { work_package_id: wp, url: prUrl(103) }, 'pr_reference_mismatch');
  await architect.reject('sync_pr', { work_package_id: wp }, 'pr_not_merged');
  expect(provider.calls.at(-1)?.argv[2]).toBe('104');
  expect((await row(architect, request, wp)).delivery_outcome).toBeNull();
  provider.set(104, pr(104, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await architect.call('sync_pr', { work_package_id: wp });
  expect((await row(architect, request, wp)).delivery.pr_number).toBe(104);
  await architect.reject('set_blocker', { work_package_id: wp, blocker_id: 'scope', active: false, summary: 'Late resolution.' }, 'work_package_ended');
  expect((await row(architect, request, wp)).raw_status).toBe('ended');
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeTruthy();
  await factory.stop();
  let disconnected: unknown;
  try { await architect.rpc('tools/list'); } catch (error) { disconnected = error; }
  expect(disconnected).toBeTruthy();
  const receipts = (await readFile(factory.receipt, 'utf8')).trim().split('\n').map((line) => JSON.parse(line));
  expect(receipts.at(-2).phase).toBe('request');
  expect(receipts.at(-2).method).toBe('tools/list');
  expect(receipts.at(-1).phase).toBe('failure');
  expect(receipts.at(-1).error).toBe(String(disconnected));
});


test('architect integration holds gate a ready PR without reopening work or changing reviewed evidence', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Final integration authority');
  const [wp, sibling] = (await architect.addPackages([contract('Held delivery'), contract('Independent delivery')]));
  for (const [id, number] of [[wp, 801], [sibling, 802]] as const) {
    await architect.call('dispatch_work_package', { work_package_id: id });
    provider.set(number, pr(number, head('a')));
    await sync(architect, id, number, head('a'));
  }
  const before = await row(architect, request, wp);
  expect(before.raw_status).toBe('ready');
  expect(before.merge_eligibility.eligible).toBe(true);
  const metadata = (await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).metadata;
  const hold = { work_package_id: wp, blocker_id: 'integration-authority', active: true, summary: 'Integration requires a final human decision.' };
  const outsider = await factory.client();
  await outsider.request('Unrelated authority');
  expect((await outsider.rpc('tools/call', { name: 'set_blocker', arguments: hold })).error).toBeTruthy();
  expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(true);
  for (const [blocker_id, reason] of [['', 'missing_blocker_id'], ['   ', 'missing_blocker_id'], [42, 'invalid_blocker_id']] as const) {
    await architect.reject('set_blocker', { ...hold, blocker_id }, reason);
  }
  expect((await architect.call('set_blocker', hold)).changed).toBe(true);
  expect((await architect.call('set_blocker', hold)).changed).toBe(false);
  const held = await row(architect, request, wp);
  expect(held.raw_status).toBe('ready');
  expect(held.merge_eligibility.eligible).toBe(false);
  expect(held.merge_eligibility.reason_codes).toContain('active_blocker');
  expect(held.merge_eligibility.next_action).toBe('clear_blocker');
  expect((await row(architect, request, sibling)).merge_eligibility.eligible).toBe(true);
  expect((await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).metadata).toEqual(metadata);
  const resolution = { work_package_id: wp, blocker_id: 'integration-authority', active: false, summary: 'Integration authorized.' };
  expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(false);
  expect((await architect.call('set_blocker', resolution)).changed).toBe(true);
  expect((await architect.call('set_blocker', resolution)).changed).toBe(false);
  expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(true);
  expect((await row(architect, request, wp)).raw_status).toBe('ready');
  expect((await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).metadata).toEqual(metadata);
  provider.set(801, pr(801, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await architect.call('sync_pr', { work_package_id: wp });
  expect((await row(architect, request, wp)).raw_status).toBe('ended');
  await architect.reject('set_blocker', hold, 'work_package_ended');
  expect((await row(architect, request, wp)).work_package.blocker_state['active?']).toBe(false);
});
