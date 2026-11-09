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
  await expect(goal).toContainText('0/2 done');

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
  await expect(screen.getByRole('button', 'See all 2 packages', { exact: true })).toBeVisible();
  await screen.getByRole('button', 'See all 2 packages', { exact: true }).tap();
  await expect(goal).toContainText('Service prerequisite');
  await expect(goal).toContainText('Dependent findings');
  await expect(goal).toContainText('Planned');
  await expect(goal).toContainText('0/2 done');
  await screen.getByRole('button', 'sympp settings', { exact: true }).tap();
  await expect(screen.getByLabel('Finished goals are archived after', { exact: false })).toBeVisible();
  await screen.getByRole('button', 'sympp settings', { exact: true }).tap();
  if (candidate.recording) return;
  provider!.set(401, pr(401, head('a'), {
    statusCheckRollup: [{ name: 'required', status: 'IN_PROGRESS', conclusion: null }], reviewDecision: 'REVIEW_REQUIRED', mergeStateStatus: 'BLOCKED',
  }));
  await client.call('sync_pr', { work_package_id: first, url: prUrl(401), head_sha: head('a') });
  await candidate.capture('ci-wait');
  await browser.reload();
  await screen.getByRole('button', 'Expanded', { exact: true }).tap();
  await expect(goal).toContainText('Review/CI');
  await expect(goal).toContainText('CI running');
  expect((await row(client, request, first)).delivery_outcome).toBeNull();
  expect((await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.completed_at).toBeNull();
  expect((await row(client, request, first)).work_package.runtime_state['active?']).toBe(false);
  provider!.set(401, pr(401, head('a')));
  await sync(client, first, 401, head('a'));
  await candidate.capture('qualified');
  await browser.reload();
  await screen.getByRole('button', 'Expanded', { exact: true }).tap();
  await expect(goal).toContainText('0/2 done');
  await expect(goal).toContainText('Ready');
  expect((await row(client, request, first)).merge_eligibility.eligible).toBe(true);

  provider!.set(401, pr(401, head('a'), { state: 'MERGED', mergedAt: new Date().toISOString(), mergeCommit: { oid: head('f') } }));
  await client.call('sync_pr', { work_package_id: first });
  await candidate.capture('pr-delivered');
  await browser.reload();
  await expect(goal).toContainText('1/2 done');
  expect((await row(client, request, first)).delivery_outcome).toBe('pr_merged');
  await client.call('dispatch_work_package', { work_package_id: second });
  await close(client, second);
  await candidate.capture('finished');
  await browser.reload();
  await expect(goal).toContainText('All 2 packages have ended.');
  await expect(screen.getByRole('heading', 'Landed · last 24 hours')).toBeVisible();
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
  await browser.reload();
  await expect(browser.locator(`[data-goal="${reviewing}"]`)).toContainText('fast · running');
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
  const goal = browser.locator(`[data-goal="${request}"]`);
  await expect(screen.getByText('Approve the bounded scope?', { visible: true })).toBeVisible();
  await expect(goal).toContainText('Needs you');
  await expect(browser.locator('title')).toHaveText(/^\(1\)\s/);
  expect((await row(client, request, wp)).work_package.blocker_state['active?']).toBe(false);
  await client.call('set_blocker', { work_package_id: wp, blocker_id: 'schema', active: true, summary: 'Required schema missing.' });
  await client.call('resolve_ask', { ask_id: ask, to: 'withdrawn' });
  await candidate.capture('blocker-without-escalation');
  await browser.reload();
  await expect(screen.getByText('Approve the bounded scope?')).toHaveCount(0);
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
  await screen.getByRole('button', 'Archive', { exact: false }).tap();
  await screen.getByRole('button', 'Archive? Click again', { exact: false }).tap();
  await expect(goal).toContainText('archived');
  expect((await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.archived_at).toBeTruthy();
  await screen.getByText('Archived', { exact: false, visible: true }).tap();
  await screen.getByRole('button', 'Actions for Operator choice', { exact: true }).tap();
  await screen.getByRole('button', 'Restore', { exact: false }).tap();
  await screen.getByRole('button', 'Restore? Click again', { exact: false }).tap();
  await expect(goal).toContainText('All 1 packages have ended.');
  expect((await client.inspect(`/api/v1/sympp/operator/work-requests/${request}`)).work_request.archived_at).toBeNull();

  const intake = await client.operator('/api/v1/sympp/operator/work-requests', {
    title: 'Operator intake', repo: 'example/service', base_branch: 'beta', work_type: 'feature',
    human_description: 'Synthetic operator intake.', desired_dispatch_shape: 'architect_led_feature_branch', constraints: {},
  });
  expect(intake.status).toBe(201);
  const intakeId = intake.body.work_request.work_request.id;
  await browser.reload();
  await screen.getByText('Not started', { exact: false, visible: true }).tap();
  await expect(browser.locator(`[data-goal="${intakeId}"]`)).toContainText('Operator intake');
});
