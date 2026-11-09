import { expect } from 'e2e';
import { writeFile } from 'node:fs/promises';
import { contract, test } from '../support/factory.js';

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
