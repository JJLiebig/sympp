// A small hydrated board: one PR job across every stage, one job without PRs, one still being
// shaped and one across two repositories that needs the person, with a Herdr chief that created the
// first and dispatched packages in both. Shapes follow GET /api/v1/sympp/herdr/dashboard;
// deskFixture() is the matching Herdr topics and spaces, chiefTerminals() the chiefs' terminals.
export const NOW = Date.parse('2026-10-25T13:00:00Z');
const at = (minutesAgo) => new Date(NOW - minutesAgo * 60e3).toISOString();

const pkg = (id, title, sequence, board, extra = {}) => ({
  id, work_package_id: id, title, sequence, repo: 'owner/web', inserted_at: at(600), board_state: board, ...extra,
});

// The chiefs Start chief labelled: Herdr in t7, Live in t5, and a finished one that no longer counts.
export function chiefTerminals() {
  return [
    { address: 't7', pid: 70, state: 'live', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Herdr' } },
    { address: 't5', pid: 50, state: 'live', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Live' } },
    { address: 't3', pid: 30, state: 'finished', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Tools' } },
    { address: 't2', pid: 20, state: 'live', labels: { 'sympp.domain': 'Tools' } },
  ];
}

// An open ask as the board reports it, with its answer route.
const ask = (id, text, askedAt) => ({ id, kind: 'ask', text, work_package_id: null, decision_prompt: null, asked_by: 'build-desk/t4', asked_at: at(askedAt), answer_route: `/api/v1/sympp/herdr/asks/${id}/answer` });

export function boardPayload() {
  return {
    generated_at: new Date(NOW).toISOString(),
    runtime: { offline: false },
    work_packages: [{ id: 'wp-build', active_agent_run: { attempt: 2, last_seen_at: at(3), stale: false } }],
    work_request_details: [
      {
        work_request: {
          id: 'wr-pr', title: 'Native job tab', repo: 'owner/web', phase: 'active', base_branch: 'main',
          inserted_at: at(3000), worked_on: { address: 'build-desk/t4', role: 'architect', liveness: 'live', since: at(20) },
          dispatched_by: { kind: 'chief', domain: 'herdr' },
        },
        product_tree: { execution_graph: { effective_edges: [
          { prerequisite_work_package_id: 'wp-done', dependent_work_package_id: 'wp-build' },
          { prerequisite_work_package_id: 'wp-build', dependent_work_package_id: 'wp-queued' },
          { prerequisite_work_package_id: 'wp-review', dependent_work_package_id: 'wp-queued' },
        ] } },
        asks: [ask('ask-order', 'Which order should the levels land in?', 60)],
        work_packages: [
          pkg('wp-queued', 'Factory level', 4, { stage: 'queued', track: 'pr' }, { dependency_signal: { unmet_work_package_ids: ['wp-build'] } }),
          pkg('wp-build', 'Stage board', 2, { stage: 'build', track: 'pr', entered_at: at(90) }, {
            dispatched_at: at(90), dispatched_by: { kind: 'chief', domain: 'Herdr' },
            activity_signal: { current_actor: { role: 'worker', name: 'codex-board' }, observation_state: 'current', next_actor: 'worker', next_action: 'open_pr' },
          }),
          pkg('wp-review', 'Review lens', 3, { stage: 'review', track: 'pr', entered_at: at(40) }, {
            dispatched_at: at(300), pr_signal: { status: 'open', number: 812, checks: { status: 'passing' } },
            review_signal: {
              type: 'review_suite', mode: 'fast', status: 'in_progress', provider_status: 'decision-pending', round: 3,
              started_at: at(200), round_started_at: at(40), observed_at: at(2), observation_state: 'current',
              steps: [{ index: 0, name: 'arena-base-review', state: 'done' }, { index: 1, name: 'base-signoff', state: 'current' }],
              round_history: [
                { number: 1, lane: 'review_t1', step: 'arena-base-review', status: 'decided', started_at: at(200), finished_at: at(150), outcome: 'findings', findings: 4 },
                { number: 2, lane: 'review-followup', step: null, status: 'decided', started_at: at(120), finished_at: at(60), outcome: 'findings', findings: 2 },
                { number: 3, lane: 'review_t1', step: 'base-signoff', status: 'decision-pending', started_at: at(40), finished_at: null, outcome: null, findings: null },
              ],
            },
            activity_signal: { current_actor: { role: 'worker', name: 'opus-lens' }, observation_state: 'stale', waiting_reason: 'review_in_progress', next_actor: 'worker', next_action: 'address_findings', last_update_at: at(25) },
          }),
          // Landed a day before the rest started: a long stretch nobody acted in.
          pkg('wp-done', 'Module split', 1, { stage: 'done', track: 'pr', delivered: true, entered_at: at(1800) }, {
            inserted_at: at(3000), dispatched_at: at(2900), pr_signal: { status: 'merged', number: 801 },
            review_signal: { type: 'review_suite', mode: 'fast', status: 'passed', round: '1', started_at: at(2000) },
          }),
        ],
      },
      {
        work_request: { id: 'wr-nopr', title: 'Research spike', repo: 'owner/notes', phase: 'active', inserted_at: at(400) },
        work_packages: [
          pkg('np-1', 'Survey', 1, { stage: 'done', track: 'no_pr', delivered: true, entered_at: at(200) }, { repo: 'owner/notes', dispatched_at: at(300) }),
          pkg('np-2', 'Write-up', 2, { stage: 'build', track: 'no_pr' }, { repo: 'owner/notes', dispatched_at: at(100) }),
        ],
      },
      { work_request: { id: 'wr-shaping', title: 'New idea', repo: 'owner/web', phase: 'intake', inserted_at: at(30) } },
      {
        work_request: {
          id: 'wr-cross', title: 'Shared tokens', repo: 'owner/api', phase: 'active', inserted_at: at(1000),
          operator_report: {
            brief: { text: 'Token API is building; the UI waits on it and on your call.', written_at: at(60) },
          },
        },
        product_tree: { execution_graph: { effective_edges: [{ prerequisite_work_package_id: 'x-api', dependent_work_package_id: 'x-web' }] } },
        asks: [ask('ask-tokens', 'Ship tokens before the API?', 240)],
        work_packages: [
          pkg('x-api', 'Token API', 1, { stage: 'build', track: 'pr', entered_at: at(120) }, { repo: 'owner/api', dispatched_at: at(120), dispatched_by: { kind: 'chief', domain: 'Herdr' } }),
          pkg('x-web', 'Token UI', 2, { stage: 'queued', track: 'pr' }, { dependency_signal: { unmet_work_package_ids: ['x-api'] } }),
        ],
      },
    ],
  };
}

// Board variants for design previews; the default board above stays as the tests know it.
// "busy" adds tasks of every size: one package in one repository up to many across three, in
// trouble, stuck, without a recent report, landed and planned; PR checks not started, running,
// passed and failed; reviews in each Review Suite step; a repository without CI; and a package no
// worker has taken. "quiet" is the busy board with nothing waiting on the person and nothing wrong.
// Live packages report current activity unless a case says otherwise. `repo_signal.has_ci` says
// whether the package's repository runs CI at all. Review steps are Review Suite's deep profile; a
// review past its last step waits on the GitHub review.
const CI = { 'owner/web': true, 'owner/api': true, 'owner/notes': false };
const reviewSteps = (current) => {
  const names = ['base-signoff', 'arena-deep-review', 'deep-signoff'];
  const at = current === null ? names.length : names.indexOf(current);
  return names.map((name, index) => ({ index, name, state: index < at ? 'done' : index === at ? 'current' : 'pending' }));
};

export function variantPayload(variant) {
  const board = boardPayload();
  if (variant !== 'busy' && variant !== 'quiet') return board;
  const quiet = variant === 'quiet';
  const step = (id, title, sequence, stage, minutes, extra = {}) => pkg(id, title, sequence,
    { stage, track: 'pr', delivered: stage === 'done', entered_at: at(minutes) },
    { dispatched_at: at(minutes + 30), activity_signal: { observation_state: 'current' }, ...extra });
  board.work_request_details.push(
    {
      work_request: { id: 'wr-restore', title: 'Restore sessions after a reboot', repo: 'owner/web', phase: 'active', inserted_at: at(2400) },
      // The architect's group paths: the web board strips each top-level group apart, nested ones inside it.
      work_packages: [
        step('r-1', 'Session ledger', 1, 'done', 1500, { group: 'Core', repo: 'owner/api' }),
        step('r-2', 'Holder adoption', 2, 'done', 1200, { group: 'Core', repo: 'owner/api' }),
        step('r-3', 'Resume command table', 3, 'done', 700, { group: 'Core' }),
        step('r-4', 'Recovery toast', 4, 'review', 50, { group: 'Recovery', pr_signal: { status: 'open', number: 830, url: 'https://github.com/owner/web/pull/830', checks: { status: 'passing' } },
          review_signal: { type: 'review_suite', mode: 'fast', status: 'in_progress', round: quiet ? 1 : 3, started_at: at(quiet ? 50 : 260), round_started_at: at(50), steps: reviewSteps('deep-signoff') } }),
        step('r-5', 'Shell fallback', 5, 'checks', 35, { group: 'Recovery / Shell', repo: 'owner/api', pr_signal: { status: 'open', number: 14, checks: { status: quiet ? 'pending' : 'failing' } } }),
        step('r-6', 'Remote cores', 6, 'build', 25, { group: 'Recovery', repo: 'owner/api' }),
        step('r-7', 'Settings toggle', 7, 'merge', 10, { group: 'Polish', pr_signal: { status: 'open', number: 829, checks: { status: 'passing' } } }),
        pkg('r-8', 'Docs and changelog', 8, { stage: 'queued', track: 'pr' }, { group: 'Polish', repo: 'owner/notes', dependency_signal: { unmet_work_package_ids: ['r-4'] } }),
        pkg('r-9', 'Crash replay test', 9, { stage: 'queued', track: 'pr' }, { group: 'Polish' }),
      ],
    },
    {
      work_request: { id: 'wr-theme', title: 'Follow the system theme', repo: 'owner/web', phase: 'active', inserted_at: at(80) },
      work_packages: [step('t-1', 'Theme listener', 1, 'build', 40, {
        pr_signal: { status: 'open', number: 833, checks: { status: 'pending' } }, ...(quiet ? {} : { activity_signal: { observation_state: 'stale' } }),
      })],
    },
    {
      work_request: { id: 'wr-status', title: 'Quieter status bar', repo: 'owner/web', phase: 'active', inserted_at: at(150) },
      work_packages: [
        step('s-1', 'Status colours', 1, 'review', 30, { pr_signal: { status: 'open', number: 835, checks: { status: 'passing' } },
          review_signal: { type: 'review_suite', mode: 'fast', status: 'in_progress', round: 2, started_at: at(90), round_started_at: at(12), steps: reviewSteps(null), next_action: 'github_review' } }),
        // Pushed during review: its checks run again.
        step('s-2', 'Bar layout', 2, 'review', 20, { pr_signal: { status: 'open', number: 836, checks: { status: 'pending' } },
          review_signal: { type: 'review_suite', mode: 'fast', status: 'in_progress', round: 1, started_at: at(20), round_started_at: at(20), steps: reviewSteps('base-signoff') } }),
        // Dispatched to Build, but no worker has taken it yet.
        pkg('s-3', 'Status tooltip', 3, { stage: 'build', track: 'pr', entered_at: at(5) }),
      ],
    },
    {
      work_request: { id: 'wr-notes', title: 'Release notes template', repo: 'owner/notes', phase: 'active', inserted_at: at(100) },
      work_packages: [step('n-1', 'Template', 1, 'build', 15, { repo: 'owner/notes', pr_signal: { status: 'open', number: 21 } })],
    },
    {
      work_request: { id: 'wr-docs', title: 'Operator guide refresh', repo: 'owner/web', phase: 'active', inserted_at: at(3000) },
      work_packages: quiet
        ? [step('d-1', 'Outline', 1, 'done', 900), step('d-2', 'Screens', 2, 'done', 600), step('d-3', 'Install chapter', 3, 'build', 20), pkg('d-4', 'Troubleshooting', 4, { stage: 'queued', track: 'pr' })]
        : [step('d-1', 'Outline', 1, 'done', 900), step('d-2', 'Screens', 2, 'done', 400), pkg('d-3', 'Install chapter', 3, { stage: 'queued', track: 'pr' }), pkg('d-4', 'Troubleshooting', 4, { stage: 'queued', track: 'pr' })],
    },
    {
      work_request: { id: 'wr-badges', title: 'Agent badges in the sidebar', repo: 'owner/web', phase: 'active', inserted_at: at(1400) },
      work_packages: [step('b-1', 'Badge art', 1, 'done', 500), step('b-2', 'Badge slot', 2, 'done', 300)],
    },
    {
      work_request: { id: 'wr-keys', title: 'Keyboard map for every level', repo: 'owner/web', phase: 'planned', inserted_at: at(200) },
      work_packages: [pkg('k-1', 'Key table', 1, { stage: 'queued', track: 'pr' }), pkg('k-2', 'Help overlay', 2, { stage: 'queued', track: 'pr' })],
    },
  );
  if (quiet) {
    board.work_request_details[0].asks = [];
    board.work_request_details[3].asks = [];
  }
  for (const detail of board.work_request_details) {
    for (const p of detail.work_packages ?? []) p.repo_signal = { has_ci: CI[p.repo] };
  }
  const tokenApi = board.work_request_details[3].work_packages.find((p) => p.id === 'x-api');
  tokenApi.activity_signal = { observation_state: 'current' };
  if (quiet) {
    const review = board.work_request_details[0].work_packages.find((p) => p.id === 'wp-review');
    review.activity_signal = { current_actor: { role: 'worker', name: 'opus-lens' }, observation_state: 'current', next_actor: 'worker', next_action: 'address_findings' };
    review.review_signal = { ...review.review_signal, round: 1, started_at: at(40), round_history: [] };
  }
  return board;
}

// Herdr's own grouping for the board above: the web space under Herdr, a remote api space under
// Personal Tools, an empty topic, and unsorted spaces with and without sympp work.
export function deskFixture() {
  const space = (id, name, folder, machine = null, extra = {}) => ({ id, index: 1, name, named: false, folder, machine, branch: null, active: false, status: null, tabs: [], ...extra });
  return {
    topics: {
      groups: [
        { id: 't-herdr', name: 'Herdr', spaces: ['s-web', 's-gone'], folded: false },
        { id: 't-tools', name: 'Personal Tools', spaces: ['vps/s-api'], folded: false },
        { id: 't-live', name: 'Nextide-Live', spaces: [], folded: false },
      ],
      unsorted: ['s-notes'],
    },
    spaces: [
      space('s-web', 'web', String.raw`C:\code\owner\web`, null, { active: true, branch: 'main', tabs: [{ id: 'tab-web' }, { id: 'tab-job' }] }),
      space('s-notes', 'notes', String.raw`C:\code\notes`),
      space('s-home', '~', String.raw`C:\Users\me`),
      space('vps/s-api', 'api', '/home/me/api', 'vps'),
    ],
  };
}
