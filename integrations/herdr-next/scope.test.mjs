// The Topic, Space and task views' rules: what the person is asked, what went wrong, the strip, the
// order and the folds, from the board as model.js parses it.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as M from './mods/sympp/model.js';
import * as L from './mods/sympp/levels.js';
import * as S from './mods/sympp/scope.js';
import { NOW, boardPayload, variantPayload, deskFixture } from './fixture.mjs';

const jobsOf = (payload) => M.parseBoard(payload).jobs;
const jobOf = (payload, id) => jobsOf(payload).find((job) => job.id === id);
const task = (payload, id) => S.taskOf(jobOf(payload, id), NOW);

test("asks are the only Needs you, each answered through its own route, a card's as a task's", () => {
  const busy = variantPayload('busy');
  const pr = task(busy, 'wr-pr');
  assert.deepEqual(pr.asks.map((a) => [a.text, a.question.route, a.by.address]), [['Which order should the levels land in?', '/api/v1/sympp/herdr/asks/q1/answer', 'box/t4']]);
  assert.equal(pr.asks[0].question.prompt.options.find((o) => o.recommended).id, 'board_first', 'the decision prompt comes with it');
  const card = M.parseBoard(busy).cards.find((c) => c.id === 'card-flicker');
  assert.deepEqual(card.needs.map((n) => [n.text, n.ask.route]), [['OK to drop the resize workaround for Windows 10?', '/api/v1/sympp/herdr/asks/ask-flicker/answer']]);
  const odd = variantPayload('busy');
  odd.work_request_details[0].asks = [{ id: 'x', question: '  ' }, { id: 'y', question: 'Pick one?', answer_route: '//evil.example/answer' }];
  assert.deepEqual(task(odd, 'wr-pr').asks.map((a) => [a.text, a.question.route]), [['Pick one?', '/api/v1/sympp/herdr/asks/y/answer']], 'an answer only goes to this factory');
});

test("a task's checks are one live signal, with a slot from the start only where its repository runs CI", () => {
  const busy = variantPayload('busy');
  const ci = (id) => task(busy, id).ci;
  assert.equal(ci('wr-restore'), 'failed', 'any failing check wins');
  assert.equal(ci('wr-status'), 'running', 'then any running one, during review too');
  assert.equal(ci('wr-pr'), 'passed', 'a package with no PR yet does not hold back the ones that passed');
  assert.equal(ci('wr-cross'), 'waiting', 'a repository with CI keeps the slot before any PR opens');
  assert.equal(ci('wr-notes'), null, 'a repository without CI has no slot, even with a PR open');
  const external = variantPayload('busy');
  external.work_request_details.find((d) => d.work_request.id === 'wr-notes').work_packages[0].pr_signal.checks = { status: 'failing' };
  assert.equal(task(external, 'wr-notes').ci, 'failed', 'checks the PR reports show even when the checkout has no workflows');
  assert.equal(ci('wr-nopr'), null, 'nor does work that opens no PR');
  const unknown = variantPayload('busy');
  for (const d of unknown.work_request_details) for (const p of d.work_packages ?? []) delete p.repo_signal;
  assert.equal(task(unknown, 'wr-cross').ci, null, 'without the flag, no slot until checks report');
  assert.equal(task(unknown, 'wr-restore').ci, 'failed');
  const unread = (ci) => S.ciOf({ ci, track: 'pr', stage: 'review', pr: { checks: 'unavailable' } });
  assert.deepEqual([unread(true), unread(null)], ['unknown', null], 'checks that cannot be read keep the slot but claim nothing');
});

test('a review reads as its mode and state in a word or two, and a package dispatched without a worker yet reads as launching', () => {
  const pkgs = Object.fromEntries(jobsOf(variantPayload('busy')).flatMap((job) => job.packages).map((p) => [p.id, p]));
  assert.deepEqual(['r-4', 'r-5', 'r-7', 'n-1', 'r-6'].map((id) => S.reviewText(pkgs[id].review)), ['deep · round 3', 'normal · findings', 'fast · done', 'no review', null]);
  assert.deepEqual(['s-3', 'r-6', 't-1'].map((id) => S.unmanned(pkgs[id])), [true, false, false]);
});

test("a package's step comes from its status and derived progress, and only an open PR into another repository can be finished", () => {
  const pkgs = Object.fromEntries(jobsOf(variantPayload('busy')).flatMap((job) => job.packages).map((p) => [p.id, p]));
  assert.deepEqual(['k-1', 's-3', 'r-6', 'r-4', 'r-7', 'r-1', 'c-2'].map((id) => pkgs[id].stage), ['planned', 'launching', 'implementing', 'review_ci', 'ready', 'ended', 'ended']);
  assert.deepEqual(['r-1', 'b-2', 'np-1', 'c-2', 'c-3'].map((id) => [pkgs[id].ending, pkgs[id].outcome]),
    [['pr_merged', 'merged'], ['finished', 'finished'], ['completed_no_pr', 'finished'], ['abandoned', 'dropped'], ['skipped', 'dropped']]);
  assert.deepEqual(Object.values(pkgs).filter((p) => p.finishable).map((p) => p.id), ['u-2'], 'upstream/core#97 from owner/web');
  assert.equal(pkgs['b-2'].finishable, false, 'a finished package has nothing left to finish');
  assert.deepEqual(['r-4', 'u-2', 's-3'].map((id) => pkgs[id].owner?.liveness ?? null), ['live', 'finished', null]);
});

test('decisions to review are the recorded ones and feedback that never reached its terminal, until dismissed', () => {
  const payload = variantPayload('busy');
  const recap = payload.work_request_details.find((d) => d.work_request.id === 'wr-recap');
  recap.decisions.push(
    { id: 'seen', decision: 'Acked call.', review_state: 'acknowledged' },
    { id: 'sent', decision: 'Delivered call.', review_state: 'feedback', feedback: 'ok', delivered: true },
    { id: 'gone', decision: 'Dismissed call.', review_state: 'feedback', feedback: 'later', delivered: false, dismissed_at: new Date(NOW).toISOString() },
  );
  const jobs = jobsOf(payload);
  assert.deepEqual(L.decisionQueue(jobs).map((d) => [d.id, d.undelivered]), [['dec-share', true], ['dec-order', false], ['dec-toast', false]], 'oldest first');
  assert.equal(L.decisionQueue(jobs)[0].feedback, 'Keep share links on the list for Q1; two agencies asked.');
});

test('phases come from group paths: the strip runs each first segment apart, and nested groups sit inside their phase', () => {
  const restore = task(variantPayload('busy'), 'wr-restore');
  assert.deepEqual(restore.strip.map((r) => [r.phase, r.pkgs.map((p) => p.id)]), [['Core', ['r-1', 'r-2', 'r-3']], ['Recovery', ['r-4', 'r-5', 'r-6']], ['Polish', ['r-7', 'r-8', 'r-9']]]);
  assert.deepEqual(task(boardPayload(), 'wr-pr').strip.map((r) => r.pkgs.map((p) => p.id)), [['wp-done', 'wp-build', 'wp-review', 'wp-queued']], 'without groups, one run in planned order');
  const tree = S.groupTree(S.packageParts(restore).active);
  const shape = (node) => [node.name, node.items.map((e) => e.pkg.id), node.children.map(shape)];
  assert.deepEqual(tree.map(shape), [['Recovery', ['r-4'], [['Shell', ['r-5', 'r-6'], []]]], ['Polish', ['r-7'], []]]);
  const mixed = variantPayload('busy');
  const restoreDetail = mixed.work_request_details.find((d) => d.work_request.id === 'wr-restore');
  restoreDetail.work_packages.find((p) => p.id === 'r-5').group = ' Recovery /  Shell ';
  delete restoreDetail.work_packages.find((p) => p.id === 'r-7').group;
  assert.deepEqual(S.groupTree(S.packageParts(task(mixed, 'wr-restore')).active).map(shape), [['Recovery', ['r-4'], [['Shell', ['r-5', 'r-6'], []]]], [null, ['r-7'], []]],
    'segments are trimmed and ungrouped work comes last');
});

test('needs come first, then the rest by when they opened; a task does not move when it advances', () => {
  const { topics, spaces } = deskFixture();
  const desk = L.deskOf(topics, spaces);
  const order = (payload) => {
    const jobs = jobsOf(payload);
    return S.scopeTasks({ topic: 't-herdr' }, desk, jobs, L.placeJobs(jobs, desk), NOW).map((t) => t.job.id);
  };
  const busy = order(variantPayload('busy'));
  assert.deepEqual(busy.slice(0, 2).sort(), ['wr-cross', 'wr-pr']);
  const before = order(variantPayload('quiet'));
  const advanced = variantPayload('quiet');
  const theme = advanced.work_request_details.find((d) => d.work_request.id === 'wr-theme').work_packages[0];
  theme.progress = { stage: 'review_ci', since: new Date(NOW - 60e3).toISOString() };
  assert.deepEqual(order(advanced), before);
  const space = S.scopeTasks({ topic: 't-tools', space: 'vps/s-api' }, desk, jobsOf(variantPayload('busy')), null, NOW).map((t) => t.job.id);
  assert.deepEqual(space.sort(), ['wr-cross', 'wr-restore'], 'a space keeps only the tasks on its repository');
});

test('a task shows its packages at work and the ones waiting on the person; landed and queued ones fold', () => {
  const parts = S.packageParts(task(variantPayload('busy'), 'wr-restore'));
  assert.deepEqual([parts.active, parts.landed, parts.queued].map((list) => list.map((e) => e.pkg.id)), [['r-4', 'r-5', 'r-6', 'r-7'], ['r-1', 'r-2', 'r-3'], ['r-8', 'r-9']]);
  const pr = S.packageParts(task(variantPayload('busy'), 'wr-pr'));
  assert.ok(pr.active.some((e) => e.pkg.id === 'wp-review' && !e.needsYou), 'a textless human next actor never creates attention');
});


test('an open ask keeps a task with only landed work in view and keeps its age across polls', () => {
  const payload = variantPayload('busy');
  const detail = payload.work_request_details[0];
  detail.work_packages = detail.work_packages.map((p) => ({ ...p, status: 'ended', progress: null, delivery: { outcome: 'pr_merged', recorded_at: new Date(NOW - 7200e3).toISOString() } }));
  detail.asks[0].asked_at = new Date(NOW - 3600e3).toISOString();
  const before = jobOf(payload, 'wr-pr');
  payload.generated_at = new Date(NOW + 2 * 86400e3).toISOString();
  const after = jobOf(payload, 'wr-pr');
  assert.equal(after.lane, 'moving');
  assert.equal(after.verdict, 'needs_you');
  assert.equal(S.taskOf(after, NOW).asks[0].text, 'Which order should the levels land in?');
  assert.equal(after.needs[0].since, NOW - 3600e3);
  assert.equal(L.toastId(after.needs[0]), L.toastId(before.needs[0]));
});

test('a topic shows the small work on its repositories, open cards first', () => {
  const { topics, spaces } = deskFixture();
  const desk = L.deskOf(topics, spaces);
  const board = M.parseBoard(variantPayload('busy'));
  const place = L.placeJobs([...board.jobs, ...board.cards], desk);
  assert.deepEqual(S.scopeCards({ topic: 't-herdr' }, desk, board.cards, place).map((c) => c.id), ['card-tokens', 'card-flicker', 'card-typos']);
  assert.deepEqual(S.scopeCards({ topic: 't-tools', space: 'vps/s-api' }, desk, board.cards, place).map((c) => c.id), ['card-ocr', 'card-logs']);
  const dismissed = variantPayload('busy');
  dismissed.cards.find((c) => c.id === 'card-logs').state = 'dismissed';
  assert.equal(M.parseBoard(dismissed).cards.some((c) => c.id === 'card-logs'), false, 'a dismissed card leaves');
});
