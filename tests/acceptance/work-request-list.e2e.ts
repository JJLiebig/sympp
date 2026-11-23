import { expect } from 'e2e';
import { contract, test } from '../support/factory.js';

test('lists a compact page of WorkRequests and resumes from its cursor', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const reader = await factory.client(null);
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
    if (index === 23) {
      const [packageId] = await author.addPackages([contract('Retired delivery path')], { work_request_id: id });
      await author.call('close_work_package', { work_package_id: packageId, outcome: 'skipped' });
      await chief.call('ask', { work_request_id: id, question: 'Can this rollout be archived?' });
      rows.push({ id, title, repo, phase: 'unresolved', next_action: 'complete_or_archive', open_asks: 1 });
    } else {
      rows.push({ id, title, repo, phase: 'intake' });
    }
  }

  const first = (await reader.tool('list_work_requests')).result;
  const payload = first.structuredContent;
  const toon = first.content[0].text;
  const firstRows = rows.slice(0, 20);
  expect(payload).toEqual({
    work_requests: firstRows, total_count: 20, limit: 20, filters: {}, next_cursor: expect.any(String),
  });
  expect(toon).toContain(`next_cursor: ${payload.next_cursor}`);
  expect(toon.split('\n').slice(-21)).toEqual([
    'work_requests[20]{id,phase,repo,title}:',
    ...firstRows.map(({ id, phase, repo, title }) => `  ${id},${phase},${repo},${title}`),
  ]);
  // The same 20 rows at 7b2ed0b3 used 7,332 JSON chars and 7,739 full TOON chars.
  expect(JSON.stringify(payload).length).toBeLessThan(3_000);
  expect(toon.length).toBeLessThan(2_000);

  const next = (await reader.tool('list_work_requests', { cursor: payload.next_cursor })).result;
  expect(next.structuredContent.work_requests).toEqual(rows.slice(20));
  expect(next.structuredContent.next_cursor).toBeUndefined();
  const { id, repo, title } = rows.at(-1)!;
  expect(next.content[0].text).toContain([
    `  - id: ${id}`, '    next_action: complete_or_archive', '    open_asks: 1',
    '    phase: unresolved', `    repo: ${repo}`, `    title: ${title}`,
  ].join('\n'));

  const filtered = await reader.call('list_work_requests', { repo: `https://github.com/${repo}.git`, phase: 'intake' });
  expect(filtered.work_requests).toEqual(rows.filter((row) => row.repo === repo && row.phase === 'intake'));
});
