import { expect } from 'e2e';
import { test, packages } from '../support/authority.js';
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
