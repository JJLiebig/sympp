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

test('independent PRs qualify alongside history imports whose commit lists are truncated', async ({ watched: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('History imports');
  const sizes = [4, 403, 1737, ...Array(16).fill(1)];
  const numbers = sizes.map((_, index) => 501 + index);
  const packages = await architect.addPackages(numbers.map((number) =>
    contract(`PR ${number}`, { branch_pattern: `feature/delivery-${number}` })));
  for (const wp of packages) await architect.call('dispatch_work_package', { work_package_id: wp });

  const oid = (number: number, index: number) => (number * 10000 + index).toString(16).padStart(40, '0');
  const base = head('0');
  provider.baseTips.set('example/service/beta', base);
  provider.commitParents.set(base, []);
  const chain = (number: number, size: number, parent: string, offset = 0) => Array.from({ length: size }, (_, index) => {
    const sha = oid(number, offset + index);
    provider.commitParents.set(sha, [parent]);
    parent = sha;
    return sha;
  });
  const open = (number: number, commits: string[], sha = commits.at(-1)!) =>
    provider.set(number, pr(number, sha, { commits: commits.map((oid) => ({ oid })) }));
  for (const [index, number] of numbers.entries()) {
    open(number, chain(number, sizes[index], base));
  }

  // Hold the first pair open while the second starts. The watcher must make
  // progress on comparisons even while an earlier provider request is waiting.
  const branches = packages.map((wp, index) => ({ wp, head: oid(numbers[index], sizes[index] - 1), size: sizes[index] }))
    .sort((left, right) => left.wp.localeCompare(right.wp));
  const comparePath = (left: string, right: string) => `/repos/example/service/compare/${[left, right].sort().join('...')}?per_page=1&page=2`;
  const pairs = branches.flatMap((left, index) => branches.slice(index + 1)
    .filter((right) => left.size > 250 || right.size > 250).map((right) => comparePath(left.head, right.head)));
  const first = provider.pauseHttpReply(pairs[0]);
  const second = provider.pauseHttpReply(pairs[1]);
  const cold = factory.tick('sweep');
  try {
    await Promise.all([first.started, second.started]);
  } finally {
    first.release();
    second.release();
  }
  await cold;
  const [candidate, imported] = packages;
  const [candidateNumber, importNumber] = numbers;
  const candidateHead = oid(candidateNumber, 3);
  expect((await row(architect, request, candidate)).raw_status).toBe('ready');
  expect((await row(architect, request, imported)).raw_status).toBe('ready');
  // A cold sweep reads one snapshot, one short-list batch, each long-PR pair
  // once, and at most one common-history proof read per pair.
  expect(provider.graphql.length).toBe(2);
  expect(provider.rest.filter((path) => pairs.includes(path)).sort()).toEqual([...pairs].sort());
  const coldRest = provider.rest.length;
  expect(coldRest).toBeLessThanOrEqual(70);
  await factory.tick('sweep');
  expect([provider.graphql.length, provider.rest.length]).toEqual([3, coldRest]);
  expect((await sync(architect, candidate, candidateNumber, candidateHead)).pr_sync.readiness_reasons).toEqual([]);
  expect(provider.rest.slice(coldRest)).toEqual(['/repos/example/service/git/ref/heads/beta']);

  // One unreadable comparison holds just the two affected PRs. They can
  // recover on the same heads as soon as the comparison works again.
  const importCommits = chain(importNumber, sizes[1] + 1, base);
  const importHead = importCommits.at(-1)!;
  open(importNumber, importCommits);
  const unavailable = [candidateHead, importHead].sort().join('...');
  provider.unreadableComparisons.add(unavailable);
  const beforeFailure = provider.rest.length;
  await factory.tick('sweep');
  expect(provider.rest.slice(beforeFailure).filter((path) => path === comparePath(candidateHead, importHead))).toHaveLength(1);
  const stale = (await architect.board(request, 'full')).work_packages
    .filter((item: any) => item.work_package.observation_stale.includes('stacking')).map((item: any) => item.id);
  expect(stale.sort()).toEqual([candidate, imported].sort());
  expect((await sync(architect, candidate, candidateNumber, candidateHead)).pr_sync.readiness_reasons).toEqual(['stacking_unknown']);
  provider.unreadableComparisons.delete(unavailable);
  await factory.tick('sweep');
  expect((await row(architect, request, candidate)).work_package.observation_stale).toEqual([]);

  // The older PR picked up the entire history import. Containment wins over
  // PR creation order, including when neither commit list is complete.
  const stackedCommits = chain(candidateNumber, 251, importHead, 1000);
  const stackedHead = stackedCommits.at(-1)!;
  open(candidateNumber, [...importCommits, ...stackedCommits]);
  await factory.tick('sweep');
  const stacked = await row(architect, request, candidate);
  expect(stacked.raw_status).toBe('dispatched');
  expect(stacked.work_package.stacked_on).toEqual([imported]);
  const synced = (await sync(architect, candidate, candidateNumber, stackedHead)).pr_sync;
  expect(synced.readiness_reasons).toEqual(['stacked_on_unmerged_work']);
  expect(synced.next_action).toBe(`remove ${imported}'s unmerged commits, or wait for its PR to merge`);

  // The target branch can advance while the PR heads and recorded base OIDs
  // stay fixed. The shared commits are part of the base now.
  provider.baseTips.set('example/service/beta', importHead);
  open(candidateNumber, stackedCommits);
  open(importNumber, [], importHead);
  await factory.tick('sweep');
  const qualified = await row(architect, request, candidate);
  expect(qualified.raw_status).toBe('ready');
  expect(qualified.work_package.stacked_on).toEqual([]);
});

test('a reachable merge base cannot clear a comparison with additional common history', async ({ watched: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('Two merge bases');
  const [older, later] = await architect.addPackages([contract('Long import', { branch_pattern: 'feature/delivery-551' }),
    contract('Feature', { branch_pattern: 'feature/delivery-552' })]);
  for (const wp of [older, later]) await architect.call('dispatch_work_package', { work_package_id: wp });

  const [root, merged, unmerged, feature, join] = ['0', '1', '2', '3', '4'].map(head);
  provider.baseTips.set('example/service/beta', merged);
  for (const [sha, parents] of [[root, []], [merged, [root]], [unmerged, [root]], [feature, [merged, unmerged]], [join, [unmerged, merged]]] as const) {
    provider.commitParents.set(sha, [...parents]);
  }
  const incoming = [unmerged, join];
  for (let index = 0; index < 251; index++) {
    const sha = (60000 + index).toString(16).padStart(40, 'e');
    provider.commitParents.set(sha, [incoming.at(-1)!]);
    incoming.push(sha);
  }
  provider.set(551, pr(551, incoming.at(-1)!, { commits: incoming.map((oid) => ({ oid })) }));
  provider.set(552, pr(552, feature, { commits: [unmerged, feature].map((oid) => ({ oid })) }));
  await factory.tick('sweep');
  // The compare endpoint returns `merged`, but both heads also contain `unmerged`.
  const observed = await row(architect, request, later);
  expect(observed.raw_status).toBe('dispatched');
  expect(observed.work_package.observation_stale).toEqual(['stacking']);
});

test('a long PR on an older target can be stacked on a newer PR targeting another branch', async ({ watched: { factory, provider } }) => {
  const release = await factory.client();
  const releaseRequest = await release.request('Release backport', 'release');
  const [backport] = await release.addPackages([contract('Long backport', { branch_pattern: 'feature/delivery-581' })]);
  const main = await factory.client();
  const mainRequest = await main.request('Main feature');
  const [feature] = await main.addPackages([contract('Main feature', { branch_pattern: 'feature/delivery-582' })]);
  await release.call('dispatch_work_package', { work_package_id: backport });
  await main.call('dispatch_work_package', { work_package_id: feature });

  const [root, beta, featureHead] = ['0', '1', '2'].map(head);
  provider.baseTips.set('example/service/beta', beta);
  provider.baseTips.set('example/service/release', root);
  provider.commitParents.set(root, []);
  provider.commitParents.set(beta, [root]);
  provider.commitParents.set(featureHead, [beta]);
  const commits = [beta, featureHead];
  for (let index = 0; index < 251; index++) {
    const sha = (70000 + index).toString(16).padStart(40, 'f');
    provider.commitParents.set(sha, [commits.at(-1)!]);
    commits.push(sha);
  }
  const backportHead = commits.at(-1)!;
  provider.set(581, pr(581, backportHead, { baseRefName: 'release', commits: commits.map((oid) => ({ oid })) }));
  provider.set(582, pr(582, featureHead, { baseRefOid: beta }));

  await factory.tick('sweep');
  expect((await row(main, mainRequest, feature)).raw_status).toBe('ready');
  expect((await row(release, releaseRequest, backport)).work_package.stacked_on).toEqual([feature]);
  expect((await sync(release, backport, 581, backportHead)).pr_sync.next_action).toBe(`remove ${feature}'s unmerged commits, or wait for its PR to merge`);
});
