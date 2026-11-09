import { expect } from 'e2e';
import { contract, type Client } from '../support/factory.js';
import { close, head, pr, prUrl, row, sync, test } from '../support/delivery.js';

const plan = async (client: Client, request: string) => (await client.call('read_work_request', { detail: 'full', work_request_id: request, view: 'plan' })).plan;
const graph = async (client: Client, request: string) => (await plan(client, request)).execution_graph;
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
    add('Waiting on others', 'parked'), add('After parked work', 'later', { depends_on: ['parked'] }),
  ] });
  const [direct, next, a, b, c, d, e, consumer, successor, final, cancelled, parked, later] = edited.applied.map((op: any) => op.work_package_id);
  const delivered = 'wait for delivered closure (merged PR or completed without a PR) of';
  expect((await graph(architect, request)).effective_edges.map((edge: any) => [edge.prerequisite_work_package_id, edge.dependent_work_package_id]).sort())
    .toEqual([[direct, next], [a, consumer], [b, consumer], [next, c], [next, d], [c, e], [d, e], [parked, later]].sort());
  expect((await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies')).next_action)
    .toBe(`${delivered} ${direct}, then dispatch`);
  await depend(architect, next, cancelled, { reason: 'Initially required scope.' });
  // Unstarted scope is skipped, never abandoned; a successor belongs to the same request.
  expect((await architect.reject('close_work_package', { work_package_id: cancelled, outcome: 'abandoned', rationale: 'Dropped.' }, 'ending_not_allowed')).state).toBe('planned');
  const elsewhere = await factory.client();
  await elsewhere.request('Another request');
  const [foreign] = await elsewhere.addPackages([contract('Foreign successor')]);
  await architect.reject('close_work_package', { work_package_id: cancelled, outcome: 'superseded', successor_work_package_id: foreign, rationale: 'Elsewhere.' }, 'successor_work_package_out_of_scope');
  await architect.call('close_work_package', { work_package_id: cancelled, outcome: 'skipped' });
  const refusal = await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies');
  expect(refusal.state).toBe('planned');
  expect(refusal.prerequisite_work_package_ids.sort()).toEqual([direct, cancelled].sort());
  expect(refusal.next_action).toContain(`${cancelled} ended skipped and never delivers: add a successor that delivers it or remove the dependency`);
  // A finished package's code isn't on the base: it never satisfies a dependent.
  await close(architect, parked, 'finished', {});
  expect((await architect.reject('dispatch_work_package', { work_package_id: later }, 'unmet_work_package_dependencies')).next_action)
    .toBe(`${parked} ended finished and never delivers: remove the dependency or depend on a package that delivers it`);
  await architect.call('edit_plan', { ops: [{ op: 'remove_dependency', from: later, to: parked }] });
  expect((await row(architect, request, cancelled)).raw_status).toBe('ended');
  expect((await row(architect, request, cancelled)).delivery_outcome).toBe('skipped');
  await architect.call('edit_plan', { ops: [{ op: 'remove_dependency', from: next, to: cancelled }] });
  // Retiring scope is not completion; only the delivered end of the chain satisfies it.
  await architect.call('set_blocker', { work_package_id: direct, blocker_id: 'old-attempt', active: true, summary: 'This attempt is blocked.' });
  await close(architect, direct, 'superseded', { successor_work_package_id: successor, rationale: 'A replacement owns the same scope.' });
  expect((await row(architect, request, direct)).work_package.blocker_state['active?']).toBe(false);
  await close(architect, successor, 'superseded', { successor_work_package_id: final, rationale: 'The final attempt owns the same scope.' });
  expect((await architect.reject('dispatch_work_package', { work_package_id: next }, 'unmet_work_package_dependencies')).next_action)
    .toBe(`${delivered} ${final} (successor of ${successor}), then dispatch`);
  expect((await row(architect, request, direct)).successor.work_package_id).toBe(successor);
  expect((await row(architect, request, successor)).successor.work_package_id).toBe(final);
  await close(architect, final);
  expect((await architect.call('dispatch_work_package', { work_package_id: next })).work_package.id).toBe(next);
  for (const wp of [a, b, next, c, d, consumer, e, later]) {
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

test('a PR carrying another package\'s unmerged commits does not qualify until that PR merges', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Stacked commits');
  const [fix, feature] = await architect.addPackages([contract('CI fix'), contract('Feature')]);
  for (const wp of [fix, feature]) await architect.call('dispatch_work_package', { work_package_id: wp });
  // The feature branch merged the unmerged CI fix to get green checks.
  provider.set(301, pr(301, head('a'), { commits: [{ oid: head('a') }] }));
  provider.set(302, pr(302, head('b'), { commits: [{ oid: head('a') }, { oid: head('b') }] }));
  expect((await sync(architect, fix, 301, head('a'))).pr_sync.status).toBe('ready');
  const held = (await sync(architect, feature, 302, head('b'))).pr_sync;
  expect(held.status).toBe('dispatched');
  expect(held.readiness_reasons).toEqual(['stacked_on_unmerged_work']);
  expect(held.next_action).toBe(`remove ${fix}'s unmerged commits, or wait for its PR to merge`);
  // Once the fix is squash-merged, its commits no longer belong to an open PR.
  provider.set(301, pr(301, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('e') }, commits: [{ oid: head('a') }] }));
  await architect.call('sync_pr', { work_package_id: fix });
  expect((await row(architect, request, fix)).delivery_outcome).toBe('pr_merged');
  const qualified = (await sync(architect, feature, 302, head('b'))).pr_sync;
  expect(qualified.readiness_reasons).toEqual([]);
  expect(qualified.status).toBe('ready');
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
    await architect.call('set_blocker', { work_package_id: wp, blocker_id: 'merge-order', active: true, summary: 'External merge bypassed this blocker.' });
    provider.set(number, pr(number, head('d')));
    expect((await sync(architect, wp, number, head('d'))).pr_sync.readiness_reasons).toContain('dependency_not_delivered');
    expect((await row(architect, request, wp)).merge_eligibility.eligible).toBe(false);
    provider.set(number, pr(number, head('d'), { state: 'MERGED', mergedAt: mergeTime, mergeCommit: { oid: head('f') } }));
    await architect.call('sync_pr', { work_package_id: wp, url: prUrl(number) });
    if (wp === replay) {
      // Syncing a merged PR again records nothing new.
      const recorded = (await row(architect, request, wp)).delivery;
      expect(recorded.outcome).toBe('pr_merged');
      await architect.call('sync_pr', { work_package_id: wp, url: prUrl(number) });
      expect((await row(architect, request, wp)).delivery).toEqual(recorded);
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

test('the watcher holds a PR stacked on another package\'s unmerged work until that PR merges, and never unqualifies on an unreadable sibling', async ({ watched: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Watched stacking');
  const [fix, feature, later, retired] = await architect.addPackages(['CI fix', 'Feature', 'Later sibling', 'Retired attempt']
    .map((title, index) => contract(title, { branch_pattern: `feature/delivery-${311 + index}` })));
  for (const wp of [fix, feature, later, retired]) await architect.call('dispatch_work_package', { work_package_id: wp });
  const status = async (wp: string) => (await row(architect, request, wp)).raw_status;
  const commitReads = () => provider.graphql.filter(({ query }) => query.includes('commits(first: 100)')).length;
  const open = (number: number, sha: string, commits: string[], patch: object = {}) =>
    provider.set(number, pr(number, sha, { commits: commits.map((oid) => ({ oid })), ...patch }));
  // A retired package's PR may stay open with commits its successor reuses: it never counts.
  await close(architect, retired, 'superseded', { successor_work_package_id: later, rationale: 'The later sibling owns this scope.' });
  open(314, head('9'), [head('9')]);
  open(311, head('a'), [head('a')]);
  open(312, head('b'), [head('9'), head('b')]);
  await factory.tick('sweep');
  expect(await status(fix)).toBe('ready');
  expect(await status(feature)).toBe('ready');
  // Commit lists are read again only when a head or base moves.
  const reads = commitReads();
  await factory.tick('sweep');
  expect(commitReads()).toBe(reads);
  // An unreadable sibling PR defers the check: a ready package stays ready.
  provider.unreadable.add(311);
  await factory.tick('sweep');
  expect(await status(feature)).toBe('ready');
  expect((await row(architect, request, feature)).work_package.observation_stale).toEqual(['stacking']);
  provider.unreadable.delete(311);
  // The feature branch merged the unmerged CI fix: its ready PR unqualifies.
  open(312, head('c'), [head('9'), head('b'), head('a'), head('c')]);
  await factory.tick('sweep');
  const stacked = await row(architect, request, feature);
  expect(stacked.raw_status).toBe('dispatched');
  expect(stacked.work_package.stacked_on).toEqual([fix]);
  expect(stacked.operational_state.activity_signal.next_action).toBe(`remove ${fix}'s unmerged commits, or wait for its PR to merge`);
  expect(await status(fix)).toBe('ready');
  // Of two PRs sharing unmerged work that neither fully contains, the later one holds.
  open(313, head('d'), [head('a'), head('d')]);
  await factory.tick('sweep');
  expect((await row(architect, request, later)).work_package.stacked_on.sort()).toEqual([fix, feature].sort());
  // Squash-merged: the fix's commits no longer belong to an open PR.
  open(311, head('a'), [head('a')], { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('e') } });
  await factory.tick('sweep');
  expect((await row(architect, request, fix)).delivery_outcome).toBe('pr_merged');
  expect(await status(feature)).toBe('ready');
  expect((await row(architect, request, feature)).work_package.stacked_on).toEqual([]);
  expect((await row(architect, request, later)).work_package.stacked_on).toEqual([feature]);
  // A package's own earlier PR never counts against its replacement.
  const [own, hidden] = await architect.addPackages([
    contract('Own replacement', { branch_pattern: 'feature/delivery-317' }), contract('Hidden PR', { branch_pattern: 'feature/delivery-319' }),
  ]);
  for (const wp of [own, hidden]) await architect.call('dispatch_work_package', { work_package_id: wp });
  open(317, head('7'), [head('7')]);
  await architect.call('sync_pr', { work_package_id: own, url: prUrl(317) });
  open(318, head('8'), [head('7'), head('8')], { headRefName: 'feature/delivery-317',
    statusCheckRollup: [{ name: 'required', status: 'IN_PROGRESS', conclusion: null }] });
  expect((await architect.call('sync_pr', { work_package_id: own, url: prUrl(318) })).work_package.status).toBe('dispatched');
  // A package whose branch lookup fails may hide an open PR: work in its repository waits.
  open(318, head('8'), [head('7'), head('8')], { headRefName: 'feature/delivery-317' });
  provider.unreadableBranches.add('feature/delivery-319');
  await factory.tick('sweep');
  expect(await status(own)).toBe('dispatched');
  expect((await row(architect, request, own)).work_package.observation_stale).toEqual(['stacking']);
  provider.unreadableBranches.delete('feature/delivery-319');
  await factory.tick('sweep');
  const replaced = await row(architect, request, own);
  expect(replaced.raw_status).toBe('ready');
  expect(replaced.work_package.stacked_on).toEqual([]);
});
