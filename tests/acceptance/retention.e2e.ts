import { expect } from 'e2e';
import { test, packages } from '../support/authority.js';
import { contract } from '../support/factory.js';
import { ageHistory, archives, detail, requestPath, retention, unstarted } from '../support/retention-history.js';

test('never-started retention uses creation age and restore age without inventing completion or deleting history', async ({ processes }) => {
  let factory = processes.factory();
  let client = await factory.client();
  const old = await unstarted(client, 'Unstarted old goal');
  const fresh = await unstarted(client, 'Recent goal');
  await client.call('record_decision', { source_type: 'operator', work_request_id: old, decision: 'History must survive archival.', rationale: 'Retention', scope_impact: 'None', created_by: 'acceptance' });
  expect((await client.operator(`${requestPath(old)}/archive`, {})).body.error.code).toBe('not_completed');
  await ageHistory(factory, [{ table: 'sympp_work_requests', id: old, column: 'inserted_at', days: 31 }]);
  factory = processes.factory();
  client = await factory.client();
  // This edit is deliberately recent; it must not restart creation-age retention.
  await client.call('record_decision', { source_type: 'operator', work_request_id: old, decision: 'Recent activity is not a restore.', rationale: 'Retention', scope_impact: 'None', created_by: 'acceptance' });
  expect((await archives(client)).map((row: any) => row.id)).not.toContain(old);
  await retention(client);
  const archived = (await archives(client)).find((row: any) => row.id === old);
  expect(archived.archive_reason).toBe('never_started');
  expect(archived.completed_at).toBeNull();
  expect(archived.operational_state.key).toBe('archived');
  expect((await detail(client, old)).phase).toBe('archived');
  expect((await archives(client)).map((row: any) => row.id)).not.toContain(fresh);
  await ageHistory(factory, [{ table: 'sympp_work_requests', id: old, column: 'archived_at', days: 90 }]);
  factory = processes.factory();
  client = await factory.client();
  await retention(client, 60);
  expect((await archives(client)).map((row: any) => row.id)).toContain(old);
  expect((await client.call('read_work_request', { detail: 'full', work_request_id: old })).decision_log_entries).toHaveLength(2);
  expect((await client.operator(`${requestPath(old)}/restore`, {})).status).toBe(200);
  await retention(client);
  expect((await archives(client)).map((row: any) => row.id)).not.toContain(old);
  expect((await detail(client, old)).completed_at).toBeNull();
  await ageHistory(factory, [{ table: 'sympp_work_requests', id: old, column: 'restored_at', days: 31 }]);
  factory = processes.factory();
  client = await factory.client();
  await retention(client);
  expect((await archives(client)).map((row: any) => row.id)).toContain(old);
  expect((await client.operator(`${requestPath(old)}/delete`, {})).status).toBe(200);
  expect((await client.operator(`${requestPath(old)}/restore`, {})).status).toBe(404);
  expect((await detail(client, fresh)).id).toBe(fresh);
});

test('dispatched work protects old goals while completed retention restores and deletes deliberately', async ({ processes }) => {
  let factory = processes.factory();
  let client = await factory.client();
  const owned = await client.request('Owned request without packages');
  const dispatched = await client.request('Dispatched work protects old request');
  await packages(client, ['Actually dispatched']);
  const finished = await unstarted(client, 'Finished goal');
  const unfinished = await unstarted(client, 'Unfinished comparison');
  await client.call('record_decision', { source_type: 'operator', work_request_id: finished, decision: 'Keep until deliberate deletion.', rationale: 'Retention', scope_impact: 'None', created_by: 'acceptance' });
  expect((await client.operator(`${requestPath(finished)}/complete`, {})).status).toBe(200);
  await ageHistory(factory, [
    ...[owned, dispatched].map((id) => ({ table: 'sympp_work_requests' as const, id, column: 'inserted_at' as const, days: 90 })),
    { table: 'sympp_work_requests', id: finished, column: 'operator_completed_at', days: 4 },
  ]);
  factory = processes.factory();
  client = await factory.client();
  expect((await archives(client)).map((row: any) => row.id)).not.toContain(finished);
  await retention(client);
  const archived = await archives(client);
  const ids = archived.map((row: any) => row.id);
  expect(ids).toContain(finished);
  // An owned WorkRequest without packages is still intake, so it ages out like any never-started goal.
  expect(archived.find((row: any) => row.id === owned).archive_reason).toBe('never_started');
  for (const id of [dispatched, unfinished]) expect(ids).not.toContain(id);
  expect((await client.operator(`${requestPath(finished)}/restore`, {})).status).toBe(200);
  await retention(client);
  expect((await archives(client)).map((row: any) => row.id)).not.toContain(finished);
  expect((await detail(client, finished)).completed_at).toBeTruthy();
  expect((await client.operator(`${requestPath(finished)}/archive`, {})).status).toBe(200);
  await ageHistory(factory, [{ table: 'sympp_work_requests', id: finished, column: 'archived_at', days: 31 }]);
  factory = processes.factory();
  client = await factory.client();
  await retention(client);
  expect((await client.operator(`${requestPath(finished)}/restore`, {})).status).toBe(404);
  // Deliberate deletion also supports an unfinished, never-archived goal.
  expect((await client.operator(`${requestPath(unfinished)}/delete`, {})).status).toBe(200);
  expect((await client.operator(`${requestPath(unfinished)}/restore`, {})).status).toBe(404);
  expect((await detail(client, owned)).id).toBe(owned);
});

test('every phase follows actual delivery, open asks never change it, and a successor decides whether superseded scope resolves', async ({ processes }) => {
  const factory = processes.factory();
  const client = await factory.client();
  const phase = async (id: string) => (await client.call('read_work_request', { work_request_id: id })).work_request;
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const ask = (id: string) => chief.call('ask', { work_request_id: id, question: 'Anything else?' });
  const end = (work_package_id: string, outcome: string, extra: object = {}) => client.call('close_work_package', { work_package_id, outcome, ...extra });
  const noPr = { evidence: 'Delivered without a PR.' };
  const intake = await client.request('Phase intake');
  await ask(intake);
  expect((await phase(intake)).phase).toBe('intake');
  const planned = await client.request('Phase planned');
  const [delivered] = await packages(client, ['Delivered early']);
  await end(delivered, 'completed_no_pr', noPr);
  await client.addPackages([contract('Still planned')]);
  expect((await phase(planned)).phase).toBe('planned');
  const active = await client.request('Phase active');
  await packages(client, ['In flight']);
  await client.addPackages([contract('Later')]);
  expect((await phase(active)).phase).toBe('active');
  const done = await client.request('Phase done');
  const [noPrWp, finished, abandonedLater] = await packages(client, ['No PR', 'Finished', 'Abandoned']);
  const [skipped] = await client.addPackages([contract('Skipped')]);
  await end(noPrWp, 'completed_no_pr', noPr);
  await end(finished, 'finished');
  await end(skipped, 'skipped');
  // Ready-or-active work beside an abandoned package is still active.
  await end(abandonedLater, 'abandoned', { rationale: 'Retired scope.' });
  await ask(done);
  expect((await phase(done)).phase).toBe('unresolved');
  const resolved = await client.request('Phase resolved by delivery');
  const [onlyDelivery, onlyFinished] = await packages(client, ['Only delivery', 'Only finished']);
  await end(onlyDelivery, 'completed_no_pr', noPr);
  await end(onlyFinished, 'finished');
  await ask(resolved);
  // Delivery truth stays primary over an open ask.
  expect((await phase(resolved)).phase).toBe('done');
  expect((await phase(done))).toMatchObject({ phase: 'unresolved', next_action: 'complete_or_archive' });

  // A superseded package resolves only through its successor in the same request.
  const successor = await client.request('Phase successor');
  const [original] = await packages(client, ['Original scope']);
  const [replacement] = await client.addPackages([contract('Replacement scope')]);
  await client.reject('close_work_package', { work_package_id: original, outcome: 'superseded', successor_work_package_id: delivered, rationale: 'Elsewhere.' }, 'successor_work_package_out_of_scope');
  await end(original, 'superseded', { successor_work_package_id: replacement, rationale: 'Replace the original scope.' });
  expect((await phase(successor)).phase).toBe('planned');
  await client.call('dispatch_work_package', { work_package_id: replacement });
  await end(replacement, 'abandoned', { rationale: 'The successor was dropped too.' });
  expect((await phase(successor)).phase).toBe('unresolved');
  const chain = await client.request('Phase finished successor');
  const [first] = await packages(client, ['First scope']);
  const [second] = await packages(client, ['Second scope']);
  await end(first, 'superseded', { successor_work_package_id: second, rationale: 'Recut.' });
  await end(second, 'finished');
  expect((await phase(chain)).phase).toBe('done');

  // Explicit operator completion is authoritative; archive and restore keep it.
  for (const id of [planned, done]) expect((await client.operator(`/api/v1/sympp/operator/work-requests/${id}/complete`, {})).body.work_request.phase).toBe('done');
  const again = await client.operator(`/api/v1/sympp/operator/work-requests/${done}/complete`, {});
  expect(again.body.work_request.operator_completed_at).toBeTruthy();
  for (const id of [intake, active]) expect((await client.operator(`/api/v1/sympp/operator/work-requests/${id}/archive`, {})).body.error.code).toBe('not_completed');
  expect((await client.operator(`/api/v1/sympp/operator/work-requests/${successor}/archive`, {})).body.work_request.archive_reason).toBe('manual');
  expect((await client.operator(`/api/v1/sympp/operator/work-requests/${successor}/archive`, {})).status).toBe(200);
  expect((await phase(successor))).toMatchObject({ phase: 'archived', next_action: 'restore' });
  const listed = async (phaseName: string) => (await client.call('list_work_requests', { phase: phaseName })).work_requests.map((entry: any) => entry.id).sort();
  expect(await listed('archived')).toEqual([successor]);
  expect(await listed('done')).toEqual([planned, done, resolved, chain].sort());
  expect((await client.operator(`/api/v1/sympp/operator/work-requests/${successor}/restore`, {})).status).toBe(200);
  expect((await client.operator(`/api/v1/sympp/operator/work-requests/${successor}/restore`, {})).status).toBe(200);
  const back = await detail(client, successor);
  expect([back.phase, back.archived_at]).toEqual(['unresolved', null]);
});
