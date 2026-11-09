import { expect } from 'e2e';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import type { Client } from '../support/factory.js';
import { head, installReviewSuite, pr, test, type Provider, type Terminal } from '../support/delivery.js';
import { githubCheckout as checkout } from '../support/worktree-git.js';

// Both boards list cards: the operator's web board and Herdr's native board.
async function cards(client: Client) {
  const web = (await client.inspect('/api/v1/sympp/operator/dashboard/hydrated')).cards;
  const native = await client.raw(undefined, {}, 'GET', '/api/v1/sympp/herdr/dashboard');
  expect(native.status).toBe(200);
  expect(native.body.cards).toEqual(web);
  return Object.fromEntries(web.map((card: any) => [card.title, card]));
}

// The Observer's two ticks: herdr-core first, then GitHub, Review Suite and cards.
async function observe(factory: { tick: (name: 'sweep' | 'terminals') => Promise<void> }) {
  await factory.tick('terminals');
  await factory.tick('sweep');
}

const live = (provider: Provider, terminal: Terminal) => provider.terminal({ ...terminal, state: 'live' });
const branchPr = (number: number, sha: string, branch: string, patch: object = {}) =>
  pr(number, sha, { headRefName: branch, baseRefName: 'main', ...patch });

test('a terminal working for an architect or chief gets a card that follows its branch, PR, review and merge; workers never do', async ({ watched: { factory, provider, root } }) => {
  const architect = await factory.client();
  await architect.request('Card parent');
  await mkdir(join(root, 'checkouts'));
  const child = await checkout(root, 'child', 'feature/card-1');
  live(provider, { address: 'c1', cwd: child.dir, parent: architect.terminal!, title: 'Dark theme' });
  live(provider, { address: 'w1', cwd: (await checkout(root, 'worker', 'feature/worker')).dir, parent: architect.terminal!, title: 'Worker',
    labels: { 'sympp.role': 'worker', 'sympp.work_package_id': 'wp_elsewhere' } });
  live(provider, { address: 'b1', cwd: (await checkout(root, 'base', 'main')).dir, parent: architect.terminal!, title: 'On base' });
  live(provider, { address: 'k1', cwd: (await checkout(root, 'labelled', 'feature/labelled', false)).dir, title: 'Labelled', labels: { 'sympp.card': '1' } });
  live(provider, { address: 'ch', title: 'Chief', labels: { 'sympp.role': 'chief' } });
  live(provider, { address: 'c2', cwd: (await checkout(root, 'chief-child', 'feature/chief-child')).dir, parent: 'ch', title: 'Chief child' });
  live(provider, { address: 'x1', cwd: (await checkout(root, 'stranger', 'feature/stranger')).dir, title: 'Stranger' });
  await observe(factory);
  let board = await cards(architect);
  expect(Object.keys(board).sort()).toEqual(['Chief child', 'Dark theme', 'Labelled']);
  expect(board['Dark theme']).toMatchObject({ state: 'working', repository: 'example/service', base_branch: 'main', branch: 'feature/card-1' });
  expect(board['Dark theme'].worked_on).toMatchObject({ address: 'acceptance/c1', role: 'card' });
  // Without origin/HEAD the base is origin/main.
  expect(board['Labelled']).toMatchObject({ state: 'working', base_branch: 'main' });

  // The branch's PR opens: review and CI.
  provider.set(950, branchPr(950, head('a'), 'feature/card-1'));
  live(provider, { address: 'c1', labels: { 'sympp.review_id': 'rvw_card000000001' } });
  const review = await installReviewSuite(factory.home);
  await review.answer({ review: 'rvw_card000000001', done: true, status: 'done', reviewed_head: head('a'), accepted_head: head('a'), progress: '1/1' });
  await observe(factory);
  board = await cards(architect);
  expect(board['Dark theme']).toMatchObject({ state: 'review_ci', pr: { number: 950, state: 'open', head_sha: head('a') } });
  expect(board['Dark theme'].review).toMatchObject({ id: 'rvw_card000000001', state: 'done' });
  // A new review cycle never shows the previous cycle's result.
  live(provider, { address: 'c1', labels: { 'sympp.review_id': 'rvw_card000000002' } });
  await review.answer({ error: 'unknown review cycle id: rvw_card000000002', status: 'usage_error' }, 2);
  await observe(factory);
  expect((await cards(architect))['Dark theme'].review).toMatchObject({ id: 'rvw_card000000002', state: 'pending' });

  provider.set(950, branchPr(950, head('a'), 'feature/card-1', { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await observe(factory);
  board = await cards(architect);
  expect(board['Dark theme'].state).toBe('merged');
  expect(board['Dark theme'].ended_at).toBeTruthy();
  // An ended card's branch isn't taken for new work while its terminal stays on it.
  await observe(factory);
  expect((await cards(architect))['Dark theme'].state).toBe('merged');

  // The same terminal starts another branch: the card opens again.
  await child.switch('feature/card-2');
  await observe(factory);
  expect((await cards(architect))['Dark theme']).toMatchObject({ state: 'working', branch: 'feature/card-2' });
  provider.set(951, branchPr(951, head('b'), 'feature/card-2'));
  await observe(factory);
  expect((await cards(architect))['Dark theme'].state).toBe('review_ci');
  provider.set(951, branchPr(951, head('b'), 'feature/card-2', { state: 'CLOSED' }));
  await observe(factory);
  expect((await cards(architect))['Dark theme'].state).toBe('done');

  // A terminal on its base branch shows work once a PR from that branch opens.
  provider.set(952, branchPr(952, head('c'), 'main', { baseRefName: 'release' }));
  await observe(factory);
  expect((await cards(architect))['On base']).toMatchObject({ state: 'review_ci', repository: 'example/service', base_branch: 'main', branch: 'main' });
});

test('unknown inputs never end a card, a finished terminal without a PR does, and the operator answers and dismisses cards', async ({ watched: { factory, provider, root } }) => {
  const architect = await factory.client();
  await architect.request('Card parent');
  await mkdir(join(root, 'checkouts'));
  // Before it works on a branch, a terminal has no card to ask on.
  const early = await factory.client('a1');
  const noCard = await early.reject('ask', { question: 'Before any branch?' }, 'no_open_card');
  expect(noCard.next_action).toContain('work_request_id');
  await early.reject('ask', { work_package_id: 'wp_any', question: 'Which package?' }, 'missing_work_request_id');
  const asking = await checkout(root, 'asking', 'feature/asking');
  live(provider, { address: 'a1', cwd: asking.dir, parent: architect.terminal!, title: 'Asking' });
  live(provider, { address: 'f1', cwd: (await checkout(root, 'finishing', 'feature/finishing')).dir, parent: architect.terminal!, title: 'Finishing' });
  await observe(factory);
  expect((await cards(architect))['Asking'].state).toBe('working');

  // GitHub or herdr-core can't be read: cards only show it, even for a terminal that finished.
  provider.terminal({ address: 'f1', state: 'finished' });
  provider.github = 'down';
  await observe(factory);
  let board = await cards(architect);
  expect(board['Asking']).toMatchObject({ state: 'working', stale: ['github'] });
  expect(board['Finishing']).toMatchObject({ state: 'working', stale: ['github'] });
  provider.github = 'up';
  provider.core = null;
  await observe(factory);
  expect((await cards(architect))['Asking'].state).toBe('working');
  provider.core = { id: 'acceptance-core', name: 'acceptance' };

  // Once GitHub confirms the finished terminal's branch has no PR, its card is done.
  await observe(factory);
  board = await cards(architect);
  expect(board['Finishing'].state).toBe('done');
  expect(board['Asking'].state).toBe('working');

  // A card's ask is answered by the operator and typed into the asking terminal.
  const ask = (await early.call('ask', { question: 'Ship the dark theme?' })).ask;
  expect(ask.card_id).toBe(board['Asking'].id);
  expect((await cards(architect))['Asking'].asks.map((item: any) => item.id)).toEqual([ask.id]);
  await early.reject('resolve_ask', { ask_id: ask.id, to: 'answered', answer: 'Yes',
    decision: { source_type: 'human', decision: 'Yes', rationale: 'Asked', scope_impact: 'None' } }, 'decision_needs_work_request');
  const answered = await architect.operator(`/api/v1/sympp/operator/asks/${ask.id}/answer`, { answer: 'Yes, ship it.' });
  expect(answered.status).toBe(200);
  expect(answered.body.card_id).toBe(ask.card_id);
  expect(provider.sent).toContain(['--no-submit', '--raw', 'a1', 'Answer: Yes, ship it.']);
  // The agent can also read the answer from its card.
  const health = await early.call('sympp.health');
  expect(health.caller.card).toMatchObject({ state: 'working', asks: [{ id: ask.id, answer: 'Yes, ship it.', state: 'answered' }] });
  expect((await architect.call('sympp.health')).caller.card).toBeUndefined();

  // Dismissing from Herdr withdraws open asks; dismissing again changes nothing.
  const pending = (await early.call('ask', { question: 'Still needed?' })).ask;
  const dismiss = `/api/v1/sympp/herdr/cards/${board['Asking'].id}/dismiss`;
  const dismissed = await early.raw({}, {}, 'POST', dismiss);
  expect(dismissed.status).toBe(200);
  expect(dismissed.body).toMatchObject({ ok: true, card_id: board['Asking'].id, state: 'dismissed' });
  expect((await architect.operator(`/api/v1/sympp/operator/cards/${board['Asking'].id}/dismiss`, {})).body.state).toBe('dismissed');
  expect((await architect.operator('/api/v1/sympp/operator/cards/card_missing/dismiss', {})).status).toBe(404);
  // Its open ask was withdrawn, so it can no longer be answered.
  expect((await architect.operator(`/api/v1/sympp/operator/asks/${pending.id}/answer`, { answer: 'Too late.' })).status).toBe(409);
  await early.reject('ask', { question: 'After dismissal?' }, 'no_open_card');
  board = await cards(architect);
  expect(board['Asking']).toMatchObject({ state: 'dismissed', asks: [] });
  // A dismissed card opens again when its terminal starts another branch.
  await asking.switch('feature/asking-2');
  await observe(factory);
  expect((await cards(architect))['Asking']).toMatchObject({ state: 'working', branch: 'feature/asking-2' });
});
