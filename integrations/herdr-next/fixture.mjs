// A small hydrated v2 board: one PR job with a package in each step, one job without PRs, one still
// being shaped and one across two repositories that asks the person, with a Herdr chief that
// dispatched packages in both. Shapes follow GET /api/v1/sympp/herdr/dashboard as v2 serves it:
// derived package progress, "worked on by" terminals, asks, flagged decisions and cards.
// deskFixture() is the matching Herdr topics and spaces, chiefTerminals() the chiefs' terminals, and
// applyDemo() plays an operator action on a payload in memory for the preview.
export const NOW = Date.parse('2026-10-25T13:00:00Z');
const at = (minutesAgo) => new Date(NOW - minutesAgo * 60e3).toISOString();

// A terminal working on a task or card; sample addresses name machines that don't exist, so no
// action can reach a real terminal.
const term = (address, role, liveness = 'live', since = 60) => ({ address, role, liveness, since: at(since) });
// A package's worker terminal as the factory's core reports it.
const worker = (address, liveness = 'live') => ({ address, state: liveness === 'finished' ? 'finished' : 'live', status: liveness === 'unknown' ? 'unknown' : 'working' });

// A package. `progress` only while dispatched; an ending has its outcome.
const pkg = (id, title, sequence, status, extra = {}) => ({
  id, work_package_id: id, title, sequence, repo: 'owner/web', inserted_at: at(600), status, pr_signal: { status: 'none' }, ...extra,
});
const going = (progress, since, extra = {}) => ({ ...(progress ? { progress } : {}), board_state: { entered_at: at(since) }, dispatched_at: at(since + 30), ...extra });
const ended = (outcome, minutes, extra = {}) => ({ delivery: { outcome, recorded_at: at(minutes) }, ...extra });
const pr = (repo, number, checks = null, status = 'open') => ({
  status, number, repository: repo, url: `https://github.com/${repo}/pull/${number}`, ...(checks ? { checks: { status: checks, changed_at: at(8) } } : {}),
});
// Review Suite's signal for a package dispatched with a review mode; mode none has none.
const STATUS = { running: 'in_progress', findings: 'failed', done: 'passed' };
const review = (mode, state = null, round = 1, extra = {}) => (mode === 'none' ? undefined
  : { type: 'review-suite', mode, status: STATUS[state] ?? 'pending', round, observation_state: 'current', ...extra });
// An open ask as the native board lists it, with its answer route.
const ask = (id, text, askedBy, minutes, extra = {}) => ({
  id, kind: 'ask', text, work_package_id: null, decision_prompt: null, asked_by: askedBy, asked_at: at(minutes),
  answer_route: `/api/v1/sympp/herdr/asks/${id}/answer`, ...extra,
});
// A flagged decision to review, with the routes its state allows.
const decision = (id, wr, text, rationale, by, minutes, extra = {}) => withRoutes({
  id, work_request_id: wr, decision: text, rationale, scope_impact: null, recorded_by: by, created_at: at(minutes), review_state: 'recorded', feedback: null, undelivered_reason: null, ...extra,
});
function withRoutes(d) {
  const base = `/api/v1/sympp/herdr/decisions/${d.id}`;
  for (const key of ['ack_route', 'feedback_route', 'dismiss_route']) delete d[key];
  if (d.review_state === 'recorded') Object.assign(d, { next_action: 'ack or feedback', ack_route: `${base}/ack`, feedback_route: `${base}/feedback` });
  else if (d.undelivered_reason) Object.assign(d, { next_action: 'dismiss', dismiss_route: `${base}/dismiss` });
  else d.next_action = 'none';
  return d;
}

// The chiefs Start chief labelled: Herdr in t7, Live in t5, and a finished one that no longer counts.
export function chiefTerminals() {
  return [
    { address: 't7', pid: 70, state: 'live', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Herdr' } },
    { address: 't5', pid: 50, state: 'live', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Live' } },
    { address: 't3', pid: 30, state: 'finished', labels: { 'sympp.role': 'chief', 'sympp.domain': 'Tools' } },
    { address: 't2', pid: 20, state: 'live', labels: { 'sympp.domain': 'Tools' } },
  ];
}

const ARCHITECT = term('box/t4', 'architect', 'live', 20);
const CHIEF = term('box/t0hd', 'chief', 'live', 300);

export function boardPayload() {
  return {
    generated_at: new Date(NOW).toISOString(),
    runtime: { offline: false },
    work_request_details: [
      {
        work_request: {
          id: 'wr-pr', title: 'Native job tab', repo: 'owner/web', phase: 'active', base_branch: 'main',
          inserted_at: at(3000), worked_on: ARCHITECT, dispatched_by: { kind: 'chief', domain: 'herdr' },
        },
        product_tree: { execution_graph: { effective_edges: [
          { prerequisite_work_package_id: 'wp-done', dependent_work_package_id: 'wp-build' },
          { prerequisite_work_package_id: 'wp-build', dependent_work_package_id: 'wp-queued' },
          { prerequisite_work_package_id: 'wp-review', dependent_work_package_id: 'wp-queued' },
        ] } },
        asks: [ask('q1', 'Which order should the levels land in?', ARCHITECT.address, 50)],
        work_packages: [
          pkg('wp-queued', 'Factory level', 4, 'planned', { dependency_signal: { unmet_work_package_ids: ['wp-build'] } }),
          pkg('wp-build', 'Stage board', 2, 'dispatched', going('implementing', 90, {
            dispatched_by: { kind: 'chief', domain: 'Herdr' }, worker_terminal: worker('box/t8'),
          })),
          pkg('wp-review', 'Review lens', 3, 'dispatched', going('review_ci', 40, {
            pr_signal: pr('owner/web', 812, 'passing'), worker_terminal: worker('box/t9'),
            review_signal: review('fast', 'running', 3, {
              provider_status: 'decision-pending', started_at: at(200), round_started_at: at(40), observed_at: at(2), observation_state: 'current',
              steps: [{ index: 0, name: 'arena-base-review', state: 'done' }, { index: 1, name: 'base-signoff', state: 'current' }],
              round_history: [
                { number: 1, lane: 'review_t1', step: 'arena-base-review', status: 'decided', started_at: at(200), finished_at: at(150), outcome: 'findings', findings: 4 },
                { number: 2, lane: 'review-followup', step: null, status: 'decided', started_at: at(120), finished_at: at(60), outcome: 'findings', findings: 2 },
                { number: 3, lane: 'review_t1', step: 'base-signoff', status: 'decision-pending', started_at: at(40), finished_at: null, outcome: null, findings: null },
              ],
            }),
          })),
          // Landed a day before the rest started: a long stretch nobody acted in.
          pkg('wp-done', 'Module split', 1, 'ended', ended('pr_merged', 1800, {
            inserted_at: at(3000), dispatched_at: at(2900), pr_signal: pr('owner/web', 801, null, 'merged'), review_signal: review('fast', 'done', 1, { started_at: at(2000) }),
          })),
        ],
      },
      {
        work_request: { id: 'wr-nopr', title: 'Research spike', repo: 'owner/notes', phase: 'active', inserted_at: at(400), worked_on: term('box/t6', 'architect', 'live', 400) },
        work_packages: [
          pkg('np-1', 'Survey', 1, 'ended', ended('completed_no_pr', 200, { repo: 'owner/notes', dispatched_at: at(300) })),
          pkg('np-2', 'Write-up', 2, 'dispatched', going('implementing', 70, { repo: 'owner/notes', review_signal: review('none') })),
        ],
      },
      { work_request: { id: 'wr-shaping', title: 'New idea', repo: 'owner/web', phase: 'intake', inserted_at: at(30), worked_on: CHIEF } },
      {
        work_request: {
          id: 'wr-cross', title: 'Shared tokens', repo: 'owner/api', phase: 'active', inserted_at: at(1000), worked_on: term('vps/t2', 'architect', 'live', 900),
          operator_report: { brief: { text: 'Token API is building; the UI waits on it and on your call.', written_at: at(60) } },
        },
        product_tree: { execution_graph: { effective_edges: [{ prerequisite_work_package_id: 'x-api', dependent_work_package_id: 'x-web' }] } },
        asks: [ask('esc-1', 'Ship tokens before the API?', 'vps/t2', 240)],
        work_packages: [
          pkg('x-api', 'Token API', 1, 'dispatched', going('implementing', 120, { repo: 'owner/api', dispatched_by: { kind: 'chief', domain: 'Herdr' }, worker_terminal: worker('vps/t11') })),
          pkg('x-web', 'Token UI', 2, 'planned', { dependency_signal: { unmet_work_package_ids: ['x-api'] } }),
        ],
      },
    ],
  };
}

// Board variants for design previews; the default board above stays as the tests know it.
// "busy" adds tasks of every size and every v2 state: owners live, not answering and finished;
// packages launching, implementing, in review/CI and ready, and each ending; group paths nested two
// deep; a PR into another repository that only Finish closes; an unresolved and an archived task;
// decisions to review and undelivered feedback; and cards for small work. "quiet" is the busy board
// with nothing waiting on the person and nothing wrong. `repo_signal.has_ci` says whether the
// package's repository runs CI at all.
const CI = { 'owner/web': true, 'owner/api': true, 'owner/notes': false, 'upstream/core': true };
const reviewSteps = (current) => {
  const names = ['base-signoff', 'arena-deep-review', 'deep-signoff'];
  const step = current === null ? names.length : names.indexOf(current);
  return names.map((name, index) => ({ index, name, state: index < step ? 'done' : index === step ? 'current' : 'pending' }));
};

export function variantPayload(variant) {
  const board = boardPayload();
  if (variant !== 'busy' && variant !== 'quiet') return board;
  const quiet = variant === 'quiet';
  board.work_request_details.push(
    {
      work_request: { id: 'wr-restore', title: 'Restore sessions after a reboot', repo: 'owner/web', phase: 'active', inserted_at: at(2400), worked_on: term('box/t1q1', 'architect', 'live', 2300) },
      work_packages: [
        pkg('r-1', 'Session ledger', 1, 'ended', ended('pr_merged', 1500, { group: 'Core', repo: 'owner/api', pr_signal: pr('owner/api', 9, null, 'merged') })),
        pkg('r-2', 'Holder adoption', 2, 'ended', ended('pr_merged', 1200, { group: 'Core', repo: 'owner/api', pr_signal: pr('owner/api', 11, null, 'merged') })),
        pkg('r-3', 'Resume command table', 3, 'ended', ended('pr_merged', 700, { group: 'Core', pr_signal: pr('owner/web', 821, null, 'merged') })),
        pkg('r-4', 'Recovery toast', 4, 'dispatched', going('review_ci', 50, { group: 'Recovery', worker_terminal: worker('box/t3fa'), pr_signal: pr('owner/web', 830, 'passing'),
          review_signal: review('deep', 'running', quiet ? 1 : 3, { started_at: at(quiet ? 50 : 260), round_started_at: at(50), steps: reviewSteps('deep-signoff') }) })),
        pkg('r-5', 'Shell fallback', 5, 'dispatched', going('review_ci', 35, { group: 'Recovery / Shell', repo: 'owner/api', worker_terminal: worker('box/t3fb'),
          pr_signal: pr('owner/api', 14, quiet ? 'pending' : 'failing'), review_signal: review('normal', quiet ? 'running' : 'findings', 2) })),
        pkg('r-6', 'Remote cores', 6, 'dispatched', going('implementing', 25, { group: 'Recovery / Shell', repo: 'owner/api', worker_terminal: worker('box/t3fc') })),
        pkg('r-7', 'Settings toggle', 7, 'ready', going(null, 10, { group: 'Polish', worker_terminal: worker('box/t3fd'), pr_signal: pr('owner/web', 829, 'passing'), review_signal: review('fast', 'done') })),
        pkg('r-8', 'Docs and changelog', 8, 'planned', { group: 'Polish', repo: 'owner/notes', dependency_signal: { unmet_work_package_ids: ['r-4'] } }),
        pkg('r-9', 'Crash replay test', 9, 'planned', { group: 'Polish' }),
      ],
      decisions_to_review: quiet ? [] : [decision('dec-toast', 'wr-restore', 'The recovery toast stays until it is dismissed.',
        'A reboot can land while nobody is looking; a timed toast would be missed.', CHIEF.address, 55)],
    },
    {
      work_request: { id: 'wr-theme', title: 'Follow the system theme', repo: 'owner/web', phase: 'active', inserted_at: at(80), worked_on: term('box/t1q2', 'architect') },
      work_packages: [pkg('t-1', 'Theme listener', 1, 'dispatched', going('implementing', 40, { worker_terminal: worker('lap/t1x9', quiet ? 'live' : 'unknown') }))],
    },
    {
      work_request: { id: 'wr-status', title: 'Quieter status bar', repo: 'owner/web', phase: 'active', inserted_at: at(150), worked_on: term('box/t1q3', 'architect') },
      work_packages: [
        pkg('s-1', 'Status colours', 1, 'dispatched', going('review_ci', 30, { worker_terminal: worker('box/t5a'), pr_signal: pr('owner/web', 835, 'passing'),
          review_signal: review('fast', 'running', 2, { steps: reviewSteps(null), next_action: 'github_review' }) })),
        // Pushed during review: its checks run again.
        pkg('s-2', 'Bar layout', 2, 'dispatched', going('review_ci', 20, { worker_terminal: worker('box/t5b'), pr_signal: pr('owner/web', 836, 'pending'),
          review_signal: review('fast', 'running', 1, { steps: reviewSteps('base-signoff') }) })),
        // Dispatched, but no worker terminal has shown up yet.
        pkg('s-3', 'Status tooltip', 3, 'dispatched', going('launching', 5)),
      ],
    },
    {
      work_request: { id: 'wr-notes', title: 'Release notes template', repo: 'owner/notes', phase: 'active', inserted_at: at(100), worked_on: term('box/t1q4', 'architect') },
      work_packages: [pkg('n-1', 'Template', 1, 'dispatched', going('review_ci', 15, { repo: 'owner/notes', worker_terminal: worker('box/t5c'), pr_signal: pr('owner/notes', 21), review_signal: review('none') }))],
    },
    {
      work_request: { id: 'wr-upstream', title: 'Upstream: poll backoff', repo: 'owner/web', phase: 'active', inserted_at: at(3000), worked_on: term('lap/t2m4', 'architect', quiet ? 'live' : 'unknown') },
      work_packages: [
        pkg('u-1', 'Port backoff here', 1, 'ended', ended('pr_merged', 2000, { pr_signal: pr('owner/web', 802, null, 'merged') })),
        // Its PR is into another repository: nobody here can merge it, so Finish closes it.
        pkg('u-2', 'Back off on rate limits', 2, 'ready', going(null, 1500, { worker_terminal: worker('box/t7aa', 'finished'), pr_signal: pr('upstream/core', 97, 'passing'), review_signal: review('fast', 'done') })),
      ],
    },
    {
      work_request: { id: 'wr-docs', title: 'Operator guide refresh', repo: 'owner/web', phase: quiet ? 'active' : 'planned', inserted_at: at(3000), worked_on: term('box/t1q5', 'architect', 'finished') },
      work_packages: quiet
        ? [pkg('d-1', 'Outline', 1, 'ended', ended('pr_merged', 900)), pkg('d-2', 'Screens', 2, 'ended', ended('pr_merged', 600)), pkg('d-3', 'Install chapter', 3, 'dispatched', going('implementing', 20)), pkg('d-4', 'Troubleshooting', 4, 'planned')]
        : [pkg('d-1', 'Outline', 1, 'ended', ended('pr_merged', 900)), pkg('d-2', 'Screens', 2, 'ended', ended('pr_merged', 400)), pkg('d-3', 'Install chapter', 3, 'planned'), pkg('d-4', 'Troubleshooting', 4, 'planned')],
    },
    {
      work_request: { id: 'wr-recap', title: 'Recap export', repo: 'owner/web', phase: 'unresolved', inserted_at: at(2000), worked_on: term('box/t8rc', 'architect', 'finished') },
      work_packages: [
        pkg('c-1', 'Recap PDF layout', 1, 'ended', ended('pr_merged', 600, { pr_signal: pr('owner/web', 1290, null, 'merged') })),
        pkg('c-2', 'XLSX export', 2, 'ended', ended('abandoned', 420)),
        pkg('c-3', 'Share link for recaps', 3, 'ended', ended('skipped', 400)),
      ],
      decisions_to_review: quiet ? [] : [decision('dec-share', 'wr-recap', 'Share links for recaps are skipped this round.', 'Agencies download and forward the PDF.', 'lap/t0nm', 410,
        { review_state: 'feedback', feedback: 'Keep share links on the list for Q1; two agencies asked.', undelivered_reason: 'terminal_finished' })],
    },
    {
      work_request: { id: 'wr-badges', title: 'Agent badges in the sidebar', repo: 'owner/web', phase: 'done', inserted_at: at(1400), worked_on: term('box/t9b', 'architect', 'finished') },
      work_packages: [pkg('b-1', 'Badge art', 1, 'ended', ended('pr_merged', 500)), pkg('b-2', 'Badge slot', 2, 'ended', ended('finished', 300, { pr_signal: pr('upstream/core', 88, 'passing') }))],
    },
    {
      work_request: { id: 'wr-keys', title: 'Keyboard map for every level', repo: 'owner/web', phase: 'planned', inserted_at: at(200), worked_on: term('box/t1q6', 'architect') },
      work_packages: [pkg('k-1', 'Key table', 1, 'planned'), pkg('k-2', 'Help overlay', 2, 'planned')],
    },
    {
      work_request: { id: 'wr-old', title: 'Playback retry', repo: 'owner/web', phase: 'archived', inserted_at: at(9 * 1440) },
      work_packages: [pkg('o-1', 'Retry signed URLs', 1, 'ended', ended('pr_merged', 9 * 1440))],
    },
  );
  const [pr0, , , cross] = board.work_request_details;
  if (quiet) {
    pr0.asks = [];
    cross.asks = [];
    const lens = pr0.work_packages.find((p) => p.id === 'wp-review');
    lens.review_signal = { ...lens.review_signal, round: 1, started_at: at(40), round_history: [] };
  } else {
    pr0.asks[0].decision_prompt = {
      tl_dr: 'The factory level waits on both. Which lands first?', details: 'Stage board is building; Review lens is in its third review round.',
      options: [
        { id: 'board_first', label: 'Stage board first', recommended: true, pros: ['It is closer to its PR'], cons: ['Review lens waits a day'] },
        { id: 'lens_first', label: 'Review lens first', pros: ['Its review is nearly done'], cons: ['The board keeps the old stage names longer'] },
      ],
      custom_redirect_label: 'Another order',
    };
    pr0.decisions_to_review = [decision('dec-order', 'wr-pr', 'Landed packages fold under the strip instead of listing.',
      'Long tasks pushed the work at hand below the fold.', ARCHITECT.address, 140)];
  }
  for (const detail of board.work_request_details) {
    for (const p of detail.work_packages ?? []) p.repo_signal = { has_ci: CI[p.repo] };
  }
  board.cards = [
    card('card-flicker', 'Fix panel flicker on resize', 'owner/web', 'fix/panel-flicker', term('box/t4aa', 'card'), 'working', 34,
      { asks: quiet ? [] : [{ id: 'ask-flicker', card_id: 'card-flicker', question: 'OK to drop the resize workaround for Windows 10?', state: 'open', asked_by: 'box/t4aa', asked_at: at(9) }] }),
    card('card-tokens', 'Dark theme tokens for the panel', 'owner/web', 'feat/panel-tokens', term('box/t4ab', 'card'), 'review_ci', 12,
      { pr: cardPr('owner/web', 207, 'passing'), review: { id: 'rvw_tokens', state: 'pending', status: 'in_progress' } }),
    card('card-ocr', 'OCR confidence threshold', 'owner/api', 'feat/ocr-threshold', term('lap/t2pp', 'card', quiet ? 'live' : 'unknown'), 'review_ci', 80,
      { pr: cardPr('owner/api', 322, quiet ? 'pending' : 'failing'), review: { id: 'rvw_ocr', state: 'pending', status: quiet ? 'in_progress' : 'failed' } }),
    card('card-logs', 'Rotate bridge logs', 'owner/api', 'fix/bridge-log-rotation', term('box/t4ac', 'card', 'finished'), 'merged', 190,
      { pr: cardPr('owner/api', 846, 'passing', 'merged'), review: { id: 'rvw_logs', state: 'done', status: 'passed' } }),
    card('card-typos', 'Search typo tolerance', 'owner/web', 'spike/search-typos', term('lap/t6vx', 'card', 'finished'), 'done', 300),
  ];
  return board;
}

// A card as the board lists it: the terminal's work, its branch and PR, and its open asks.
function card(id, title, repository, branch, workedOn, state, minutes, extra = {}) {
  return { id, title, repository, base_branch: 'main', branch, worked_on: workedOn, state, stale: [], asks: [], since: at(minutes), ...extra };
}
const cardPr = (repository, number, ci, state = 'open') => ({ repository, number, url: `https://github.com/${repository}/pull/${number}`, state, draft: false, ci: { status: ci } });

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

// ---------- Demo actions ----------

// Plays one operator POST on a board payload in memory, as the factory would record it, so the
// preview can be clicked through. Returns the route's response body, or null for a route it doesn't
// know. Feedback reaches its terminal unless that terminal has finished (lap/t0nm in the sample).
const FINISHED = new Set(['lap/t0nm']);
export function applyDemo(payload, path, body = {}) {
  const now = new Date(Date.parse(payload.generated_at)).toISOString();
  const details = payload.work_request_details;
  const route = path.replace(/^.*\/api\/v1\/sympp\/herdr/, '').split('/').filter(Boolean).map(decodeURIComponent);
  const [kind, id, step] = route;
  const ok = (extra = {}) => ({ ok: true, ...extra });
  if (kind === 'asks' && step === 'answer') {
    for (const holder of [...details, ...(payload.cards ?? [])]) if (holder.asks) holder.asks = holder.asks.filter((a) => a.id !== id);
    return ok({ ask_id: id, delivery: { state: 'delivered' } });
  }
  if (kind === 'decisions') {
    const holder = details.find((d) => (d.decisions_to_review ?? []).some((x) => x.id === id));
    const d = holder?.decisions_to_review.find((x) => x.id === id);
    if (!d) return null;
    const drop = () => { holder.decisions_to_review = holder.decisions_to_review.filter((x) => x.id !== id); };
    if (step === 'ack') { d.review_state = 'acknowledged'; drop(); }
    else if (step === 'feedback') {
      const delivered = !FINISHED.has(d.recorded_by);
      withRoutes(Object.assign(d, { review_state: 'feedback', feedback: body.text, undelivered_reason: delivered ? null : 'terminal_finished' }));
      if (delivered) drop();
      return ok({ decision_id: id, review_state: 'feedback', delivery: delivered ? { state: 'delivered', to: d.recorded_by } : { state: 'not_delivered', reason: 'terminal_finished' } });
    } else if (step === 'dismiss') { d.undelivered_reason = null; drop(); }
    else return null;
    return ok({ decision_id: id, review_state: d.review_state });
  }
  if (kind === 'work-packages' && step === 'finish') {
    const p = details.flatMap((d) => d.work_packages ?? []).find((x) => x.id === id);
    if (!p) return null;
    Object.assign(p, { status: 'ended', progress: undefined, delivery: { outcome: 'finished', recorded_at: now } });
    return ok({ work_package_id: id, status: 'ended' });
  }
  if (kind === 'work-requests') {
    const r = details.find((d) => d.work_request.id === id)?.work_request;
    if (!r) return null;
    if (step === 'complete') Object.assign(r, { phase: 'done', completed_at: now });
    else if (step === 'archive') Object.assign(r, { phase: 'archived', prior_phase: r.phase });
    else if (step === 'restore') r.phase = r.prior_phase ?? 'done';
    else if (step === 'release') delete r.worked_on;
    else if (step === 'delete') payload.work_request_details = details.filter((d) => d.work_request.id !== id);
    else return null;
    return ok({ work_request_id: id });
  }
  if (kind === 'cards' && step === 'dismiss') {
    const c = (payload.cards ?? []).find((x) => x.id === id);
    if (!c) return null;
    c.state = 'dismissed';
    return ok({ card_id: id, state: 'dismissed' });
  }
  return null;
}
