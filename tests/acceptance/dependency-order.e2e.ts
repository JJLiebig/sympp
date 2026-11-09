import { expect } from 'e2e';
import { contract, type Client } from '../support/factory.js';
import { close, head, pr, prUrl, row, sync, test } from '../support/delivery.js';

const plan = async (client: Client, request: string) => (await client.call('read_work_request', { detail: 'full', work_request_id: request, view: 'plan' })).plan;
const graph = async (client: Client, request: string) => (await plan(client, request)).execution_graph;
const dependencyId = async (client: Client, request: string, from: string, to: string) =>
  (await plan(client, request)).dependencies.find((dependency: any) => dependency.from === from && dependency.to === to).id;
const depend = (client: Client, from: string, to: string, extra: object = {}) =>
  client.call('edit_plan', { ops: [{ op: 'set_dependency', from, to, ...extra }] });
const add = (title: string, key: string, patch: object = {}) => ({ op: 'add_package', key, ...contract(title, patch) });

test('all dependency endpoint combinations dispatch only after canonical delivery, including successor chains', async ({ delivery: { factory } }) => {
  const architect = await factory.client();
  const request = await architect.request('Dependency delivery');
  // Dependencies may name packages added earlier in the same edit by key.
  const edited = await architect.call('edit_plan', { ops: [
    add('Direct prerequisite', 'direct'), add('Direct dependent', 'next', { depends_on: ['direct'] }),
    add('Source one', 'a', { group: 'Sources' }), add('Source two', 'b', { group: 'Sources' }),
    add('Middle one', 'c', { group: 'Middle', depends_on: ['next'] }), add('Middle two', 'd', { group: 'Middle', depends_on: ['next'] }),
    add('Group consumer', 'e', { group: 'Consumers', depends_on: ['c', 'd'] }), add('Source group consumer', 'consumer', { depends_on: ['a', 'b'] }),
    add('Replacement attempt', 'successor'), add('Final replacement', 'final'), add('Cancelled scope', 'cancelled'),
  ] });
  const [direct, next, a, b, c, d, e, consumer, successor, final, cancelled] = edited.applied.map((op: any) => op.work_package_id);
  expect((await graph(architect, request)).effective_edges.map((edge: any) => [edge.prerequisite_work_package_id, edge.dependent_work_package_id]).sort())
    .toEqual([[direct, next], [a, consumer], [b, consumer], [next, c], [next, d], [c, e], [d, e]].sort());
  await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies');
  await depend(architect, next, cancelled, { reason: 'Initially required scope.' });
  await architect.call('skip_work_package', { work_package_id: cancelled });
  const refusal = await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies');
  expect(refusal.prerequisite_work_package_ids.sort()).toEqual([direct, cancelled].sort());
  expect((await row(architect, request, cancelled)).raw_status).toBe('ended');
  expect((await row(architect, request, cancelled)).delivery_outcome).toBe('skipped');
  await architect.call('edit_plan', { ops: [{ op: 'remove_dependency', from: next, to: cancelled }] });
  // Retiring scope is not completion; only the delivered end of the chain satisfies it.
  await architect.call('append_progress', { work_package_id: direct, summary: 'This attempt is blocked.', idempotency_key: 'superseded-blocker', payload: { type: 'blocker', active: true, blocker_id: 'old-attempt' } });
  await close(architect, direct, 'superseded', { successor_work_package_id: successor, superseded_reason: 'A replacement owns the same scope.' });
  expect((await row(architect, request, direct)).work_package.blocker_state['active?']).toBe(false);
  await close(architect, successor, 'superseded', { successor_work_package_id: final, superseded_reason: 'The final attempt owns the same scope.' });
  await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies');
  expect((await row(architect, request, direct)).successor.work_package_id).toBe(successor);
  expect((await row(architect, request, successor)).successor.work_package_id).toBe(final);
  await close(architect, final);
  expect((await architect.call('dispatch_work_package', { work_package_id: next })).work_package.id).toBe(next);
  for (const wp of [a, b, next, c, d, consumer, e]) {
    if (wp !== next) await architect.call('dispatch_work_package', { work_package_id: wp });
    await close(architect, wp);
  }
  expect((await graph(architect, request)).unmet_dependencies).toEqual([]);
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeTruthy();
  expect((await row(architect, request, direct)).delivery_outcome).toBe('superseded');
  expect((await row(architect, request, successor)).delivery_outcome).toBe('superseded');
  const archived = await architect.operator(`/api/v1/sympp/operator/work-requests/${request}/archive`, {});
  expect(archived.status).toBe(200);
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.archived_at).toBeTruthy();
});

test('candidate pins allow dispatch but current pins and dependent inputs gate merge', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Exact candidate ordering');
  const [backend, ui, peer, late] = await architect.addPackages([contract('Backend'), contract('Consumer', { group: 'Consumers' }), contract('Peer', { group: 'Consumers' }), contract('Late consumer', { group: 'Consumers' })]);
  await architect.call('dispatch_work_package', { work_package_id: backend });
  provider.set(201, pr(201, head('a')));
  await sync(architect, backend, 201, head('a'));
  await depend(architect, ui, backend, { reason: 'Require delivered scope.' });
  await architect.reject('dispatch_work_package', { work_package_id: ui }, 'unmet_work_package_dependencies');
  // One edit pins every consumer to the reviewed backend candidate.
  await architect.call('edit_plan', { ops: [ui, peer, late].map((from) => ({ op: 'set_dependency', from, to: backend, candidate_head_sha: head('a') })) });
  const pin = await dependencyId(architect, request, ui, backend);
  await depend(architect, ui, backend, { candidate_head_sha: head('b') });
  await architect.reject('dispatch_work_package', { work_package_id: ui }, 'unmet_work_package_dependencies');
  await depend(architect, ui, backend, { candidate_head_sha: head('a') });
  expect((await architect.call('dispatch_work_package', { work_package_id: ui })).work_package.status).toBe('dispatched');
  const contextBefore = (await plan(architect, request)).dependencies.find((dependency: any) => dependency.id === pin);
  const invalidContext = await architect.rpc('tools/call', architect.toolParams('edit_plan', { ops: [{ op: 'set_dependency', from: ui, to: backend, reason: '' }] }));
  expect(invalidContext.error?.data).toMatchObject({ reason: 'invalid_field', field: 'reason', op_index: 0 });
  const contextAfter = (await plan(architect, request)).dependencies.find((dependency: any) => dependency.id === pin);
  expect(contextAfter).toEqual(contextBefore);
  expect(contextAfter.reason).toBe('Require delivered scope.');
  expect((await graph(architect, request)).effective_edges.find((edge: any) => edge.dependent_work_package_id === ui).constraints[0].candidate_head_sha).toBe(head('a'));

  // A new PR head is a real current-head change; old candidate evidence cannot win.
  provider.set(201, pr(201, head('b')));
  await sync(architect, backend, 201, head('b'));
  await architect.reject('dispatch_work_package', { work_package_id: peer }, 'unmet_work_package_dependencies');
  expect((await graph(architect, request)).effective_edges[0].constraints[0].candidate_state).toBe('stale_head');
  provider.set(201, pr(201, head('a')));
  await sync(architect, backend, 201, head('a'));
  expect((await architect.call('dispatch_work_package', { work_package_id: peer })).work_package.id).toBe(peer);
  provider.set(202, pr(202, head('c')));
  const staleInputs = await sync(architect, ui, 202, head('c'));
  expect(staleInputs.pr_sync.readiness_reasons).toContain('dependency_inputs_stale');
  const inputs = [{ dependency_id: pin, prerequisite_work_package_id: backend, candidate_head_sha: head('a') }];
  for (const [sha, selections] of [[head('d'), inputs], [head('c'), [{ ...inputs[0], candidate_head_sha: head('b') }]]] as const) {
    const rejected = await architect.tool('sync_pr', { work_package_id: ui, url: prUrl(202), head_sha: sha, dependency_inputs: selections });
    expect(rejected.error).toBeTruthy();
  }
  await architect.call('sync_pr', { work_package_id: ui, url: prUrl(202), head_sha: head('c'), dependency_inputs: inputs });
  // Repinning away and back needs a fresh attestation, even of the same input.
  await depend(architect, ui, backend, { candidate_head_sha: head('b') });
  await depend(architect, ui, backend, { candidate_head_sha: head('a') });
  expect((await row(architect, request, ui)).merge_eligibility.reason_codes).toContain('dependency_inputs_stale');
  await architect.call('sync_pr', { work_package_id: ui, url: prUrl(202), head_sha: head('c'), dependency_inputs: inputs });
  expect((await row(architect, request, ui)).merge_eligibility.reason_codes).not.toContain('dependency_inputs_stale');
  expect((await row(architect, request, ui)).merge_eligibility.reason_codes).toContain('dependency_not_delivered');
  provider.set(201, pr(201, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('e') } }));
  await architect.call('sync_pr', { work_package_id: backend });
  expect((await row(architect, request, ui)).merge_eligibility.eligible).toBe(true);
  // Delivery cannot excuse a mismatched pin.
  await depend(architect, late, backend, { candidate_head_sha: head('b') });
  await architect.reject('dispatch_work_package', { work_package_id: late }, 'unmet_work_package_dependencies');
  await depend(architect, late, backend, { candidate_head_sha: head('a') });
  expect((await architect.call('dispatch_work_package', { work_package_id: late })).work_package.id).toBe(late);
  // A ready contract is frozen: an edit is refused and the package stays ready.
  const frozen = await architect.reject('edit_plan', { ops: [{ op: 'update_package', work_package_id: ui, expected_revision: 1, patch: { title: 'Revised consumer contract' } }] }, 'contract_frozen');
  expect(frozen.state).toBe('ready');
  expect((await row(architect, request, ui)).raw_status).toBe('ready');
  // A new dependent head consumed nothing yet: its inputs are stale and it is no longer ready.
  provider.set(202, pr(202, head('d')));
  await sync(architect, ui, 202, head('d'));
  expect((await row(architect, request, ui)).merge_eligibility.reason_codes).toContain('dependency_inputs_stale');
  expect((await row(architect, request, ui)).raw_status).toBe('dispatched');
  expect((await row(architect, request, ui)).merge_eligibility.eligible).toBe(false);
});

test('clearing a candidate requires fresh qualification while a new unpinned prerequisite requires only delivery', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Expanded cleared pin');
  const [a, b, ui] = await architect.addPackages([contract('First', { group: 'Prerequisites' }), contract('Second', { group: 'Prerequisites' }), contract('Consumer')]);
  await depend(architect, ui, a, { candidate_head_sha: head('a'), reason: 'Use current scope.' });
  await close(architect, a);
  await close(architect, b);
  // A completed no-PR package has no candidate head; removing the pin is explicit.
  await architect.reject('dispatch_work_package', { work_package_id: ui }, 'unmet_work_package_dependencies');
  await architect.call('edit_plan', { ops: [
    { op: 'set_dependency', from: ui, to: a, candidate_head_sha: null },
    { op: 'set_dependency', from: ui, to: b, reason: 'Use current scope.' },
  ] });
  await architect.call('dispatch_work_package', { work_package_id: ui });
  provider.set(203, pr(203, head('c')));
  await sync(architect, ui, 203, head('c'));
  // The cleared pin needs fresh qualification; the new dependency never carried a pin, so delivery is enough.
  const stale = (await row(architect, request, ui)).merge_eligibility;
  expect(stale.eligible).toBe(false);
  expect(stale.reason_codes).toContain('dependency_inputs_stale');
  await architect.call('sync_pr', {
    work_package_id: ui, url: prUrl(203), head_sha: head('c'),
    dependency_inputs: [{ dependency_id: await dependencyId(architect, request, ui, a), prerequisite_work_package_id: a, candidate_head_sha: null }],
  });
  expect((await sync(architect, ui, 203, head('c'))).pr_sync.readiness_reasons).toEqual([]);
  expect((await row(architect, request, ui)).merge_eligibility.eligible).toBe(true);
});

test('out-of-order automatic and manual closeout retain order violations through reconciliation', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('External merge order');
  const [backend, ui, replay] = await architect.addPackages([contract('Prerequisite'), contract('Dependent'), contract('Manual action replay')]);
  // Dispatch happened before the architect discovered the dependency.
  const mergeTime = new Date().toISOString();
  for (const [wp, number] of [[ui, 204], [replay, 205]] as const) {
    await architect.call('dispatch_work_package', { work_package_id: wp });
    await depend(architect, wp, backend, { reason: 'Prerequisite must deliver first.' });
    await architect.call('append_progress', { work_package_id: wp, summary: 'External merge bypassed this blocker.', idempotency_key: `block-${wp}`, payload: { type: 'blocker', active: true, blocker_id: 'merge-order' } });
    provider.set(number, pr(number, head('d')));
    expect((await sync(architect, wp, number, head('d'))).pr_sync.readiness_reasons).toContain('dependencies_unavailable');
    expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(false);
    provider.set(number, pr(number, head('d'), { state: 'MERGED', mergedAt: mergeTime, mergeCommit: { oid: head('f') } }));
    if (wp === ui) {
      await architect.call('sync_pr', { work_package_id: wp, url: prUrl(number) });
    } else {
      const action = { work_package_id: wp, outcome: 'pr_merged', idempotency_key: 'external-manual-closeout', recorded_by: 'acceptance-architect', evidence: {
        pr_merged: { pr_url: prUrl(number), pr_number: number, pr_repository: 'example/service', pr_merged_at: mergeTime, merge_commit_sha: head('f') },
      } };
      const recorded = (await architect.call('record_work_package_delivery', action)).work_package_delivery;
      expect(recorded.outcome).toBe('pr_merged');
      expect(recorded.recorded_by).toBe('acceptance-architect');
      expect((await architect.call('record_work_package_delivery', action)).work_package_delivery.id).toBe(recorded.id);
    }
  }
  expect((await row(architect, request, ui)).delivery_outcome).toBe('pr_merged');
  expect((await row(architect, request, replay)).work_package.blocker_state['active?']).toBe(false);
  const merged = await row(architect, request, ui);
  expect(merged.raw_status).toBe('ended');
  expect(merged.delivery_outcome).toBe('pr_merged');
  expect(merged.work_package.blocker_state['active?']).toBe(false);
  expect(merged.attention_reason_codes).toContain('delivery_order_violation');
  expect(Date.parse(merged.delivery.pr_merged_at)).toBe(Date.parse(mergeTime));
  expect((await architect.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeNull();
  await close(architect, backend);
  const after = await row(architect, request, ui);
  expect(after.delivery).toEqual(merged.delivery);
  expect(after.merge_eligibility.reason_codes).toContain('delivery_order_violation');
  await architect.call('sync_pr', { work_package_id: ui });
  expect((await row(architect, request, ui)).delivery).toEqual(merged.delivery);
});
