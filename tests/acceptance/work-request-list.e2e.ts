import { expect } from 'e2e';
import { DatabaseSync } from 'node:sqlite';
import { test } from '../support/authority.js';
import { contract } from '../support/factory.js';

test('lists compact WorkRequests newest first and resumes through tied timestamps', async ({ processes }) => {
  const factory = processes.factory();
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const scopes = [
    ['example/runtime', 'Rehearse backup recovery'],
    ['example/data', 'Validate migration snapshots'],
    ['example/review', 'Verify delivery handoff'],
  ];
  const rows = [];
  for (let index = 0; index < 24; index++) {
    const author = await factory.client();
    const [repo, task] = scopes[index % scopes.length];
    const title = `${task} ${index + 1}`;
    const { work_request: { id } } = await author.call('create_work_request', {
      title, repo, base_branch: 'main', work_type: 'feature',
      description: 'Synthetic request with delivery and recovery evidence.',
    });
    if (index === 0) {
      const [packageId] = await author.addPackages([contract('Retired delivery path')], { work_request_id: id });
      await author.call('close_work_package', { work_package_id: packageId, outcome: 'skipped' });
      await chief.call('ask', { work_request_id: id, question: 'Can this rollout be archived?' });
      rows.push({ id, title, repo, phase: 'unresolved', next_action: 'complete_or_archive', open_asks: 1 });
    } else {
      rows.push({ id, title, repo, phase: 'intake' });
    }
  }

  // Two rows at this timestamp belong on each side of the default page boundary.
  const tieStart = 2;
  const tieEnd = 6;
  await factory.stop();
  const db = new DatabaseSync(factory.database);
  try {
    const update = db.prepare('UPDATE sympp_work_requests SET inserted_at = ? WHERE id = ?');
    for (const [index, { id }] of rows.entries()) {
      const second = index >= tieStart && index < tieEnd ? tieStart : index;
      const insertedAt = `2026-01-01T00:00:${String(second).padStart(2, '0')}.000000Z`;
      expect(update.run(insertedAt, id).changes).toBe(1);
    }
  } finally {
    db.close();
  }
  const tiedRows = rows.slice(tieStart, tieEnd).sort((left, right) => left.id < right.id ? 1 : -1);
  const newestFirst = [...rows.slice(tieEnd).reverse(), ...tiedRows, ...rows.slice(0, tieStart).reverse()];
  const reader = await processes.factory('reader', { database: factory.database }).client(null);
  const first = (await reader.tool('list_work_requests')).result;
  const payload = first.structuredContent;
  const toon = first.content[0].text;
  const firstRows = newestFirst.slice(0, 20);
  expect(payload).toEqual({
    work_requests: firstRows, total_count: 20, limit: 20, filters: {}, next_cursor: expect.any(String),
  });
  expect(toon).toContain(`next_cursor: ${payload.next_cursor}`);
  expect(toon.split('\n').slice(-21)).toEqual([
    'work_requests[20]{id,phase,repo,title}:',
    ...firstRows.map(({ id, phase, repo, title }) => `  ${id},${phase},${repo},${title}`),
  ]);
  // The 20-row baseline at 7b2ed0b3 used 7,332 JSON chars and 7,739 full TOON chars.
  expect(JSON.stringify(payload).length).toBeLessThan(3_000);
  expect(toon.length).toBeLessThan(2_000);

  const next = (await reader.tool('list_work_requests', { cursor: payload.next_cursor })).result;
  expect(next.structuredContent.work_requests).toEqual(newestFirst.slice(20));
  expect(next.structuredContent.next_cursor).toBeUndefined();
  const { id, repo, title } = rows[0];
  expect(next.content[0].text).toContain([
    `  - id: ${id}`, '    next_action: complete_or_archive', '    open_asks: 1',
    '    phase: unresolved', `    repo: ${repo}`, `    title: ${title}`,
  ].join('\n'));

  const filtered = await reader.call('list_work_requests', { repo: `https://github.com/${repo}.git`, phase: 'intake' });
  expect(filtered.work_requests).toEqual(newestFirst.filter((row) => row.repo === repo && row.phase === 'intake'));
});
