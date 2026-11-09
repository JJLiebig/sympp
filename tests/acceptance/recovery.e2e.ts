import { expect } from 'e2e';
import { realpath } from 'node:fs/promises';
import { Client, contract, herdr, nextTerminal } from '../support/factory.js';
import { initialize, packages, snapshot, test, tool } from '../support/authority.js';

const description = 'Synthetic acceptance request; no external work is executed.';
const decodeBinding = (value: string | null) => value && JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));

test('competing terminals end with one owner, Release hands over and ownership survives a restart', async ({ processes }) => {
  let factory = processes.factory();
  const chief = await factory.client(nextTerminal(), { 'sympp.role': 'chief', 'sympp.domain': 'Acceptance' });
  const created = await chief.call('create_work_request', {
    repo: 'example/service', base_branch: 'beta', title: 'Contended request', description,
    work_type: 'feature', own: false,
  });
  const request = created.work_request.id;
  expect(created.worked_on).toBeUndefined();
  expect(created.next_action).toContain(request);
  expect((await chief.call('read_work_request', { detail: 'full', work_request_id: request })).work_request.dispatched_by).toEqual({ kind: 'chief', domain: 'Acceptance' });
  // Reads never take ownership.
  const contenders = await Promise.all([factory.client(), factory.client()]);
  for (const contender of contenders) await contender.call('read_work_request', { detail: 'full', work_request_id: request });
  for (const contender of contenders) expect((await contender.call('sympp.health')).caller.owns).toEqual([]);
  const results = await Promise.all(contenders.map((contender, index) => contender.tool('set_report', { work_request_id: request, brief: `Contender ${index}` })));
  const won = results.findIndex((result) => result.result);
  expect(results.filter((result) => result.result)).toHaveLength(1);
  const winner = contenders[won];
  const loser = contenders[1 - won];
  const refused = results[1 - won].error.data;
  expect(refused.code).toBe('owned_by_other_terminal');
  expect(refused.owner.address).toBe(winner.address);
  expect(refused.next_action).toBe(`ask ${winner.address}, or wait until it finishes`);
  expect((await winner.call('read_work_request', { detail: 'full', work_request_id: request })).work_request.operator_report.brief.text).toBe(`Contender ${won}`);
  // The pane label follows the owner-gated write, never a read.
  const write = await winner.raw({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: winner.toolParams('set_report', { work_request_id: request, eta: 'Soon' }) });
  expect(decodeBinding(write.binding)).toEqual({ role: 'architect', work_request_id: request, show_inspector: true });
  const read = await loser.raw({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: loser.toolParams('read_work_request', { work_request_id: request }) });
  expect(read.binding).toBeNull();

  const [wp] = (await winner.addPackages([contract('Owned work')], { work_request_id: request }));
  await winner.call('dispatch_work_package', { work_package_id: wp });
  const mutation = { work_package_id: wp, blocker_id: 'once', active: true, summary: 'Accepted exactly once' };
  expect((await winner.call('set_blocker', mutation)).changed).toBe(true);
  // A new agent in the same terminal (restart, compact or /clear) keeps ownership; the blocker is already set.
  const sameTerminal = await factory.client(winner.terminal);
  expect((await sameTerminal.call('set_blocker', mutation)).changed).toBe(false);
  await loser.reject('set_blocker', { ...mutation, blocker_id: 'stolen' }, 'owned_by_other_terminal');
  expect((await winner.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress.filter((event: any) => event.summary === mutation.summary)).toHaveLength(1);

  // A caller outside Herdr reads but cannot write.
  const outside = await factory.client(null);
  expect((await outside.call('sympp.health')).caller.access).toBe('read_only');
  expect((await outside.call('read_work_request', { detail: 'full', work_request_id: request })).work_request.id).toBe(request);
  await outside.reject('set_report', { work_request_id: request, brief: 'Outside' }, 'read_only_outside_herdr');
  await outside.reject('create_work_request', { repo: 'example/service', base_branch: 'beta', title: 'Outside goal', description, work_type: 'feature' }, 'read_only_outside_herdr');

  // The board shows who works on the request; operator Release hands it over.
  const board = await winner.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  expect(board.work_request_details.find((entry: any) => entry.work_request.id === request).work_request.worked_on.address).toBe(winner.address);
  const path = `/api/v1/sympp/operator/work-requests/${request}/release`;
  expect((await winner.raw({}, { origin: 'https://example.invalid' }, 'POST', path)).status).toBe(401);
  expect((await winner.operator(path, {})).status).toBe(200);
  expect((await winner.operator(path, {})).status).toBe(409);
  await loser.call('set_report', { work_request_id: request, brief: 'Taken over after Release' });
  const back = await winner.reject('set_blocker', { ...mutation, blocker_id: 'after-release' }, 'owned_by_other_terminal');
  expect(back.owner.address).toBe(loser.address);

  // After a backend restart the MCP session is gone, but ownership is not.
  await factory.stop();
  factory = processes.factory();
  const stale = await loser.reconnect(await factory.endpoint).raw(tool('sympp.health'));
  expect(stale.status).toBe(404);
  expect(stale.body.error.data.reason).toBe('unknown_state_key');
  const resumed = await factory.client(loser.terminal);
  expect((await resumed.call('sympp.health')).caller.owns.map((entry: any) => entry.work_request_id)).toEqual([request]);
  await resumed.call('set_report', { work_request_id: request, brief: 'Still mine after restart' });
  await (await factory.client(winner.terminal)).reject('set_report', { work_request_id: request, brief: 'Not mine' }, 'owned_by_other_terminal');
});

test('a supported disposable offline snapshot denies MCP and dispatch without changing the source ledger', async ({ processes }) => {
  const source = processes.factory();
  const architect = await source.client();
  const request = await architect.request('Offline denial');
  const [wp] = await packages(architect, ['Snapshot work']);
  await source.stop();
  const database = await snapshot(source);
  const offline = processes.factory('offline', { database, offline: true });
  const client = new Client(await offline.endpoint, offline.receipt);
  for (const payload of [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: initialize },
    { ...tool('set_report', { work_request_id: request, brief: 'Must not write' }), params: { name: 'set_report', arguments: { work_request_id: request, brief: 'Must not write' }, _meta: { herdr: herdr('t-offline') } } },
    tool('record_decision', { work_request_id: request, source_type: 'operator', decision: 'Must not write', rationale: 'Offline', scope_impact: 'None', created_by: 'offline' }),
  ]) {
    const refused = await client.raw(payload);
    expect(refused.status).toBe(403);
    expect(refused.body.error.data.reason).toBe('offline_sandbox');
  }
  const restarted = processes.factory();
  const original = await restarted.client(architect.terminal);
  expect((await original.call('read_work_request', { detail: 'full', work_request_id: request })).work_packages[0].status).toBe('dispatched');
  expect((await original.call('read_work_request', { detail: 'full', work_request_id: request })).decision_log_entries).toEqual([]);
});

test('backend restart keeps the ledger and its owner but a different ledger refuses the old session', async ({ processes }) => {
  const original = processes.factory();
  const architect = await original.client();
  const request = await architect.request('Durable identity');
  const [wp] = await packages(architect, ['Survives restart']);
  const health = await architect.call('sympp.health');
  const ledgerPath = await realpath(original.database);
  const mutation = { work_package_id: wp, blocker_id: 'restart-once', active: true, summary: 'Survives a real backend stop' };
  expect((await architect.call('set_blocker', mutation)).changed).toBe(true);
  await original.stop();
  const restarted = processes.factory('factory');
  const recovered = await restarted.client(architect.terminal);
  expect((await recovered.call('sympp.health')).ledger.identity).toEqual(health.ledger.identity);
  expect(await realpath(restarted.database)).toBe(ledgerPath);
  expect((await recovered.call('set_blocker', mutation)).changed).toBe(false);
  expect((await recovered.call('read_work_request', { detail: 'full', work_request_id: request })).work_packages[0].status).toBe('dispatched');
  const outsider = processes.factory('foreign-ledger');
  const wrongLedger = recovered.reconnect(await outsider.endpoint);
  const denied = await wrongLedger.raw(tool('set_blocker', mutation));
  expect(denied.status).toBe(404);
  expect(denied.body.error.data.reason).toBe('unknown_state_key');
  const fresh = await outsider.client();
  expect(await realpath(outsider.database)).not.toBe(ledgerPath);
  expect((await fresh.rpc('tools/call', { name: 'read_work_request', arguments: { detail: 'full', work_request_id: request } })).error.data.code).toBe('not_found');
  expect((await fresh.call('sympp.health')).caller.owns).toEqual([]);
  expect((await recovered.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).blockers.filter((entry: any) => entry.id === 'restart-once' && entry.active)).toHaveLength(1);
});

test('failed calls are counted durably by tool and reason, never with their arguments', async ({ processes }) => {
  const factory = processes.factory();
  const client = await factory.client();
  const secret = 'Bearer synthetic-diagnostic-secret';
  const denied = await client.raw(tool('set_blocker', { nested: { authorization: secret }, [secret]: secret }));
  expect(denied.body.error.data).toMatchObject({ code: 'read_only_outside_herdr', state: null });
  expect(typeof denied.body.error.data.message).toBe('string');
  expect(typeof denied.body.error.data.next_action).toBe('string');
  expect(JSON.stringify(denied.body)).not.toContain('synthetic-diagnostic-secret');
  expect((await client.raw(tool(`missing-${secret}`, {}))).body.error.data.code).toBe('method_not_found');
  const summary = await client.call('summarize_failed_mcp_calls');
  expect(summary.total).toBe(2);
  expect(summary.failures.map(({ tool: name, reason, layer, count }: any) => ({ tool: name, reason, layer, count }))
    .sort((a: any, b: any) => a.tool.localeCompare(b.tool))).toEqual([
    { tool: 'set_blocker', reason: 'read_only_outside_herdr', layer: 'tool', count: 1 },
    { tool: 'unknown', reason: 'method_not_found', layer: 'tool', count: 1 },
  ]);
  expect(JSON.stringify(summary)).not.toContain('synthetic-diagnostic-secret');
  expect((await client.call('summarize_failed_mcp_calls', { tool: 'set_blocker' })).total).toBe(1);
});

test('STDIO initialization serves trusted local reads, refuses writes outside Herdr and respects ownership', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('STDIO authority');
  const [wp] = await packages(architect, ['Local transport']);
  const reader = processes.stdio('stdio-reader', { database: factory.database });
  const before = await reader.rawRequest('tools/call', { name: 'read_work_request', arguments: { work_request_id: request } });
  expect(before.error.data.reason).toBe('server_not_initialized');
  const initialized = await reader.request('initialize', initialize);
  expect(initialized.serverInfo.name).toBe('sympp');
  expect(initialized.serverInfo.version).toBeTruthy();
  expect(initialized.capabilities.tools).toEqual({});
  expect(initialized.capabilities.resources).toEqual({});
  expect((await reader.rawRequest('tools/call', { name: 'mint_worker_grant', arguments: {} })).error.code).toBe(-32601);
  const health = (await reader.request('tools/call', { name: 'sympp.health', arguments: {} })).structuredContent;
  expect(health.status).toBe('ok');
  expect(health.ledger.reachable).toBe(true);
  expect(health.ledger.identity.kind).toBe('sqlite');
  expect(health.ledger.identity.source).toBe('explicit');
  expect(health.caller.access).toBe('read_only');
  const peer = processes.stdio('stdio-peer', { database: factory.database });
  const createArgs = { repo: 'example/service', base_branch: 'beta', title: 'STDIO goal', work_type: 'feature', description: 'Created over STDIO.' };
  expect((await peer.rawRequest('tools/call', { name: 'create_work_request', arguments: createArgs })).error.data.reason).toBe('server_not_initialized');
  await peer.request('initialize', initialize);
  expect((await peer.request('tools/call', { name: 'read_work_request', arguments: { detail: 'full', work_request_id: request } })).structuredContent.work_request.id).toBe(request);
  const packageView = await peer.request('tools/call', { name: 'read_work_request', arguments: { work_request_id: request, view: 'package', work_package_id: wp } });
  expect(packageView.structuredContent.work_package.id).toBe(wp);
  expect((await peer.rawRequest('tools/call', { name: 'create_work_request', arguments: createArgs })).error.data.code).toBe('read_only_outside_herdr');
  const meta = { herdr: herdr('t-stdio') };
  const created = (await peer.request('tools/call', { name: 'create_work_request', arguments: createArgs, _meta: meta })).structuredContent;
  expect(created.worked_on.address).toBe('acceptance/t-stdio');
  const blocker = { work_package_id: wp, blocker_id: 'stdio-foreign', active: true, summary: 'Not the owner' };
  expect((await peer.rawRequest('tools/call', { name: 'set_blocker', arguments: blocker, _meta: meta })).error.data.code).toBe('owned_by_other_terminal');
  expect((await peer.rawRequest('tools/call', { name: 'set_blocker', arguments: blocker })).error.data.code).toBe('read_only_outside_herdr');
  const note = await peer.rawRequest('tools/call', { name: 'record_decision', arguments: {
    work_request_id: request, source_type: 'operator', decision: 'Untrusted operator', rationale: 'STDIO', scope_impact: 'None', created_by: 'stdio-worker',
  } });
  expect(note.error.data.code).toBe('read_only_outside_herdr');
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: request })).decision_log_entries).toEqual([]);
  expect((await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress.map((entry: any) => entry.summary)).not.toContain('Not the owner');
});

test('STDIO protocol errors and batches cannot smuggle identity across requests', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Batch authority');
  const [first] = await packages(architect, ['First batch package']);
  const candidate = processes.stdio('protocol', { database: factory.database });
  expect((await candidate.rawRequest('initialize')).error.data.reason).toBe('missing_protocol_version');
  expect((await candidate.rawRequest('initialize', { protocolVersion: '2025-03-26' })).error.data.reason).toBe('invalid_initialize_params');
  expect((await candidate.rawRequest('initialize', [] as any)).error.data.reason).toBe('params_must_be_object');
  expect((await candidate.rawPayload({ jsonrpc: '2.0', method: 'initialize', params: initialize })).error.data.reason).toBe('initialize_requires_id');
  expect((await candidate.request('initialize', { ...initialize, protocolVersion: '2024-11-05' })).protocolVersion).toBe('2025-03-26');
  expect((await candidate.rawRequest('initialize', initialize)).error.data.reason).toBe('already_initialized');
  for (const [payload, key, reason] of [
    [{ jsonrpc: '1.0', id: 910 }, 910, 'invalid_jsonrpc_version'],
    [{ jsonrpc: '1.0', method: 'initialize' }, null, 'invalid_jsonrpc_version'],
    [{ jsonrpc: '2.0', id: 911 }, 911, 'missing_method'],
    [{ jsonrpc: '2.0', id: {}, method: 'tools/call', params: { name: 'set_blocker', arguments: { work_package_id: first }, _meta: { herdr: herdr('t-batch') } } }, null, 'invalid_request_id'],
    [{ jsonrpc: '2.0', id: [], method: 'tools/list' }, null, 'invalid_request_id'],
    [{ id: {}, method: 'initialize', params: {} }, null, 'invalid_request_id'],
    [{ jsonrpc: '2.0', id: 912, method: 42 }, 912, 'invalid_method'],
    [{ jsonrpc: '2.0', id: 913, method: 'tools/list', params: 'bad' }, 913, 'params_must_be_object_or_array'],
    [{ id: null, method: 'initialize', params: {} }, null, 'invalid_jsonrpc_version'],
    [{ method: 'initialize', params: {} }, null, 'request_must_be_object'],
    [{ id: 916, method: 123 }, 916, 'invalid_method'],
    [[], null, 'empty_batch'],
    [[{ jsonrpc: '2.0', id: 914, method: 'initialize', params: initialize }], null, 'initialize_must_be_standalone'],
  ] as const) expect((await candidate.rawPayload(payload, key)).error.data.reason).toBe(reason);
  for (const method of ['tools/list', 'tools/call', 'resources/list', 'resources/read']) {
    expect((await candidate.rawPayload({ jsonrpc: '2.0', id: 915, method, params: [] }, 915)).error.data.reason).toBe('params_must_be_object');
  }
  expect((await candidate.request('tools/call', { name: 'sympp.health', arguments: {} })).structuredContent.caller.access).toBe('read_only');
  const catalog = await candidate.request('tools/list');
  const mixed = await candidate.rawPayload([
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 'version', method: 'resources/read', params: { uri: 'sympp://health/version' } },
  ]);
  expect(mixed).toHaveLength(1);
  expect(mixed[0].id).toBe('version');
  expect(JSON.parse(mixed[0].result.contents[0].text).source.revision).toBe(process.env.ACCEPTANCE_CHECKOUT_SHA);
  expect(JSON.parse(mixed[0].result.contents[0].text).mode).toBe('stdio');
  const batchTool = (id: number, name: string, args: object = {}, meta?: object) => ({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
  const owner = { herdr: herdr(architect.terminal!) };
  const blocker = (key: string) => ({ work_package_id: first, blocker_id: key, active: true, summary: key });
  // Each request carries its own identity: a batch cannot lend one request's terminal to another.
  const denied = await candidate.rawPayload([
    [{ jsonrpc: '2.0', id: 920, method: 'tools/list' }],
    batchTool(921, 'set_blocker', blocker('batch-before')),
    batchTool(922, 'set_blocker', blocker('batch-other'), { herdr: herdr('t-batch-other') }),
    batchTool(923, 'set_blocker', blocker('batch-owner'), owner),
    batchTool(924, 'set_blocker', blocker('batch-after')),
    batchTool(925, 'read_work_request', { work_request_id: 'foreign' }),
  ]);
  expect(denied[0].error.data.reason).toBe('request_must_be_object');
  expect(denied[1].error.data.code).toBe('read_only_outside_herdr');
  expect(denied[2].error.data.code).toBe('owned_by_other_terminal');
  expect(denied[3].result.structuredContent.blocker.summary).toBe('batch-owner');
  expect(denied[4].error.data.code).toBe('read_only_outside_herdr');
  expect(denied[5].error.data.code).toBe('not_found');
  const summaries = (await architect.inspect(`/api/v1/sympp/operator/work-packages/${first}`)).progress.map((entry: any) => entry.summary);
  expect(summaries).toContain('batch-owner');
  for (const key of ['batch-before', 'batch-other', 'batch-after']) expect(summaries).not.toContain(key);
  expect(await candidate.request('tools/list')).toEqual(catalog);
  // A following response is the barrier: blank/CRLF lines and notifications
  // must neither emit replies nor stop processing the stream.
  const before = candidate.protocolLineCount;
  candidate.process.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: {} }) + '\n');
  candidate.process.stdin.write('\r\n' + JSON.stringify([{ jsonrpc: '2.0', method: 'notifications/initialized' }, { jsonrpc: '2.0', method: 'notifications/cancelled' }]) + '\r\n');
  await candidate.request('tools/list');
  expect(candidate.protocolLineCount).toBe(before + 1);
});

test('HTTP client leases preserve local request boundaries and a clean detach ends that terminal\'s ownership', async ({ processes }) => {
  const factory = processes.factory();
  const client = new Client(await factory.endpoint, factory.receipt);
  const readiness = await client.raw(null, {}, 'GET', '/mcp/readiness');
  expect(readiness.status).toBe(200);
  expect(readiness.body.source.revision).toBe(process.env.ACCEPTANCE_CHECKOUT_SHA);
  expect(readiness.body.ledger.identity.default_home).toBe(false);
  expect((await client.raw(tool('sympp.health'))).body.error.data.reason).toBe('missing_session_id');
  for (const path of ['/mcp/readiness', '/mcp/client-lease']) {
    const method = path.endsWith('readiness') ? 'GET' : 'POST';
    for (const [headers, reason] of [[{ origin: 'https://example.invalid' }, 'origin_not_allowed'], [{ 'x-forwarded-for': '127.0.0.1' }, 'local_only']] as const) {
      const refused = await client.raw({ client_id: 'denied-client', action: 'attach' }, headers, method, path);
      expect(refused.status).toBe(403);
      expect(refused.body.error.data.reason).toBe(reason);
    }
  }
  const lease = async (id: string, action: string) => {
    const response = await client.raw({ client_id: id, action }, {}, 'POST', '/mcp/client-lease');
    expect(response.status).toBe(200);
    return response.body.active_client_count;
  };
  expect(await lease('first-client', 'attach')).toBe(1);
  expect(await lease('second-client', 'attach')).toBe(2);
  expect(await lease('first-client', 'heartbeat')).toBe(2);
  expect(await lease('first-client', 'detach')).toBe(1);
  expect(await lease('second-client', 'detach')).toBe(0);
  expect((await client.raw(null, {}, 'GET', '/mcp/readiness')).body.status).toBe('ok');
  // A bridge names its Herdr terminal; this factory's core cannot see that terminal,
  // so a clean detach ends its ownership while a lapsed heartbeat never would.
  const owner = await factory.client();
  const request = await owner.request('Detached owner');
  const terminal = { core_id: 'acceptance-core', terminal_id: owner.terminal };
  const leaseFor = async (action: string) => (await client.raw({ client_id: 'owner-bridge', action, terminal }, {}, 'POST', '/mcp/client-lease')).status;
  expect(await leaseFor('attach')).toBe(200);
  expect(await leaseFor('heartbeat')).toBe(200);
  const successor = await factory.client();
  await successor.reject('set_report', { work_request_id: request, brief: 'Too early' }, 'owned_by_other_terminal');
  expect(await leaseFor('detach')).toBe(200);
  await successor.call('set_report', { work_request_id: request, brief: 'Taken after a clean detach' });
  await owner.reject('set_report', { work_request_id: request, brief: 'Gone' }, 'owned_by_other_terminal');
});

