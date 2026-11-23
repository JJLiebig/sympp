import { writeFile } from 'node:fs/promises';
import { expect } from 'e2e';
import { contract, type Client } from '../support/factory.js';
import { head, pr, prUrl, sync, test } from '../support/delivery.js';

const pageLimit = 17_500;

async function read(client: Client, work_request_id: string, view: string, args: object = {}) {
  const response = await client.tool('read_work_request', { work_request_id, view, ...args });
  expect(response.error).toBeUndefined();
  const { structuredContent: payload, content } = response.result;
  expect(content).toHaveLength(1);
  const text: string = content[0].text;
  const json = JSON.stringify(payload);
  // Direct callers and cells printing structuredContent see compact JSON.
  // A cell selecting the text sees TOON. The MCP envelope isn't printed.
  const sizes = { json: json.length, toon: text.length };
  expect(Buffer.byteLength(json)).toBeLessThanOrEqual(pageLimit);
  expect(Buffer.byteLength(text)).toBeLessThanOrEqual(pageLimit);
  return { payload, sizes, text };
}

test('Kraken-sized status reads fit their model budgets and expose actionable evidence', async ({ delivery: { factory, provider } }) => {
  const architect = await factory.client();
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const created = await architect.call('create_work_request', {
    repo: 'example/service', base_branch: 'beta', work_type: 'feature', title: 'Import services in dependency order',
    description: 'Bring the existing services into the monorepo with a reversible move and verify the rollout. '.repeat(36),
    constraints: { regions: ['west', 'east'], commitMarkerBytes: [65, 66] },
  });
  const request = created.work_request.id;
  architect.workRequest = request;
  const goal = 'Preserve service behavior and verify the deployment handoff before switching traffic. '.repeat(9).trim();
  const ids = await architect.addPackages(Array.from({ length: 68 }, (_, i) => contract(`Move service slice ${i + 1}`, {
    key: `slice-${i}`,
    group: `Rollout / ${['Data', 'Operator', 'API', 'Release'][i % 4]}`,
    goal,
    ...(i >= 48 && i < 56 ? { depends_on: [`slice-${i - 47}`, `slice-${i - 1}`] } : {}),
  })));

  for (const work_package_id of ids.slice(0, 48)) {
    await architect.call('close_work_package', { work_package_id, outcome: 'skipped' });
  }
  for (const [index, id] of ids.slice(56).entries()) {
    const number = 760 + index;
    const sha = head(index.toString(16));
    await architect.call('dispatch_work_package', { work_package_id: id });
    provider.set(number, pr(number, sha, index < 6 ? {
      statusCheckRollup: [{ name: 'required', status: 'IN_PROGRESS', conclusion: null }],
    } : {}));
    await sync(architect, id, number, sha);
  }

  for (const question of ['Can we keep the previous release online during the move?', 'Which services should switch together?']) {
    await chief.call('ask', { work_request_id: request, question });
  }
  await architect.call('set_report', { brief: 'The remaining services are in review. The first group can switch after their required checks pass.', eta: 'After the trial rollout' });
  const flagged = [];
  for (let i = 0; i < 31; i++) {
    const receipt = await architect.call('record_decision', {
      work_request_id: request, source_type: 'architect', flag: i < 15,
      decision: `Use the verified source for rollout group ${i + 1}.`,
      rationale: 'It keeps the transition reversible without dropping current service state.',
      scope_impact: 'Delivery', created_by: architect.address,
    });
    if (i < 15) flagged.push(receipt.decision_log_entry.id);
  }
  const acknowledged = flagged[0];
  expect((await architect.operator(`/api/v1/sympp/operator/decisions/${acknowledged}/ack`, {})).status).toBe(200);

  const overview = await read(architect, request, 'overview');
  const plan = await read(architect, request, 'plan');
  const board = await read(architect, request, 'board');
  const pkg = await read(architect, request, 'package', { work_package_id: ids[48] });
  const measurements = { overview: overview.sizes, plan: plan.sizes, board: board.sizes, package: pkg.sizes };
  await writeFile('.e2e/work-request-read-sizes.json', JSON.stringify(measurements, null, 2));
  for (const [result, limit] of [[overview, 5_250], [plan, 14_000], [board, 14_000], [pkg, 7_000]] as const) {
    expect(result.sizes.json).toBeLessThanOrEqual(limit);
    expect(result.sizes.toon).toBeLessThanOrEqual(limit);
    expect(result.payload.next_cursor).toBeUndefined();
  }
  const repeat = await read(architect, request, 'overview', { detail: 'full' });
  expect(repeat.payload).toEqual(overview.payload);
  expect(repeat.text).toBe(overview.text);
  expect(overview.payload.work_request).toMatchObject({
    id: request, title: 'Import services in dependency order', repo: 'example/service',
    phase: 'active', next_actor: 'operator', next_action: 'answer_ask',
  });
  expect(overview.payload.work_request.operator_report.eta.text).toBe('After the trial rollout');
  expect(overview.payload.work_request.human_description).toBeUndefined();
  expect(overview.payload.work_packages.map((row: any) => row.id)).toEqual(ids.slice(48));
  expect(overview.payload.ended).toEqual({ skipped: 48 });
  expect(overview.payload.asks).toHaveLength(2);
  expect(overview.payload.older_decision_count).toBe(28);
  expect(overview.payload.decisions.map((item: any) => item.id)).toEqual(flagged.slice(-3).reverse());

  expect(plan.payload.plan.work_packages).toHaveLength(20);
  expect(plan.payload.plan.work_packages[0]).toMatchObject({ id: ids[48], group: 'Rollout / Data', revision: 1 });
  expect(plan.payload.plan.dependencies).toEqual(expect.arrayContaining([
    expect.objectContaining({ from: ids[48], to: ids[1], outcome: 'skipped', delivered: false }),
  ]));
  expect(plan.payload.plan.work_packages[0].goal).toBeUndefined();
  const rows = board.payload.delivery_board.work_packages;
  expect(rows).toHaveLength(20);
  expect(rows.find((row: any) => row.id === ids[48])).toMatchObject({
    next_actor: 'architect', next_action: 'deliver_prerequisites', merge_eligibility: { eligible: false },
  });
  expect(rows.find((row: any) => row.id === ids[56])).toMatchObject({
    pr_url: prUrl(760), head_sha: head('0'), ci: { status: 'pending' }, merge_eligibility: { eligible: false },
  });
  expect(rows.find((row: any) => row.id === ids[62])).toMatchObject({
    pr_url: prUrl(766), head_sha: head('6'), ci: { status: 'passing' }, merge_eligibility: { eligible: true },
  });
  expect(pkg.payload.work_package).toMatchObject({ id: ids[48], goal, revision: 1, depends_on: expect.arrayContaining([ids[1], ids[47]]) });
  const brief = await read(architect, request, 'request');
  expect(brief.payload.work_request.constraints).toEqual({ regions: ['west', 'east'], commitMarkerBytes: [65, 66] });
  expect(brief.text).toContain('commitMarkerBytes[2]: 65,66');

  const page = await read(chief, request, 'flagged_decisions');
  const next = await read(chief, request, 'flagged_decisions', { cursor: page.payload.next_cursor });
  expect([...page.payload.decisions, ...next.payload.decisions].map((item: any) => item.id)).toEqual([...flagged].reverse());
  expect(next.payload.decisions.find((item: any) => item.id === acknowledged).review_state).toBe('acknowledged');
  expect(next.payload.next_cursor).toBeUndefined();
  expect((await chief.readDecision(request, acknowledged)).review_state).toBe('acknowledged');
});

test('oversize package contracts and live lists continue within the budget', async ({ delivery: { factory } }) => {
  const architect = await factory.client();
  const request = await architect.request('Bounded continuations');
  const goal = 'Ship the scoped change. Trace \u00e9vidence, verify inputs, and keep the worker’s handoff intact.\n'.repeat(350).trim();
  const ids = await architect.addPackages(Array.from({ length: 115 }, (_, i) => contract(`Verify service ${i + 1}`, {
    key: `service-${i}`, ...(i === 0 ? { goal } : { depends_on: [`service-${i - 1}`] }),
  })));
  const args = { work_package_id: ids[0] };
  let page = await read(architect, request, 'package', args);
  expect(page.payload.next_cursor).toBeTruthy();
  const chunks = [page.payload.chunk];
  await architect.reject('read_work_request', { work_request_id: request, view: 'package', work_package_id: ids[1], cursor: page.payload.next_cursor }, 'invalid_cursor');
  for (let i = 0; i < 5 && page.payload.next_cursor; i++) {
    page = await read(architect, request, 'package', { ...args, cursor: page.payload.next_cursor });
    chunks.push(page.payload.chunk);
  }
  expect(page.payload.next_cursor).toBeUndefined();
  expect(JSON.parse(chunks.join('')).work_package).toMatchObject({ id: ids[0], goal, revision: 1 });

  for (const view of ['overview', 'plan', 'board']) {
    const all = [];
    const links = [];
    let cursor: string | undefined;
    for (let i = 0; i < 10; i++) {
      const { payload } = await read(architect, request, view, { cursor });
      const rows = (payload.plan ?? payload.delivery_board ?? payload).work_packages;
      all.push(...rows.map((row: any) => row.id));
      links.push(...(payload.plan?.dependencies ?? []));
      cursor = payload.next_cursor;
      if (i === 0) expect(cursor).toBeTruthy();
      if (!cursor) break;
    }
    expect(cursor).toBeUndefined();
    expect(all).toEqual(ids);
    if (view === 'plan') expect(links.map((edge: any) => [edge.from, edge.to]).sort())
      .toEqual(ids.slice(1).map((id, index) => [id, ids[index]]).sort());
  }
});
