import { expect } from 'e2e';
import { writeFile } from 'node:fs/promises';
import { readFile } from 'node:fs/promises';
import { contract, test } from '../support/factory.js';
import { head, pr, prUrl, test as deliveryTest } from '../support/delivery.js';
import { test as processTest } from '../support/authority.js';
import { git, repository } from '../support/worktree-git.js';

test('dispatch and delivery board payload measurements for a 25-package request', async ({ factory }) => {
  const architect = await factory.client();
  const description = [
    'Deliver a scoped service rollout with separate API, client, storage and operator work.',
    'Each package owns its repository and branch, required checks, review and PR handoff.',
    'Preserve dependency ordering, source attribution, delivery evidence and recovery after restart.',
    'Keep production state and provider credentials outside this disposable acceptance fixture.',
  ].join(' ').repeat(4);
  const created = await architect.call('create_work_request', {
    repo: 'example/service', base_branch: 'beta', title: 'Service rollout payload measurement',
    description, work_type: 'feature',
  });
  const request = created.work_request.id;
  architect.workRequest = request;
  const ids = await architect.addPackages(Array.from({ length: 25 }, (_, index) => contract(`Rollout package ${index + 1}`)));
  await architect.reject('dispatch_work_package', { work_package_id: ids[0], review_mode: 'thorough' }, 'invalid_review_mode');
  await architect.reject('dispatch_work_package', { work_package_id: ids[0], review_mode: undefined }, 'missing_review_mode');
  const dispatch = (await architect.rpc('tools/call', architect.toolParams('dispatch_work_package', { work_package_id: ids[0], review_mode: 'fast' }))).result;
  const board = (await architect.rpc('tools/call', {
    name: 'read_work_request', arguments: { work_request_id: request, view: 'board' },
  })).result;
  expect(dispatch.structuredContent.work_package).toMatchObject({ id: ids[0], status: 'dispatched', review_mode: 'fast' });
  expect(dispatch.structuredContent.work_package.review_id).toMatch(/^rvw_[0-9a-f]{16}$/);
  expect(board.structuredContent.delivery_board.work_packages.length).toBe(25);
  // This fixture repository has no checkout: the package stays dispatched and the hand-off says what to fix.
  expect(dispatch.structuredContent.error.reason).toBe('target_repo_root_required');
  expect(dispatch.structuredContent.error.expected_repo).toBe('example/service');
  expect(dispatch.structuredContent.next_action).toContain('dispatch_work_package again with review_mode fast');
  expect(dispatch.structuredContent.launch_line).toBeUndefined();
  await architect.reject('read_work_request', { work_request_id: request, view: 'board', detail: true }, 'invalid_detail');
  const fullBoard = (await architect.rpc('tools/call', {
    name: 'read_work_request', arguments: { work_request_id: request, view: 'board', detail: 'full' },
  })).result;
  expect(board.structuredContent.delivery_board.counts).toEqual(fullBoard.structuredContent.delivery_board.counts);
  for (const row of board.structuredContent.delivery_board.work_packages) {
    const full = fullBoard.structuredContent.delivery_board.work_packages.find((item: any) => item.id === row.id);
    expect(row.raw_status).toBe(full.raw_status);
    expect(row.delivery_outcome).toBe(full.delivery_outcome);
    expect(row.attention_reason_codes).toEqual(full.attention_reason_codes);
    expect(row.merge_eligibility).toEqual(full.merge_eligibility);
    expect(row.state).toBe(full.operational_state.key);
    expect(row.work_package).toBeUndefined();
    expect(board.content[0].text).toContain(row.id);
  }
  const chars = (value: unknown) => JSON.stringify(value).length;
  expect(chars(board)).toBeLessThan(chars(fullBoard) / 2);
  // Actual baseline at fc486cee (hosted combined tree f65790a9), using this fixture.
  expect(chars(dispatch)).toBeLessThan(23_384 / 2);
  expect(chars(board)).toBeLessThan(46_312 / 2);
  const sizes = {
    checkout: process.env.ACCEPTANCE_CHECKOUT_SHA, packages: 25,
    dispatch: chars(dispatch), board: chars(board), fullBoard: chars(fullBoard),
  };
  await writeFile('.e2e/payload-sizes.json', JSON.stringify(sizes, null, 2));
  console.log(`Payload character counts: ${JSON.stringify(sizes)}`);
});

test('skipping every planned package leaves the goal unfinished in persisted and visible state', async ({ factory }) => {
  const architect = await factory.client();
  const request = await architect.request('Skipped scope');
  const ids = await architect.addPackages([contract('Retired first scope'), contract('Retired second scope')]);
  for (const work_package_id of ids) await architect.call('close_work_package', { work_package_id, outcome: 'skipped' });
  const detail = (await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request;
  expect(detail.phase).toBe('unresolved');
  expect(detail.completed_at).toBeNull();
  const hydrated = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  expect(hydrated.work_request_details.find((detail: any) => detail.work_request.id === request).work_request.completed_at).toBeNull();
});

test('a clarified request becomes a revised plan and a dispatched package', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Clarified planning');
  const ask = (await architect.call('ask', { work_request_id: id, question: 'Which behavior should ship?' })).ask;
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_request.phase).toBe('intake');
  // An open ask never holds back planning.
  const [wp] = await architect.addPackages([contract('Agreed scope')]);
  expect((await architect.call('read_work_request', { work_request_id: id })).work_request.phase).toBe('planned');
  await architect.call('resolve_ask', { ask_id: ask.id, to: 'answered', answer: 'Ship the agreed behavior.' });
  const before = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(before.work_packages).toHaveLength(1);
  const revision = before.work_packages[0].contract_revision;
  const update = (title: string) => ({ ops: [{ op: 'update_package', work_package_id: wp, expected_revision: revision, patch: { title } }] });
  const updated = await architect.call('edit_plan', update('Refined agreed scope'));
  expect(updated.applied[0].revision).toBe(revision + 1);
  const stale = await architect.reject('edit_plan', update('Lost update'), 'revision_conflict');
  expect(stale.current_revision).toBe(revision + 1);
  expect(stale.op_index).toBe(0);
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_packages[0].title).toBe('Refined agreed scope');

  const dispatched = await architect.call('dispatch_work_package', { work_package_id: wp });
  expect(dispatched.work_package).toMatchObject({ id: wp, status: 'dispatched', review_mode: 'none', review_id: null });
  const packageView = await architect.call('read_work_request', { work_request_id: id, view: 'package', work_package_id: wp, detail: 'full' });
  expect(packageView.task_plan.text).toContain('Implement requested scope');
});

test('invalid batches are atomic and secondary delivery preserves repository and branch boundaries', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Repository scope', 'main');
  const secondary = contract('Secondary implementation', { repo: 'example/client', base_branch: 'integration' });
  const invalid = { ...secondary };
  delete invalid.base_branch;
  const add = (...contracts: object[]) => ({ ops: contracts.map((item) => ({ op: 'add_package', ...item })) });
  const scope = await architect.reject('edit_plan', add(contract('Valid prefix'), invalid), 'invalid_work_package');
  expect(scope.op_index).toBe(1);
  expect(JSON.stringify(scope)).toContain('base_branch');
  for (const required of ['title', 'goal', 'acceptance_criteria']) {
    const incomplete: Record<string, unknown> = contract('One omitted requirement');
    delete incomplete[required];
    const refused = await architect.reject('edit_plan', add(contract('Valid prefix'), incomplete), 'incomplete_contract');
    expect(refused.missing).toEqual([required]);
    expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_packages).toEqual([]);
  }
  for (const patch of [{ title: '' }, { goal: ' ' }, { acceptance_criteria: [null] }, { validation_steps: 'run checks' }, { stop_conditions: {} }]) {
    await architect.reject('edit_plan', add(contract('Invalid contract', patch)), 'incomplete_contract');
  }
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_packages).toEqual([]);
  const normalized = contract('Canonical primary scope', { base_branch: ' refs/remotes/origin/main ' });
  const [wp, primary] = await architect.addPackages([secondary, normalized]);
  const read = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(read.work_packages[0].repo).toBe('example/client');
  expect(read.work_packages[0].base_branch).toBe('integration');
  // Each package's worktree comes from its own repository.
  expect((await architect.call('dispatch_work_package', { work_package_id: wp })).error.expected_repo).toBe('example/client');
  expect(read.work_packages.find((wp: any) => wp.id === primary).base_branch).toBe('main');
  expect((await architect.call('dispatch_work_package', { work_package_id: primary })).error.expected_repo).toBe('example/service');
});

test('group paths organize scope while the effective dependency graph prevents premature or cyclic dispatch', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Grouped plan');
  const add = (title: string, key: string, patch: object = {}) => ({ op: 'add_package', key, ...contract(title, patch) });
  const edited = await architect.call('edit_plan', { ops: [
    add('Documentation', 'docs', { group: 'Capability / Prerequisites' }),
    add('API', 'api', { group: 'Capability/Prerequisites/Nested', depends_on: ['docs'] }),
    add('Peer API', 'peer', { group: 'Capability / Prerequisites / Nested', depends_on: ['docs'] }),
    add('Client', 'client', { group: 'Consumers' }),
    add('Independent', 'independent'),
  ] });
  const [documentation, api, peerApi, client, independent] = edited.applied.map((op: any) => op.work_package_id);
  const planned = Object.fromEntries(edited.plan.work_packages.map((wp: any) => [wp.id, wp]));
  expect(planned[api]).toMatchObject({ group: 'Capability / Prerequisites / Nested', depends_on: [documentation], next_action: 'deliver_prerequisites' });
  expect(planned[documentation]).toMatchObject({ group: 'Capability / Prerequisites', depends_on: [], next_action: 'dispatch_work_package' });
  expect(planned[independent].group).toBeNull();

  const readPlan = async () => (await architect.call('read_work_request', { detail: 'full', work_request_id: id, view: 'plan' })).plan;
  const overlap = (await readPlan()).execution_graph;
  expect(overlap.effective_edges.map((edge: any) => [edge.prerequisite_work_package_id, edge.dependent_work_package_id]).sort())
    .toEqual([[documentation, api], [documentation, peerApi]].sort());
  expect(overlap.cycles).toEqual([]);
  for (const childPackage of [api, peerApi]) {
    const blocked = await architect.reject('dispatch_work_package', { work_package_id: childPackage }, 'unmet_work_package_dependencies');
    expect(blocked.prerequisite_work_package_ids).toEqual([documentation]);
  }
  expect((await architect.call('dispatch_work_package', { work_package_id: documentation })).work_package.id).toBe(documentation);
  await architect.call('edit_plan', { ops: [
    { op: 'set_dependency', from: client, to: api, reason: 'The consumer requires its API.' },
    { op: 'set_dependency', from: client, to: peerApi },
  ] });
  const unmet = await architect.reject('dispatch_work_package', { work_package_id: client }, 'unmet_work_package_dependencies');
  expect([...unmet.prerequisite_work_package_ids].sort()).toEqual([api, peerApi].sort());
  const self = await architect.reject('edit_plan', { ops: [{ op: 'set_dependency', from: client, to: client }] }, 'self_dependency');
  expect(self.op_index).toBe(0);
  expect((await architect.call('dispatch_work_package', { work_package_id: independent })).work_package.id).toBe(independent);

  await architect.call('edit_plan', { ops: [{ op: 'set_dependency', from: api, to: client, reason: 'A contradictory planning intent must prevent execution.' }] });
  await architect.reject('dispatch_work_package', { work_package_id: api }, 'execution_graph_cycle');
  await architect.call('edit_plan', { ops: [{ op: 'remove_dependency', from: api, to: client }] });
  await architect.reject('edit_plan', { ops: [{ op: 'remove_dependency', from: api, to: client }] }, 'dependency_not_found');

  // One failing op rolls back the ops before it.
  const rolledBack = await architect.reject('edit_plan', { ops: [
    { op: 'update_package', work_package_id: client, expected_revision: 1, patch: { group: null } },
    { op: 'remove_dependency', from: client, to: independent },
  ] }, 'dependency_not_found');
  expect(rolledBack.op_index).toBe(1);
  expect((await readPlan()).work_packages.find((wp: any) => wp.id === client).group).toBe('Consumers');

  await architect.call('edit_plan', { ops: [
    { op: 'update_package', work_package_id: client, expected_revision: 1, patch: { group: null } },
    { op: 'remove_dependency', from: client, to: api },
    { op: 'remove_dependency', from: client, to: peerApi },
  ] });
  const plan = await readPlan();
  expect(plan.work_packages.find((wp: any) => wp.id === client)).toMatchObject({ group: null, contract_revision: 2 });
  expect(plan.dependencies.map((dependency: any) => [dependency.from, dependency.to]).sort()).toEqual([[api, documentation], [peerApi, documentation]].sort());
  await architect.reject('edit_plan', { ops: [
    { op: 'update_package', work_package_id: client, expected_revision: 1, patch: { title: 'Stale edit' } },
  ] }, 'revision_conflict');
  expect((await architect.call('dispatch_work_package', { work_package_id: client })).work_package.id).toBe(client);
});

test('package endings follow their allowed statuses, replay idempotently and clear only the ended package\'s blockers', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Ending rules');
  const [planned, dispatched, sibling, skipped] = await architect.addPackages(['Planned scope', 'Dispatched scope', 'Sibling scope', 'Retired scope'].map((title) => contract(title)));
  for (const work_package_id of [dispatched, sibling]) await architect.call('dispatch_work_package', { work_package_id });
  const early = await architect.reject('close_work_package', { work_package_id: planned, outcome: 'abandoned', rationale: 'No longer needed.' }, 'ending_not_allowed');
  expect(early).toMatchObject({ state: 'planned', outcome: 'abandoned' });
  expect([...early.allowed_outcomes].sort()).toEqual(['skipped', 'superseded']);
  expect((await architect.reject('close_work_package', { work_package_id: dispatched, outcome: 'skipped' }, 'ending_not_allowed')).state).toBe('dispatched');
  expect((await architect.call('close_work_package', { work_package_id: skipped, outcome: 'skipped' })).work_package_delivery.outcome).toBe('skipped');
  for (const [work_package_id, blocker_id] of [[dispatched, 'ended-blocker'], [sibling, 'sibling-blocker']]) {
    await architect.call('set_blocker', { work_package_id, blocker_id, active: true, summary: `Blocked by ${blocker_id}` });
  }
  const ending = { work_package_id: dispatched, outcome: 'abandoned', rationale: 'Rehomed.' };
  const first = await architect.call('close_work_package', ending);
  expect(first.work_package.status).toBe('ended');
  expect((await architect.call('close_work_package', ending)).work_package_delivery.id).toBe(first.work_package_delivery.id);
  const conflict = await architect.reject('close_work_package', { work_package_id: dispatched, outcome: 'completed_no_pr', evidence: 'Done.' }, 'delivery_outcome_conflict');
  expect(conflict).toMatchObject({ state: 'ended', outcome: 'abandoned', next_action: 'none' });
  const blockers = async (wp: string) => (await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).blockers.filter((entry: any) => entry.active).map((entry: any) => entry.id);
  expect(await blockers(dispatched)).toEqual([]);
  expect(await blockers(sibling)).toEqual(['sibling-blocker']);
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_packages.find((wp: any) => wp.id === planned).status).toBe('planned');
});

test('plan edits normalize groups, version moves, update dependency reasons and keep secrets out of every response', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Plan edit details');
  const added = await architect.tool('edit_plan', { ops: [
    { op: 'add_package', key: 'api', ...contract('Billing API', { group: 'Backend/ Billing' }) },
    { op: 'add_package', key: 'ui', ...contract('Billing page', { group: 'Frontend', depends_on: ['api'] }) },
    { op: 'add_package', ...contract('Token ghp_editplansecretvalue12345', { group: 'Ops / ghp_editplansecretvalue12345' }) },
  ] });
  expect(JSON.stringify(added)).not.toContain('ghp_editplansecretvalue12345');
  const [api, ui] = added.result.structuredContent.applied.map((op: any) => op.work_package_id);
  const readPlan = async () => (await architect.call('read_work_request', { detail: 'full', work_request_id: id, view: 'plan' })).plan;
  expect((await readPlan()).work_packages.find((wp: any) => wp.id === api)).toMatchObject({ group: 'Backend / Billing', status: 'planned', contract_revision: 1 });
  const invalid = await architect.reject('edit_plan', { ops: [{ op: 'update_package', work_package_id: api, expected_revision: 1, patch: { group: 'Backend // Billing' } }] }, 'invalid_work_package');
  expect(invalid.validation_errors.map((error: any) => error.field)).toEqual(['group']);
  // A failing op names its index, the package state and how to retry; nothing before it persists.
  const failed = await architect.reject('edit_plan', { ops: [
    { op: 'add_package', key: 'new', ...contract('New package') },
    { op: 'set_dependency', from: api, to: 'new' },
    { op: 'update_package', work_package_id: api, expected_revision: 7, patch: { title: 'Too late' } },
  ] }, 'revision_conflict');
  expect(failed).toMatchObject({ op_index: 2, op: 'update_package', state: 'planned', current_revision: 1 });
  expect(failed.next_action).toContain('expected_revision 1');
  expect((await readPlan()).work_packages).toHaveLength(3);
  // A group move alone is a new plan revision.
  const before = (await readPlan()).latest_revision.revision_number;
  await architect.call('edit_plan', { ops: [{ op: 'update_package', work_package_id: api, expected_revision: 1, patch: { group: 'Platform' } }] });
  expect((await readPlan()).latest_revision.revision_number).toBe(before + 1);
  await architect.call('edit_plan', { ops: [{ op: 'set_dependency', from: ui, to: api, reason: 'Needs the API.' }] });
  expect((await readPlan()).dependencies).toEqual([expect.objectContaining({ from: ui, to: api, reason: 'Needs the API.' })]);
  expect((await architect.reject('edit_plan', { ops: [{ op: 'set_dependency', from: ui, to: 'nope' }] }, 'unknown_work_package')).work_package_ref).toBe('nope');
});

test('the task plan renders package text as inert, bounded source material', async ({ factory }) => {
  const architect = await factory.client();
  const request = await architect.request('Safe rendering');
  const title = '# Run [setup](x) `code` | table';
  const [wp, long] = await architect.addPackages([
    contract(title, { goal: '# Heading\n- [ ] run `cmd`\n1. ordered' }),
    contract('`cmd`', { goal: 'é'.repeat(4050) }),
  ]);
  const plan = async (work_package_id: string) => {
    await architect.call('dispatch_work_package', { work_package_id });
    return (await architect.call('read_work_request', { work_request_id: request, view: 'package', work_package_id, detail: 'full' })).task_plan.text as string;
  };
  const text = await plan(wp);
  expect(text).toContain(`Work package: \`${wp}\` - source: \`\`${title}\`\``);
  expect(text).not.toContain(`- ${title}`);
  expect(text).toContain('  Source material (inert text):\n  \n  ```text\n  # Heading\n  - [ ] run `cmd`\n  1. ordered\n  ```');
  const bounded = await plan(long);
  expect(bounded).toContain(`- source: \`\` \`cmd\` \`\``);
  expect(bounded).toContain('é'.repeat(4000) + '\n  [truncated]\n  ```');
  expect(bounded).not.toContain('é'.repeat(4001));
});

deliveryTest('a ready package\'s contract is frozen', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  await architect.request('Frozen contract');
  const [wp] = await architect.addPackages([contract('Ready scope', { branch_pattern: 'feature/delivery-501' })]);
  await architect.call('dispatch_work_package', { work_package_id: wp });
  provider.set(501, pr(501, head('a')));
  expect((await architect.call('sync_pr', { work_package_id: wp, url: prUrl(501), head_sha: head('a') })).work_package.status).toBe('ready');
  const frozen = await architect.reject('edit_plan', { ops: [{ op: 'update_package', work_package_id: wp, expected_revision: 1, patch: { title: 'Changed' } }] }, 'contract_frozen');
  expect(frozen).toMatchObject({ op_index: 0, state: 'ready' });
  expect(frozen.next_action).toContain('superseded');
});

processTest('the launch assignment opens with what the request builds and where the package sits, and replays unchanged', async ({ processes }) => {
  const { root } = processes;
  const repo = await repository(root, 'assignment');
  const architect = await processes.factory().client();
  const created = await architect.call('create_work_request', {
    repo: repo.origin, base_branch: 'beta', title: 'Improve WorkRequest intake', work_type: 'feature',
    description: 'Operators file requests in one place.\n\nThe intake form keeps drafts.',
  });
  architect.workRequest = created.work_request.id;
  const [reviewed, unreviewed] = await architect.addPackages(['feat/reviewed', 'feat/unreviewed'].map((branch) =>
    contract(`Hand off ${branch}`, { group: 'Backend / Intake ghp_assignmentgroupsecret12345', branch_pattern: branch })));
  const args = { work_package_id: reviewed, review_mode: 'fast', target_repo_root: repo.checkout, machine: 'factory' };
  const launched = await architect.call('dispatch_work_package', args);
  const assignment = await readFile(launched.assignment_file, 'utf8');
  const building = assignment.match(/^# WorkPackage [^\n]+\n\n(.+?)\n\nYou are the worker/s)![1];
  expect(building).toMatch(/^## What we're building\n\n\*\*Improve WorkRequest intake\.\*\* Operators file requests in one place\.\n\nThis package is in Backend \/ Intake \S+\.$/);
  expect(assignment).not.toContain('ghp_assignmentgroupsecret12345');
  expect(assignment).toContain('start it again while it runs');
  expect(assignment).toContain('Hand off feat/reviewed');
  expect(launched.launch_line).toContain('--on factory ');
  // A contract edit while dispatched does not move the recorded worktree off its branch.
  await architect.call('edit_plan', { ops: [{ op: 'update_package', work_package_id: reviewed, expected_revision: 1, patch: { branch_pattern: 'feat/renamed' } }] });
  const replay = await architect.call('dispatch_work_package', args);
  expect([replay.replay, replay.worktree.path, replay.worktree.branch, replay.launch_line]).toEqual([true, launched.worktree.path, 'feat/reviewed', launched.launch_line]);
  expect(await git(root, launched.worktree.path, 'branch', '--show-current')).toBe('feat/reviewed');
  // Mode none mints no review id and gives the chosen agent no review step.
  const none = await architect.call('dispatch_work_package', { work_package_id: unreviewed, review_mode: 'none', agent: 'claude', target_repo_root: repo.checkout });
  expect(none.work_package.review_id).toBeNull();
  expect(none.launch_line).not.toContain('sympp.review_id');
  expect(none.launch_line).toContain('-- claude "Read ');
  expect(none.next_action).toContain('trust prompt');
  const plain = await readFile(none.assignment_file, 'utf8');
  expect(plain).toContain('No Review Suite review is required');
  expect(plain).not.toContain('review.py');
  const progress = (await architect.inspect(`/api/v1/sympp/operator/work-packages/${reviewed}`)).progress;
  expect(JSON.stringify(progress)).not.toContain(repo.checkout);
});
