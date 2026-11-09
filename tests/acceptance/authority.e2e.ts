import { expect } from 'e2e';
import { parseBoard } from '../../integrations/herdr-next/mods/sympp/model.js';
import { Client, contract, nextTerminal } from '../support/factory.js';
import { initialize, packages, test, tool } from '../support/authority.js';
import { close, head, pr, prUrl, row, test as deliveryTest } from '../support/delivery.js';

test('HTTP initialization and local origin checks prevent ambient requests from writing', async ({ processes }) => {
  const factory = processes.factory();
  const endpoint = await factory.endpoint;
  const fresh = new Client(endpoint, factory.receipt, nextTerminal());
  const uninitialized = await fresh.raw(tool('create_work_request', {}));
  expect(uninitialized.status).toBe(400);
  expect(uninitialized.body.error.data.reason).toBe('missing_session_id');
  expect((await fresh.raw(tool('record_work_request_operator_decision', {}))).body.error.data.reason).toBe('missing_session_id');
  const init = { jsonrpc: '2.0', id: 1, method: 'initialize', params: initialize };
  const list = { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} };
  const concurrent = Array.from({ length: 20 }, () => new Client(endpoint, factory.receipt));
  const initialized = await Promise.all(concurrent.map((client) => client.raw(init)));
  expect(initialized.every((response) => response.status === 200 && response.sessionId)).toBe(true);
  expect(new Set(initialized.map((response) => response.sessionId)).size).toBe(20);
  for (const client of concurrent) expect((await client.rpc('tools/list')).result.tools.length).toBeGreaterThan(0);
  for (const batch of [[init], [init, list]]) {
    expect((await fresh.raw(batch)).body.error.data.reason).toBe('batch_not_supported');
  }
  expect((await fresh.raw({ ...init, params: { protocolVersion: '2025-03-26' } })).body.error.data.reason).toBe('invalid_initialize_params');
  for (const headers of [
    { origin: 'https://example.invalid' }, { origin: 'null' },
    { origin: 'http://127.0.0.1:1' }, { origin: new URL(endpoint).origin.replace('127.0.0.1', 'localhost') },
  ]) {
    const refused = await fresh.raw(init, headers);
    expect(refused.status).toBe(403);
    expect(refused.body.error.data.reason).toBe('origin_not_allowed');
  }
  for (const headers of [
    { host: 'example.invalid' }, { forwarded: 'for=127.0.0.1' },
    { 'x-forwarded-for': '127.0.0.1' }, { 'x-forwarded-host': 'localhost' },
    { 'x-forwarded-proto': 'http' }, { 'x-real-ip': '127.0.0.1' },
  ]) {
    const refused = await fresh.raw(init, headers);
    expect(refused.status).toBe(403);
    expect(refused.body.error.data.reason).toBe('local_only');
  }
  expect((await fresh.raw(init, { origin: new URL(endpoint).origin })).status).toBe(200);
  expect((await fresh.rpc('initialize', initialize)).error.data.reason).toBe('already_initialized');
  expect((await fresh.call('sympp.health')).caller.owns).toEqual([]);
  const unboundResources = await fresh.rpc('resources/list');
  expect(unboundResources.result.resources.every((entry: any) => entry.uri.startsWith('sympp://health/'))).toBe(true);
  for (const uri of ['sympp://work-packages/', 'sympp://work-packages//task_plan.md', 'sympp://work-packages/missing/', 'sympp://work-packages/missing//task_plan.md', 'sympp://work-packages/missing/path/to/file.md']) {
    const invalid = await fresh.rpc('resources/read', { uri });
    expect(invalid.error.data.reason).toBe('invalid_work_package_resource_uri');
    expect(invalid.error.code).toBe(-32602);
  }
  const id = await fresh.request('Trusted initialization');
  const [nativePackage] = await packages(fresh, ['Native board findings']);
  const nativePath = '/api/v1/sympp/herdr/dashboard';
  const native = new Client(endpoint, factory.receipt);
  const browserBoard = await fresh.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  const nativeBoard = await native.raw(null, {}, 'GET', nativePath);
  expect(nativeBoard.status).toBe(200);
  // The native board adds the person's asks to the browser board's canonical content.
  const shared = nativeBoard.body.work_request_details.map(({ asks: _asks, ...detail }: any) => detail);
  expect(parseBoard({ ...nativeBoard.body, generated_at: browserBoard.generated_at, work_request_details: shared }))
    .toEqual(parseBoard(browserBoard));
  const detail = nativeBoard.body.work_request_details.find((entry: any) => entry.work_request.id === id);
  expect(detail.asks).toEqual([]);
  expect(browserBoard.work_request_details.find((entry: any) => entry.work_request.id === id).work_packages.find((entry: any) => entry.id === nativePackage).group).toBeNull();
  expect(detail.work_packages.find((entry: any) => entry.id === nativePackage).board_state.stage).toBe('build');
  for (const headers of [
    { host: 'example.invalid' }, { forwarded: 'for=127.0.0.1' },
    { 'x-forwarded-for': '127.0.0.1' }, { 'x-forwarded-host': 'localhost' },
    { 'x-forwarded-proto': 'http' }, { 'x-real-ip': '127.0.0.1' },
  ]) {
    const denied = await native.raw(null, headers, 'GET', nativePath);
    expect(denied.status).toBe(401);
    expect(denied.body.error.code).toBe('unauthorized');
  }
  expect((await native.raw({}, {}, 'POST', nativePath)).status).toBe(405);
  expect((await native.raw(null, {}, 'GET', '/api/v1/sympp/operator/dashboard/hydrated')).status).toBe(401);
  expect((await native.raw({ title: 'Denied native intake' }, {}, 'POST', '/api/v1/sympp/operator/work-requests')).status).toBe(401);
  const intake = {
    title: 'Native human intake', repo: 'example/native', base_branch: 'beta',
    human_description: 'A human request created without browser metadata.', future_field: true,
  };
  const nativeActions = [
    '/api/v1/sympp/herdr/work-requests',
    `/api/v1/sympp/herdr/work-requests/${id}/questions/missing/answer`,
  ];
  for (const action of nativeActions) {
    for (const headers of [
      { origin: new URL(endpoint).origin }, { origin: 'https://example.invalid' }, { origin: 'null' },
      { 'sec-fetch-site': 'same-origin' }, { 'sec-fetch-mode': 'cors' }, { 'sec-fetch-dest': 'empty' },
      { 'sec-fetch-user': '?1' }, { 'sec-fetch-future': '1' }, { host: 'example.invalid' },
      { forwarded: 'for=127.0.0.1' }, { 'x-real-ip': '127.0.0.1' },
      { 'x-forwarded-for': '127.0.0.1' }, { 'x-forwarded-host': 'localhost' },
      { 'x-forwarded-proto': 'http' }, { 'x-forwarded-port': '4000' }, { 'x-forwarded-future': '1' },
      { 'content-type': 'text/plain' }, { 'content-type': 'application/x-www-form-urlencoded' }, { 'content-type': '' },
    ]) expect((await native.raw(intake, headers, 'POST', action)).status).toBe(401);
    for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS']) {
      expect((await native.raw(null, { origin: new URL(endpoint).origin }, method, action)).status).toBe(405);
    }
  }
  const unchangedBoard = await native.raw(null, {}, 'GET', nativePath);
  expect(parseBoard({ ...unchangedBoard.body, generated_at: nativeBoard.body.generated_at }))
    .toEqual(parseBoard(nativeBoard.body));
  expect((await native.raw({}, {}, 'POST', nativeActions[0])).status).toBe(422);
  const createdNative = await native.raw(intake, { 'content-type': 'application/json; charset=utf-8' }, 'POST', nativeActions[0]);
  expect(createdNative.status).toBe(201);
  const nativeId = createdNative.body.work_request.work_request.id;
  expect(createdNative.body.refresh).toEqual({ dashboard: true, work_request_id: nativeId });
  const nativeDetail = await native.raw(null, {}, 'GET', `/api/v1/sympp/herdr/work-requests/${nativeId}`);
  expect(nativeDetail.body.work_request.title).toBe(intake.title);
  expect(nativeDetail.body.work_request.phase).toBe('intake');
  expect(nativeDetail.body.work_packages).toEqual([]);
  expect((await native.raw({}, {}, 'POST', `/api/v1/sympp/operator/work-requests/${nativeId}/delete`)).status).toBe(401);
  expect((await fresh.call('read_work_request', { detail: 'full', work_request_id: id })).work_packages.map((entry: any) => entry.id)).toEqual([nativePackage]);
  const owned = (await fresh.call('sympp.health')).caller.owns.map((entry: any) => entry.work_request_id);
  expect(owned).toEqual([id]);
  expect((await fresh.rpc('initialize', initialize)).error.data.reason).toBe('already_initialized');
  expect((await fresh.call('sympp.health')).caller.owns.map((entry: any) => entry.work_request_id)).toEqual(owned);
  const omittedHealthArgs = await fresh.rpc('tools/call', { name: 'sympp.health' });
  expect(omittedHealthArgs.result.structuredContent.status).toBe('ok');
  expect(omittedHealthArgs.result.structuredContent.caller.access).toBe('write');
  expect((await fresh.rpc('tools/call', { name: 'sympp.health', arguments: { unexpected: true } })).error.data.reason).toBe('invalid_tool_arguments');
  for (const headers of [{ origin: 'https://example.invalid' }, { 'x-forwarded-for': '127.0.0.1' }]) {
    const ambient = { work_request_id: id, decision: 'Denied ambient decision', rationale: 'Ambient', scope_impact: 'None', created_by: 'attacker' };
    expect((await fresh.raw(tool('record_work_request_operator_decision', ambient), headers)).status).toBe(403);
  }
  expect((await fresh.call('read_work_request', { detail: 'full', work_request_id: id })).decision_log_entries).toEqual([]);
  for (const batch of [[], [list], [init, list]]) {
    expect((await fresh.raw(batch)).body.error.data.reason).toBe('batch_not_supported');
  }
  expect((await fresh.raw('not json', {})).body.error.data.reason).toBe('invalid_json');
  expect((await fresh.raw(null, {}, 'GET')).status).toBe(405);
  for (const value of ['missing-session', '__sympp_mcp_current_state__', '\u00ff']) {
    const refused = await fresh.raw(tool('sympp.health'), { 'mcp-session-id': value });
    expect(refused.status).toBe(value === 'missing-session' ? 404 : 400);
    expect(refused.body.error.data.reason).toBe(value === 'missing-session' ? 'unknown_state_key' : 'invalid_session_id');
  }
  for (const payload of [init, list, { jsonrpc: '2.0', method: 'notifications/initialized' }]) {
    const unknown = await fresh.raw(payload, { 'mcp-session-id': 'missing-session' });
    expect(unknown.status).toBe(404);
    expect(unknown.body.error.data.reason).toBe('unknown_state_key');
  }
  const notification = await fresh.raw({ jsonrpc: '2.0', method: 'notifications/initialized' });
  expect(notification.status).toBe(202);
  expect(notification.body).toBeNull();
  expect((await fresh.call('read_work_request', { detail: 'full', work_request_id: id })).work_request.id).toBe(id);
});

test('ownership lets every terminal read any request but refuses writes to another owner and its endpoints', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const own = await architect.request('Owned request', 'beta', 'example/service', [
    { repo: 'example/service', base_branch: 'integration' },
  ]);
  const [ownWp] = await packages(architect, ['Owned package']);
  const malformedQuestion = await architect.reject('ask_question', { work_request_id: own, category: 'scope',
    question: 'Continue implementation?', why_needed: 'A choice is required.',
    decision_prompt: { tl_dr: 'Private malformed prompt sentinel', details: 'Missing options' },
  }, 'decision_prompt must contain 1 to 4 options');
  expect(JSON.stringify(malformedQuestion)).not.toContain('Private malformed prompt sentinel');
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: own })).clarification_questions).toEqual([]);
  const peer = await factory.client();
  const other = await peer.request('Other request');
  const [otherWp] = await peer.addPackages([contract('Hidden sibling')]);
  const question = (await peer.call('ask_question', {
    work_request_id: other, category: 'scope', question: 'Which behavior is required?', why_needed: 'A concrete choice is needed.',
  })).clarification_question;
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: other })).work_request.id).toBe(other);
  for (const [name, args] of [
    ['edit_plan', { work_request_id: other, ops: [{ op: 'add_package', ...contract('Stolen') }] }],
    ['dispatch_work_package', { work_request_id: other, work_package_id: otherWp }],
    ['dispatch_work_package', { work_package_id: otherWp }],
    ['reconcile_work_request', { work_request_id: other, apply: true }],
    ['record_work_package_delivery', { work_request_id: other, work_package_id: otherWp, outcome: 'completed_no_pr', idempotency_key: 'foreign-close', evidence: { completed_no_pr: { no_pr_evidence: 'Refuse foreign closeout' } } }],
  ] as const) {
    const refused = await architect.reject(name, args, 'owned_by_other_terminal');
    expect(refused.owner.address).toBe(peer.address);
    expect(refused.next_action).toBe(`ask ${peer.address}, or wait until it finishes`);
  }
  await architect.reject('sync_pr', { work_request_id: own, work_package_id: otherWp }, 'not_found');
  await architect.reject('dispatch_work_package', { work_request_id: own, work_package_id: 'missing-package' }, 'not_found');
  for (const [name, fields] of [
    ['answer_question', { answer: 'Stolen', answered_by: 'attacker' }],
    ['close_question', {}],
  ] as const) {
    const denied = await architect.reject(name, {
      work_request_id: own, question_id: question.id, expected_question_status: 'open', ...fields,
    }, 'not_found');
    expect(JSON.stringify(denied)).not.toContain(other);
  }
  await architect.reject('skip_work_package', { work_request_id: own, work_package_id: otherWp }, 'not_found');
  // A package of another WorkRequest is unknown to this plan, whichever op names it.
  for (const op of [
    { op: 'update_package', work_package_id: otherWp, expected_revision: 1, patch: { title: 'Stolen' } },
    { op: 'set_dependency', from: ownWp, to: otherWp, reason: 'Foreign endpoint' },
  ]) {
    const refused = await architect.reject('edit_plan', { work_request_id: own, ops: [op] }, 'unknown_work_package');
    expect(refused.work_package_ref).toBe(otherWp);
  }
  const tree = await architect.call('read_work_request', { detail: 'full', work_request_id: own, view: 'plan' });
  expect(JSON.stringify(tree)).not.toContain(otherWp);
  const unchanged = await peer.call('read_work_request', { detail: 'full', work_request_id: other });
  expect(unchanged.work_request.title).toBe('Other request');
  expect(unchanged.work_packages[0].status).toBe('planned');
  expect(unchanged.clarification_questions.find((entry: any) => entry.id === question.id).status).toBe('open');
  await peer.call('dispatch_work_package', { work_package_id: otherWp });

  const secondary = await factory.client();
  await secondary.request('Secondary repository reader', 'integration', 'example/client');
  expect((await secondary.call('read_work_request', { detail: 'full', work_request_id: own })).work_request.id).toBe(own);
  const [secondaryWp] = await architect.addPackages([contract('Secondary delivery', { repo: 'example/client', base_branch: 'integration' })]);
  await architect.call('dispatch_work_package', { work_package_id: secondaryWp });
  // Another terminal reads this WorkRequest in full; ownership gates writes only.
  const readerBoard = await secondary.board(own, 'full');
  expect(readerBoard.work_packages.find((entry: any) => entry.id === ownWp).work_package.id).toBe(ownWp);
  expect(readerBoard.work_packages.find((entry: any) => entry.id === secondaryWp).work_package.id).toBe(secondaryWp);
  await architect.call('edit_plan', { ops: [
    { op: 'update_package', work_package_id: ownWp, expected_revision: 1, patch: { group: 'Primary group' } },
    { op: 'update_package', work_package_id: secondaryWp, expected_revision: 1, patch: { group: 'Visible ancestor / Secondary group' } },
    { op: 'set_dependency', from: ownWp, to: secondaryWp, reason: 'Scoped dependency' },
  ] });
  const planArgs = { detail: 'full', work_request_id: own, view: 'plan' };
  const readerPlan = await secondary.call('read_work_request', planArgs);
  expect(readerPlan.plan.work_packages.map((entry: any) => entry.group).sort()).toEqual(['Primary group', 'Visible ancestor / Secondary group']);
  expect(readerPlan).toEqual(await architect.call('read_work_request', planArgs));
  const beforeEdges = readerPlan.plan.dependencies;
  await architect.reject('edit_plan', { ops: [{ op: 'set_dependency', from: ownWp, to: otherWp }] }, 'unknown_work_package');
  expect((await architect.call('read_work_request', planArgs)).plan.dependencies).toEqual(beforeEdges);
  await close(architect, ownWp);
  const closedRow = await row(secondary, own, ownWp);
  expect(closedRow.work_package.id).toBe(ownWp);
  expect(closedRow.operational_state.key).toBe('completed_no_pr');
  const sameRepoReader = await factory.client();
  await sameRepoReader.request('Same repository different delivery base', 'integration');
  const [alternateBase] = await architect.addPackages([contract('Alternate delivery base', { base_branch: 'integration' })]);
  await architect.call('dispatch_work_package', { work_package_id: alternateBase });
  const baseBoard = await sameRepoReader.board(own, 'full');
  expect(baseBoard.work_packages.find((entry: any) => entry.id === alternateBase).work_package.id).toBe(alternateBase);
  expect(baseBoard.work_packages.find((entry: any) => entry.id === ownWp).work_package.id).toBe(ownWp);
  await sameRepoReader.reject('record_work_package_delivery', { work_request_id: own, work_package_id: ownWp, outcome: 'completed_no_pr',
    idempotency_key: 'wrong-delivery-base', evidence: { completed_no_pr: { no_pr_evidence: 'Refuse hidden-base closeout' } },
  }, 'owned_by_other_terminal');

  for (const [repo, branch] of [['foreign/service', 'beta'], ['example/service', 'other-branch']]) {
    const outsider = await factory.client();
    const foreign = await outsider.request('Confidential outside scope', branch, repo);
    expect((await architect.call('read_work_request', { detail: 'full', work_request_id: foreign })).work_request.id).toBe(foreign);
    const listed = await architect.call('list_work_requests', {});
    expect(listed.work_requests.map((entry: any) => entry.id)).toContain(foreign);
  }
});

test('read views give a terminal that owns another request the same complete plan as the owner', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Plan projection authority');
  const reader = await factory.client();
  await reader.request('Secondary plan reader', 'integration', 'example/client');
  const views = ['overview', 'plan', 'board'];
  const read = async (client: Client, view: string) => client.call('read_work_request', { detail: 'full', work_request_id: request, view });
  for (const client of [architect, reader]) expect((await read(client, 'plan')).plan.work_packages).toEqual([]);
  const secondary = { repo: 'example/client', base_branch: 'integration' };
  const add = (title: string, key: string, patch: object = {}) => ({ op: 'add_package', key, ...contract(title, patch) });
  const edited = await architect.call('edit_plan', { ops: [
    add('Primary contract', 'primary', { group: 'Primary root / Primary package group' }),
    add('Primary ancestor membership', 'ancestor', { group: 'Secondary ancestor' }),
    add('Primary mixed membership', 'mixed', { group: 'Mixed membership', depends_on: ['primary'] }),
    add('Primary terminal contract', 'primaryTerminal', { group: 'Primary root / Primary package group', kind: 'docs' }),
    add('Secondary terminal contract', 'terminal', { ...secondary, group: 'Secondary ancestor / Secondary package group', kind: 'docs' }),
    add('Secondary planned contract', 'planned', { ...secondary, group: 'Secondary ancestor / Secondary package group', depends_on: ['terminal', 'primary'] }),
    add('Secondary mixed contract', 'mixedMember', { ...secondary, group: 'Mixed membership', depends_on: ['planned'] }),
    add('Secondary root contract', 'root', secondary),
  ] });
  const ids = Object.fromEntries(edited.applied.map((op: any) => [op.key, op.work_package_id]));
  const assertComplete = async (terminalStatus: string) => {
    for (const view of views) expect(await read(reader, view)).toEqual(await read(architect, view));
    const plan = (await read(reader, 'plan')).plan;
    expect(plan.work_packages.map((entry: any) => entry.id).sort()).toEqual(Object.values(ids).sort());
    expect(plan.summary.work_package_count).toBe(8);
    expect(plan.work_packages.find((entry: any) => entry.id === ids.terminal).status).toBe(terminalStatus);
    expect(plan.work_packages.find((entry: any) => entry.id === ids.primaryTerminal).status).toBe(terminalStatus);
    expect(plan.work_packages.find((entry: any) => entry.id === ids.root).group).toBeNull();
    expect(plan.dependencies).toHaveLength(4);
  };
  await assertComplete('planned');
  for (const wp of [ids.primaryTerminal, ids.terminal]) {
    await architect.call('dispatch_work_package', { work_package_id: wp });
    await close(architect, wp);
  }
  await assertComplete('ended');
});

test('package evidence tools keep plans atomic, findings idempotent and progress redacted for the owner', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Package planning and history');
  const reviewValues = ['synthetic-review-credential', 'synthetic-review-access', 'synthetic-review-verifier'];
  const [wp, sibling] = await architect.addPackages([
    contract('Plan owner', { review: { type: 'review-suite', args: {
      mode: 'fast', credential: reviewValues[0], access_key: reviewValues[1], grant_verifier: reviewValues[2],
    } } }), contract('Other plan'),
  ]);
  for (const work_package_id of [wp, sibling]) await architect.call('dispatch_work_package', { work_package_id });
  const own = (args: object) => ({ work_package_id: wp, ...args });
  const other = (args: object) => ({ work_package_id: sibling, ...args });
  const taskPlan = async (work_package_id: string) =>
    (await architect.call('read_work_request', { work_request_id: request, view: 'package', work_package_id, detail: 'full' })).task_plan;
  const initial = await taskPlan(wp);
  const progressBefore = (await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress;
  for (const [args, reason] of [
    [{ summary: 'Invalid key', idempotency_key: 123 }, 'invalid_idempotency_key'],
    [{ summary: 123, idempotency_key: 'invalid-summary' }, 'invalid_summary'],
    [{ summary: 'Invalid payload', idempotency_key: 'invalid-payload', payload: false }, 'invalid_payload'],
  ] as const) await architect.reject('append_progress', own(args), reason);
  expect((await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress).toEqual(progressBefore);
  const plan = await architect.call('update_task_plan', own({ expected_version: initial.version, nodes: [{ title: 'Own node' }] }));
  const ownNode = plan.plan_nodes[0].id;
  const siblingPlan = await taskPlan(sibling);
  const foreignNode = (await architect.call('update_task_plan', other({ expected_version: siblingPlan.version, nodes: [{ title: 'Sibling node' }] }))).plan_nodes[0].id;
  const before = await taskPlan(wp);
  for (const invalid of [foreignNode, 'plan_missing']) {
    await architect.reject('update_task_plan', own({ expected_version: before.version, nodes: [{ id: ownNode, status: 'done' }, { id: invalid, title: 'Do not insert' }] }), 'unknown_plan_node');
    expect(await taskPlan(wp)).toEqual(before);
  }
  await architect.reject('update_task_plan', own({ expected_version: before.version, nodes: [{ id: ownNode, status: 'invalid' }] }), 'invalid_status');
  expect(await taskPlan(wp)).toEqual(before);
  const changed = await architect.call('update_task_plan', own({ expected_version: before.version, nodes: [{ id: ownNode, body: 'Working', status: 'in_progress' }, { title: 'Additional task', status: 'done' }] }));
  expect(changed.plan_nodes.map((node: any) => node.status)).toEqual(['in_progress', 'done']);
  expect((await taskPlan(wp)).text).toContain('Working');
  await architect.reject('update_task_plan', own({ expected_version: before.version, nodes: [{ id: ownNode, status: 'done' }] }), 'stale_plan_version');
  expect((await taskPlan(sibling)).text).toContain('Sibling node');
  const siblingVersion = (await taskPlan(sibling)).version;
  await architect.call('update_task_plan', other({ expected_version: siblingVersion, nodes: Array.from({ length: 100 }, (_, index) => ({ title: `Bounded node ${index + 1}` })) }));
  const bounded = await taskPlan(sibling);
  expect(bounded.steps).toHaveLength(100);
  expect(bounded.omitted_steps).toBe(2);
  expect(bounded.steps.some((step: any) => step.title === 'Bounded node 100')).toBe(false);
  expect(bounded.text).toContain('2 later plan nodes omitted');
  await architect.call('update_task_plan', other({ expected_version: bounded.version, nodes: [{ id: foreignNode, status: 'done' }] }));
  expect((await taskPlan(sibling)).steps.find((node: any) => node.id === foreignNode).status).toBe('done');
  const first = await architect.call('append_finding', own({ id: 'synthetic-finding', title: 'Finding', body: 'Evidence', idempotency_key: ' finding-once ' }));
  expect((await architect.call('append_finding', own({ id: 'synthetic-finding', title: 'Finding', body: 'Evidence', idempotency_key: 'finding-once' }))).finding.id).toBe(first.finding.id);
  await architect.reject('append_finding', own({ id: 'different-finding', title: 'Finding', body: 'Evidence', idempotency_key: 'finding-once' }), 'idempotency_conflict');
  await architect.reject('append_finding', own({ id: 'synthetic-finding', title: 'Finding', body: 'Evidence', idempotency_key: 'other-key' }), 'idempotency_conflict');
  const safeIdentity = 'finding_embeddedSk-syntheticIdentifier';
  const sensitiveFinding = await architect.call('append_finding', own({
    id: safeIdentity, title: 'Identity survives document encoding',
    body: 'Keep identity while hiding sk-synthetic-document-secret', severity: 'sk-synthetic-severity-secret',
    idempotency_key: 'document-identity',
  }));
  expect(sensitiveFinding.finding.id).toBe(safeIdentity);
  // Package documents are readable by every trusted caller and stay redacted.
  const reader = await factory.client(null);
  for (const document of ['context.md', 'task_plan.md', 'findings.md', 'progress.md', 'review.md']) {
    const resource = await reader.rpc('resources/read', { uri: `sympp://work-packages/${wp}/${document}` });
    expect(resource.result.contents[0].mimeType).toBe('text/vnd.toon');
    const text = resource.result.contents[0].text;
    for (const secret of ['sk-synthetic-document-secret', 'sk-synthetic-severity-secret', ...reviewValues]) expect(text).not.toContain(secret);
  }
  await architect.reject('append_progress', own({
    summary: 'Cannot forge audit identity', idempotency_key: 'forged-audit',
    id: 'caller-progress-id', created_at: '2000-01-01T00:00:00Z', actor_id: 'forged-worker',
    actor_type: 'architect', agent_run_id: 'forged-run',
  }), 'unexpected_argument');
  const redacted = await architect.tool('append_progress', own({
    summary: 'Recorded progress sk-synthetic-progress-token', idempotency_key: 'redacted-progress',
    payload: { accessKey: 'synthetic-access-value', apiKey: 'synthetic-api-value', grant_verifier: 'synthetic-verifier-value', private_payload: { path: 'synthetic-private-path' }, safe: 'unprojected-safe-value' },
  }));
  expect(redacted.result.structuredContent.progress_event.summary).toContain('[REDACTED]');
  expect(redacted.result.structuredContent.progress_event.id).not.toBe('caller-progress-id');
  const history = (await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress;
  const audit = history.find((entry: any) => entry.id === redacted.result.structuredContent.progress_event.id);
  expect(Date.parse(audit.created_at)).toBeGreaterThan(Date.parse('2026-01-01T00:00:00Z'));
  // Progress is attributed to the terminal that wrote it, never to a caller-supplied author.
  expect(audit.actor.id).toBe(architect.address);
  for (const forged of ['forged-worker', 'forged-grant', 'forged-run']) expect(JSON.stringify(audit)).not.toContain(forged);
  expect(history.some((entry: any) => entry.summary === 'Cannot forge audit identity')).toBe(false);
  const projected = await reader.rpc('resources/read', { uri: `sympp://work-packages/${wp}/progress.md` });
  for (const value of ['sk-synthetic-progress-token', 'synthetic-access-value', 'synthetic-api-value', 'synthetic-verifier-value', 'synthetic-private-path', 'unprojected-safe-value']) {
    expect(redacted.result.content[0].text).not.toContain(value);
    expect(projected.result.contents[0].text).not.toContain(value);
  }
  // Another terminal cannot write this request's package evidence.
  const peer = await factory.client();
  await peer.reject('append_finding', own({ title: 'Foreign', body: 'Refused', idempotency_key: 'foreign-finding' }), 'owned_by_other_terminal');
});

deliveryTest('architect CI observations reach the native dashboard with stable per-head change times', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const request = await architect.request('CI reporting');
  const [wp] = await architect.addPackages([contract('CI reporting', { kind: 'mcp', branch_pattern: 'feature/authority' })]);
  await architect.call('dispatch_work_package', { work_package_id: wp });
  await architect.call('attach_branch', { work_package_id: wp, branch: 'feature/authority', head_sha: head('a') });
  const signal = async () => {
    const dashboard = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
    const detail = dashboard.work_request_details.find((item: any) => item.work_request.id === request);
    return detail.work_packages.find((item: any) => item.id === wp).pr_signal;
  };
  let previous: any;
  for (const [index, status] of ['pending', 'passing', 'pending', 'failing', 'pending', 'passing'].entries()) {
    const checks = status === 'pending'
      ? [{ status: 'IN_PROGRESS', conclusion: null }]
      : [{ status: 'COMPLETED', conclusion: status === 'passing' ? 'SUCCESS' : 'FAILURE' }];
    provider.set(303, pr(303, head('a'), { headRefName: 'feature/authority', statusCheckRollup: checks }));
    await architect.call('sync_pr', { work_package_id: wp, url: prUrl(303) });
    const current = await signal();
    expect(current.checks.status).toBe(status);
    expect(Number.isFinite(Date.parse(current.checks.changed_at))).toBe(true);
    if (previous) {
      expect(current.checks.changed_at).not.toBe(previous.checks.changed_at);
      expect(current.head_changed_at).toBe(previous.head_changed_at);
    }
    await architect.call('sync_pr', { work_package_id: wp, url: prUrl(303) });
    expect((await signal()).checks).toEqual(current.checks);
    previous = current;
  }
  // A review push starts a new CI run even when its status stays passing.
  await architect.call('attach_branch', { work_package_id: wp, branch: 'feature/authority', head_sha: head('b') });
  provider.set(303, pr(303, head('b'), { headRefName: 'feature/authority' }));
  await architect.call('sync_pr', { work_package_id: wp, url: prUrl(303) });
  const pushed = await signal();
  expect(pushed.head_sha).toBe(head('b'));
  expect(pushed.checks.status).toBe('passing');
  expect(pushed.checks.changed_at).not.toBe(previous.checks.changed_at);
  expect(pushed.head_changed_at).not.toBe(previous.head_changed_at);
});

test('operator reports keep server times and partial edits and only the owner writes them', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Truthful operator reports');
  const [wp] = await packages(architect, ['Report boundary']);
  const question = (await architect.call('ask_question', { work_request_id: request, category: 'scope',
    question: 'Which release should include this?', why_needed: 'Select the intended release.' })).clarification_question;
  const read = async () => (await architect.call('read_work_request', { detail: 'full', work_request_id: request })).work_request.operator_report;
  const peer = await factory.client();
  await peer.reject('set_report', { work_request_id: request, brief: 'Forged brief' }, 'owned_by_other_terminal');
  await (await factory.client(null)).reject('set_report', { work_request_id: request, brief: 'Forged brief' }, 'read_only_outside_herdr');
  await architect.reject('append_progress', { work_package_id: wp, summary: 'Old report path', idempotency_key: 'old-report',
    payload: { type: 'architect_operator_report', brief: 'Old path' } }, 'operator_report_moved');
  expect(await read()).toBeFalsy();
  await architect.call('set_report', { brief: 'x'.repeat(4000) });
  expect((await read()).brief.text).toHaveLength(4000);
  await architect.reject('set_report', { brief: 'x'.repeat(4001) }, 'invalid_operator_report_brief');
  await architect.reject('set_report', { brief: 'Forged time', written_at: '2000-01-01T00:00:00Z' }, 'unexpected_argument');
  expect((await read()).brief.text).toHaveLength(4000);
  const started = Date.now();
  await architect.call('set_report', { brief: 'Core work is ready.', eta: 'After review', parking: { reason: 'Awaiting a release window' } });
  const first = await read();
  expect(first.brief.text).toBe('Core work is ready.');
  expect(Date.parse(first.brief.written_at)).toBeGreaterThanOrEqual(started - 1000);
  expect(first.parking.parked_at).toBe(first.brief.written_at);
  expect(first.parking.resumed_at).toBeNull();
  await architect.call('set_report', { eta: 'Friday' });
  const edited = await read();
  expect(edited.brief).toEqual(first.brief);
  expect(edited.parking).toEqual(first.parking);
  expect(edited.eta.text).toBe('Friday');
  await architect.call('set_report', { eta: null, parking: null });
  const resumed = await read();
  expect(resumed.eta).toBeUndefined();
  expect(resumed.brief).toEqual(first.brief);
  expect(Date.parse(resumed.parking.resumed_at)).toBeGreaterThanOrEqual(Date.parse(first.parking.parked_at));
  await architect.call('set_report', { parking: { reason: 'Waiting on a follow-up' } });
  const reparked = await read();
  expect(reparked.parking.reason).toBe('Waiting on a follow-up');
  expect(reparked.parking.resumed_at).toBeNull();
  const dashboard = await architect.inspect('/api/v1/sympp/operator/dashboard/hydrated');
  const detail = dashboard.work_request_details.find((entry: any) => entry.work_request.id === request);
  expect(detail.work_request.operator_report).toEqual(reparked);
  expect(detail.work_request.worked_on.address).toBe(architect.address);
  const unchanged = await architect.call('read_work_request', { detail: 'full', work_request_id: request });
  expect(unchanged.work_request.phase).toBe('active');
  expect(unchanged.clarification_questions.find((entry: any) => entry.id === question.id).status).toBe('open');
  expect((await row(architect, request, wp)).attention_reason_codes).not.toContain('active_blocker');
});

test('architect question and decision mutations preserve provenance and redact compact responses', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Redacted clarification authority');
  const ask = await architect.call('ask_question', { work_request_id: request, category: 'scope',
    question: 'Avoid Bearer raw_secret_synthetic', why_needed: 'Keep raw_secret_synthetic out of responses.',
    asked_by_agent_run_id: 'raw_secret_synthetic', decision_prompt: { tl_dr: 'Choose scope', details: 'A bounded decision is required.',
      options: [{ id: 'continue', label: 'Continue', answer: 'Proceed without raw_secret_synthetic.' }],
    },
  });
  expect(ask.scope.repo).toBe('example/service');
  expect(ask.scope.base_branch).toBe('beta');
  const question = ask.clarification_question.id;
  for (const field of ['asked_by_agent_run_id', 'decision_prompt']) expect(ask.clarification_question[field]).toBeUndefined();
  expect(JSON.stringify(ask)).not.toContain('raw_secret_synthetic');
  for (const [value, got] of [['ready_for_slicing', 'ready_for_slicing'], [123, 'non_string']] as const) {
    const invalid = await architect.reject('answer_question', { work_request_id: request, question_id: question,
      expected_question_status: value, answer: 'Invalid status domain',
    }, 'invalid_question_status');
    expect(invalid.status_domain).toBe('clarification_question');
    expect(invalid.expected_statuses).toEqual(['open']);
    expect(invalid.got).toBe(got);
  }
  const answered = await architect.call('answer_question', { work_request_id: request, question_id: question,
    answer: 'Use https://example.invalid/evidence?sig=raw_secret_synthetic',
  });
  expect(answered.clarification_question.status).toBe('answered');
  expect(answered.clarification_question.answered_by).toBeUndefined();
  expect(JSON.stringify(answered)).not.toContain('raw_secret_synthetic');
  const closing = (await architect.call('ask_question', { work_request_id: request, category: 'acceptance',
    question: 'Can the obsolete alternative be closed?', why_needed: 'Retire an unused choice.',
  })).clarification_question.id;
  expect((await architect.call('close_question', { work_request_id: request, question_id: closing, expected_question_status: 'open' })).clarification_question.status).toBe('closed');
  const deciding = (await architect.call('ask_question', { work_request_id: request, category: 'product',
    question: 'Keep this scope bounded?', why_needed: 'The answer must become decision provenance.',
  })).clarification_question.id;
  const combined = await architect.call('answer_question_and_record_decision', { work_request_id: request, question_id: deciding,
    answer: 'Keep the bounded scope.', source_type: 'architect', decision: 'Keep the bounded scope.',
    rationale: 'Adjacent work has another owner.', scope_impact: 'No scope expansion.',
  });
  expect(combined.clarification_question.status).toBe('answered');
  expect(combined.decision_log_entry.source_id).toBe(deciding);
  const ids: string[] = [combined.decision_log_entry.id];
  for (const [source, by] of [['implicit', undefined], ['override', 'synthetic-architect-override']] as const) {
    const result = await architect.call('record_decision', { work_request_id: request, source_type: 'architect', source_id: source,
      decision: 'Exclude raw_secret_synthetic from the decision', rationale: 'Keep the scope bounded.', scope_impact: 'No scope expansion.',
      ...(by ? { created_by: by } : {}),
    });
    expect(result.decision_log_entry.created_by).toBe(by ?? architect.address);
    expect(JSON.stringify(result)).not.toContain('raw_secret_synthetic');
    ids.push(result.decision_log_entry.id);
  }
  const persisted = await architect.call('read_work_request', { detail: 'full', work_request_id: request });
  expect(persisted.work_request.phase).toBe('intake');
  expect(persisted.clarification_questions.map((entry: any) => entry.status)).toEqual(['answered', 'closed', 'answered']);
  expect(persisted.decision_log_entries.map((entry: any) => entry.id)).toEqual(ids);
  expect(JSON.stringify(persisted)).not.toContain('raw_secret_synthetic');
});

test('explicit trusted local decisions are open to any Herdr terminal and stay redacted', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Local operator notes');
  const decisionArgs = { work_request_id: request, decision: 'Use sk-synthetic-note-decision',
    rationale: 'Context sk-synthetic-note-rationale', scope_impact: 'Bounded sk-synthetic-note-scope' };
  // A terminal that does not own the WorkRequest may still record an operator decision.
  const other = await factory.client();
  const note = await other.call('record_work_request_operator_decision', decisionArgs);
  expect(note.decision_log_entry.source_type).toBe('operator');
  expect(note.decision_log_entry.created_by).toBe(other.address);
  expect(note.decision_log_entry.decision).toBe('Use [REDACTED]');
  expect(JSON.stringify(note)).not.toContain('sk-synthetic');
  const observer = await factory.client();
  const localDecision = await observer.call('record_work_request_operator_decision', {
    ...decisionArgs, source_id: 'ghp_syntheticdecision', created_by: 'operator sk-synthetic-decision-author',
  });
  expect(localDecision.decision_log_entry.source_id).toBe('[REDACTED]');
  expect(localDecision.decision_log_entry.created_by).toBe('operator [REDACTED]');
  await observer.reject('record_work_request_operator_decision', { ...decisionArgs, work_request_id: 'missing-request', created_by: 'operator' }, 'not_found');
  await (await factory.client(null)).reject('record_work_request_operator_decision', decisionArgs, 'read_only_outside_herdr');
  // Decisions never take ownership.
  expect((await observer.call('sympp.health')).caller.owns).toEqual([]);
  const persisted = await architect.call('read_work_request', { detail: 'full', work_request_id: request });
  const stored = persisted.decision_log_entries.find((entry: any) => entry.id === note.decision_log_entry.id);
  expect(stored.decision).toBe('Use [REDACTED]');
  expect(stored.rationale).toBe('Context [REDACTED]');
  expect(stored.scope_impact).toBe('Bounded [REDACTED]');
  expect(JSON.stringify(stored)).not.toContain('sk-synthetic');
  expect(persisted.decision_log_entries.map((entry: any) => entry.id)).toContain(localDecision.decision_log_entry.id);
});

test('architect descendant planning stays owned through terminal closeout and request archive', async ({ processes }) => {
  const factory = processes.factory();
  const architect = await factory.client();
  const request = await architect.request('Architect descendant evidence');
  const [wp] = await architect.addPackages([contract('Secondary planning', { repo: 'example/client', base_branch: 'integration' })]);
  const taskPlan = async (workRequest: string, work_package_id: string) =>
    (await architect.call('read_work_request', { work_request_id: workRequest, view: 'package', work_package_id, detail: 'full' })).task_plan;
  const initial = await taskPlan(request, wp);
  const updated = await architect.call('update_task_plan', { work_package_id: wp, expected_version: initial.version, nodes: [{ title: 'Inspect descendant', status: 'in_progress' }] });
  expect(updated.plan_nodes[0].title).toBe('Inspect descendant');
  const finding = (await architect.call('append_finding', { work_package_id: wp, title: 'Scoped evidence', body: 'Owned descendant', idempotency_key: 'architect-finding' })).finding;
  const progress = (await architect.call('append_progress', { work_package_id: wp, summary: 'Owned descendant progress', idempotency_key: 'architect-progress' })).progress_event;
  const detail = await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`);
  expect(detail.findings[0].id).toBe(finding.id);
  expect(detail.progress[0].id).toBe(progress.id);
  const uri = `sympp://work-packages/${wp}/task_plan.md`;
  expect((await architect.rpc('resources/read', { uri })).result.contents[0].text).toContain('Inspect descendant');
  const foreign = await factory.client();
  const foreignRequest = await foreign.request('Other planning owner');
  const [otherWp] = await packages(foreign, ['Private foreign plan']);
  // Reads by explicit id are free for trusted callers; writes need the owner.
  expect(typeof (await taskPlan(foreignRequest, otherWp)).version).toBe('number');
  await architect.reject('append_progress', { work_package_id: otherWp, summary: 'Foreign', idempotency_key: 'foreign' }, 'owned_by_other_terminal');
  await close(architect, wp);
  for (const [name, args] of [
    ['update_task_plan', { expected_version: updated.version, nodes: [{ id: updated.plan_nodes[0].id, status: 'done' }] }],
    ['append_finding', { title: 'Late finding', body: 'Must not persist', idempotency_key: 'late-architect-finding' }],
    ['append_progress', { summary: 'Late progress', idempotency_key: 'late-architect-progress' }],
  ] as const) await architect.reject(name, { work_package_id: wp, ...args }, 'work_package_terminal');
  expect((await architect.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).findings).toHaveLength(1);
  expect((await architect.operator(`/api/v1/sympp/operator/work-requests/${request}/archive`, {})).status).toBe(200);
  // Archiving ends ownership; the archived request's plan stays readable by id and refuses writes.
  expect((await architect.call('sympp.health')).caller.owns).toEqual([]);
  expect((await taskPlan(request, wp)).text).toContain('Inspect descendant');
  await architect.reject('edit_plan', { work_request_id: request, ops: [{ op: 'add_package', ...contract('Archived scope') }] }, 'work_request_archived');
});

