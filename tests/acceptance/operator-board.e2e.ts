import { expect } from 'e2e';
import { test } from '../support/browser-candidate.js';
import { contract } from '../support/factory.js';
import { close, head, pr, prUrl, row, sync } from '../support/delivery.js';
import { repository } from '../support/worktree-git.js';
import { DatabaseSync } from 'node:sqlite';

test('operator sees dependency ordering, pending qualification and actual delivered completion', async ({ candidate, app, screen, browser, agent }) => {
  const { client, provider } = candidate;
  let request: string;
  let first!: string;
  let second!: string;
  if (candidate.recording) {
    request = candidate.recorded.work_request_details.find((detail: any) => detail.work_request.title === 'Browser delivery').work_request.id;
  } else {
  request = await client.request('Browser delivery');
  [first, second] = (await client.addPackages([contract('Service prerequisite'), contract('Dependent findings')]));
  await client.call('edit_plan', { ops: [{ op: 'set_dependency', from: second, to: first, reason: 'The service must land first.' }] });
  await client.reject('dispatch_work_package', { work_package_id: second }, 'unmet_work_package_dependencies');
  await candidate.capture('planned');
  }
  await app.open('/sympp/board');
  const goal = browser.locator(`[data-goal="${request}"]`);
  if (!candidate.recording) {
  await screen.getByText('Not started', { exact: false, visible: true }).tap();
  await expect(goal).toBeVisible();

  await client.call('dispatch_work_package', { work_package_id: first });
  await candidate.capture('dispatched');
  await browser.reload();
  }
  if (process.env.SYMPP_BROWSER_NEGATIVE === '1') {
    await agent.act('Open the sympp settings menu for the fail-closed capability probe');
    await expect(screen.getByLabel('Finished goals are archived after', { exact: false })).toBeVisible();
    throw new Error('Unrecorded model action unexpectedly returned');
  }
  await screen.getByRole('button', 'Expanded', { exact: true }).tap();
  await screen.getByRole('button', 'See all 2 packages', { exact: true }).tap();
  if (candidate.recording) return;
  provider!.set(401, pr(401, head('a'), {
    statusCheckRollup: [{ name: 'required', status: 'IN_PROGRESS', conclusion: null }], reviewDecision: 'REVIEW_REQUIRED', mergeStateStatus: 'BLOCKED',
  }));
  await client.call('sync_pr', { work_package_id: first, url: prUrl(401), head_sha: head('a') });
  await candidate.capture('ci-wait');
  await browser.reload();
  await screen.getByRole('button', 'Expanded', { exact: true }).tap();
  await expect(goal).toContainText('Stage: Checks');
  expect((await row(client, request, first)).delivery_outcome).toBeNull();
  expect((await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeNull();
  expect((await row(client, request, first)).work_package.runtime_state['active?']).toBe(false);
  provider!.set(401, pr(401, head('a')));
  await sync(client, first, 401, head('a'));
  await candidate.capture('qualified');
  await browser.reload();
  await screen.getByRole('button', 'Expanded', { exact: true }).tap();
  await expect(goal).toContainText('Stage: Merge');
  expect((await row(client, request, first)).merge_eligibility.eligible).toBe(true);

  provider!.set(401, pr(401, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await client.call('sync_pr', { work_package_id: first });
  await candidate.capture('pr-delivered');
  expect((await row(client, request, first)).delivery_outcome).toBe('pr_merged');
  await client.call('dispatch_work_package', { work_package_id: second });
  await close(client, second);
  await candidate.capture('finished');
  expect((await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeTruthy();

  const reviewRepo = await repository(candidate.root, 'browser-review');
  const reviewClient = await candidate.factory!.client();
  const reviewing = await reviewClient.request('Provider-reported review wait', 'beta', reviewRepo.origin);
  const [reviewWp] = (await reviewClient.addPackages([contract('Review provider findings', { review: { type: 'review-suite', args: { mode: 'fast' } } })]));
  const prepared = await reviewClient.call('dispatch_work_package', { work_package_id: reviewWp, review_mode: 'fast', target_repo_root: reviewRepo.checkout });
  expect(prepared.launch_line).toContain(prepared.worktree.path);
  // The factory's Observer stores the Review Suite cycle it read by review id;
  // the cockpit runs no Observer, so the journey stores what it would have read.
  const db = new DatabaseSync(candidate.factory!.database, { timeout: 5000 });
  try {
    db.prepare('INSERT INTO sympp_work_package_observations (work_package_id, review, stale, observed_at, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run(reviewWp, JSON.stringify({ evidence_id: prepared.work_package.review_id, status: 'in_progress', provider_status: 'running', current: 1, total: 2, step: 'correctness' }), '[]', ...Array(3).fill(new Date().toISOString()));
  } finally { db.close(); }
  await candidate.capture('provider-review-wait');
  expect((await row(reviewClient, reviewing, reviewWp)).delivery_outcome).toBeNull();
});

test('operator attention differs from explicit blockers and settings/archive actions persist', async ({ candidate, app, screen, browser }) => {
  const { client } = candidate;
  const request = await client.request('Operator choice');
  const [wp] = (await client.addPackages([contract('Bounded findings')]));
  await client.call('dispatch_work_package', { work_package_id: wp });
  const prematureArchive = await client.operator(`/api/v1/sympp/operator/work-requests/${request}/archive`, {});
  expect(prematureArchive.status).toBe(422);
  expect(prematureArchive.body.error.code).toBe('not_completed');
  const ask = (await client.call('ask', { work_request_id: request, question: 'Approve the bounded scope?' })).ask.id;
  await candidate.capture('operator-needed');
  await app.open('/sympp/board');
  await expect(browser.locator('title')).toHaveText(/^\(1\)\s/);
  expect((await row(client, request, wp)).work_package.blocker_state['active?']).toBe(false);
  await client.call('set_blocker', { work_package_id: wp, blocker_id: 'schema', active: true, summary: 'Required schema missing.' });
  await client.call('resolve_ask', { ask_id: ask, to: 'withdrawn' });
  await candidate.capture('blocker-without-escalation');
  await browser.reload();
  await expect(browser.locator('title')).toHaveText(/^(?!\(\d+\))\S/);
  expect((await row(client, request, wp)).work_package.blocker_state['active?']).toBe(true);

  await screen.getByRole('button', 'sympp settings', { exact: true }).tap();
  await screen.getByLabel('Finished goals are archived after', { exact: false }).fill('30');
  await screen.getByRole('button', 'Save', { exact: true }).tap();
  await expect.poll(async () => (await client.inspect('/api/v1/sympp/operator/dashboard/hydrated')).settings.work_request_archive_after_days).toBe(30);
  await browser.reload();
  await screen.getByRole('button', 'sympp settings', { exact: true }).tap();
  await expect(screen.getByLabel('Finished goals are archived after', { exact: false })).toHaveValue('30');
  await screen.getByRole('button', 'sympp settings', { exact: true }).tap();

  await close(client, wp);
  await browser.reload();
  await screen.getByRole('button', 'Actions for Operator choice', { exact: true }).tap();
  await screen.getByRole('menuitem', 'Archive', { exact: true }).tap();
  await screen.getByRole('menuitem', 'Archive?', { exact: true }).tap();
  await expect.poll(async () => (await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.archived_at).toBeTruthy();
  await screen.getByText('Archived', { exact: false, visible: true }).tap();
  await screen.getByRole('button', 'Actions for Operator choice', { exact: true }).tap();
  await screen.getByRole('menuitem', 'Restore', { exact: true }).tap();
  await screen.getByRole('menuitem', 'Restore?', { exact: true }).tap();
  await expect.poll(async () => (await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.archived_at).toBeNull();

  const intake = await client.operator('/api/v1/sympp/operator/work-requests', {
    title: 'Operator intake', repo: 'example/service', base_branch: 'beta', work_type: 'feature',
    human_description: 'Synthetic operator intake.', desired_dispatch_shape: 'architect_led_feature_branch', constraints: {},
  });
  expect(intake.status).toBe(201);
  const intakeId = intake.body.work_request.work_request.id;
  await browser.reload();
  await screen.getByText('Not started', { exact: false, visible: true }).tap();
  await expect(browser.locator(`[data-goal="${intakeId}"]`)).toBeVisible();
});

test('the person answers a question, reviews flagged decisions and releases a goal whose owner stopped answering', async ({ candidate, app, screen, browser }) => {
  const { client, factory } = candidate;
  const request = await client.request('Board review');
  const ask = (await client.call('ask', { work_request_id: request, question: 'Which scope should ship?', decision_prompt: {
    tl_dr: 'Choose scope', details: 'Keep this delivery bounded.',
    options: [{ id: 'bounded', label: 'Bounded option', answer: 'Ship the bounded option.' }, { id: 'wide', label: 'Wide option', answer: 'Ship everything.' }],
  } })).ask.id;
  const recorder = await factory!.client();
  const flag = async (decision: string) => (await recorder.call('record_decision', {
    work_request_id: request, source_type: 'architect', decision, rationale: 'Pricing differs by region.', scope_impact: 'None', flag: true,
  })).decision_log_entry.id;
  const feedbackOn = await flag('Use regional prices.');
  await candidate.capture('question-and-decision');
  await app.open('/sympp/board');
  const full = () => client.call('read_work_request', { detail: 'full', work_request_id: request });
  const answer = async () => (await full()).asks.find((entry: any) => entry.id === ask);
  const decision = async (id: string) => (await full()).decision_log_entries.find((entry: any) => entry.id === id);

  await screen.getByRole('radio', 'Bounded option', { exact: true }).tap();
  await screen.getByLabel('Note', { exact: true }).fill('Keep it small.');
  await screen.getByRole('button', 'Send', { exact: true }).tap();
  await expect.poll(async () => (await answer()).state).toBe('answered');
  expect(await answer()).toMatchObject({ answer: 'Ship the bounded option. Keep it small.', answered_by: 'operator' });

  // The recording terminal is not on this factory's machine, so the feedback stays on the decision, undelivered.
  await screen.getByRole('button', 'Feedback', { exact: true }).tap();
  await screen.getByLabel(`Feedback for ${recorder.address}`, { exact: true }).fill('Prefer one global price.');
  await screen.getByRole('button', 'Send', { exact: true }).tap();
  await expect.poll(async () => (await decision(feedbackOn)).review_state).toBe('feedback');
  expect(await decision(feedbackOn)).toMatchObject({ feedback: 'Prefer one global price.' });
  await screen.getByRole('button', 'Dismiss undelivered feedback', { exact: true }).tap();

  const acked = await flag('Launch in Europe first.');
  await candidate.capture('second-decision');
  await browser.reload();
  await screen.getByRole('button', 'Ack', { exact: true }).tap();
  await expect.poll(async () => (await decision(acked)).review_state).toBe('acknowledged');

  // The goal's owner is not answering here; Release hands the goal to whoever writes next.
  const [wp] = await client.addPackages([contract('Regional pricing')]);
  await client.call('dispatch_work_package', { work_package_id: wp });
  await candidate.capture('owned-active-goal');
  await browser.reload();
  await screen.getByRole('button', 'Release', { exact: true }).tap();
  await screen.getByRole('button', 'Release?', { exact: true }).tap();
  await expect.poll(async () => (await client.call('sympp.health')).caller.owns).toEqual([]);
  await recorder.call('set_report', { work_request_id: request, brief: 'Taken over after Release.' });
});
