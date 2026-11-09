// Pure sympp Lens model: the native hydrated board in, plain view data out. No GPUI, no Herdr imports,
// so every transformation here can be asserted on its own. Semantics follow the standalone board
// (elixir/assets/src/fresh/model.ts, report.tsx, board.tsx); nothing here is a second ledger.

export const BOARD_PATH = "/api/v1/sympp/herdr/dashboard";
export const DASHBOARD_PATH = "/sympp";
// v2 package progress, derived by the factory: a stored status (planned, dispatched, ready, ended)
// and, while dispatched, the step its signals show. One stage key per step.
export const STAGES = ["planned", "launching", "implementing", "review_ci", "ready", "ended"];
export const LIVE_STAGES = ["launching", "implementing", "review_ci", "ready"];
export const STAGE_LABEL = { planned: "Planned", launching: "Launching", implementing: "Implementing", review_ci: "Review/CI", ready: "Ready", ended: "Ended" };
// How a package ended, in words, and what that means for the task: merged and finished count as
// delivered, the rest as dropped.
export const ENDING_LABEL = { pr_merged: "Merged", finished: "Finished", completed_no_pr: "Completed", superseded: "Superseded", abandoned: "Abandoned", skipped: "Skipped" };
export const PHASE_LABEL = { intake: "Intake", planned: "Planned", active: "Active", unresolved: "Unresolved", done: "Done", archived: "Archived" };

const MINUTE = 60e3;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const LONG_REVIEW = 3 * HOUR;
const DORMANT_AFTER = 14 * DAY;
const RANK = { needs_you: 0, on_track: 3, idle: 4, parked: 5, settled: 6 };
const OUTCOMES = { pr_merged: "merged", completed_no_pr: "finished", finished: "finished", superseded: "dropped", abandoned: "dropped", skipped: "dropped" };
// Migrated endings keep the old terminal status they were recorded with.
const LEGACY_ENDINGS = { merged: "pr_merged", closed: "completed_no_pr", abandoned: "abandoned" };
const endingOf = (delivery) => (delivery?.outcome === "legacy" ? LEGACY_ENDINGS[delivery.legacy_status] : OUTCOMES[delivery?.outcome ?? ""] ? delivery.outcome : null) ?? null;
const LIVENESS = new Set(["live", "unknown", "finished"]);

// Polling: modest, slower in the background and after failures. GPUI fetch has no streaming body.
export const POLL = { live: 15e3, quiet: 60e3, background: 60e3, retry: [15e3, 30e3, 60e3] };

// ---------- Endpoint ----------

export function normalizeEndpoint(value) {
  if (typeof value !== "string" || !value.trim()) return null;
  const base = value.trim().replace(/\/+$/, "");
  return /^https?:\/\/(?:\[[0-9a-f:.]+\]|[a-z0-9._-]+)(?::[0-9]{1,5})?$/i.test(base) ? base : null;
}

export function boardUrl(endpoint) {
  return endpoint ? `${endpoint}${BOARD_PATH}` : null;
}

export function dashboardUrl(endpoint, explicit) {
  const match = typeof explicit === "string" ? explicit.trim().match(/^(https?:\/\/[^/?#\s]+)([/?#][^\s]*)?$/i) : null;
  return match && normalizeEndpoint(match[1]) ? match[0] : endpoint ? `${endpoint}${DASHBOARD_PATH}` : null;
}

// ---------- Fetch state ----------
// `data` is the last good read and survives failures; `error` says why the latest read failed.

export function initialFetch() {
  return { data: null, receivedAt: null, attemptAt: null, error: null, failures: 0 };
}

export function fetchStarted(state, now) {
  return { ...state, attemptAt: now };
}

export function fetchSucceeded(state, data, now) {
  return { data, receivedAt: now, attemptAt: now, error: null, failures: 0 };
}

export function fetchFailed(state, error, now) {
  return { ...state, attemptAt: now, error, failures: state.failures + 1 };
}

export function httpError(status) {
  if (status === 401 || status === 403) return `sympp refused this native read (${status}). Check the local sympp connection.`;
  if (status === 404) return "This sympp has no native board route (404). It needs the release with /herdr/dashboard.";
  if (status === 503) return "The sympp ledger is busy (503). Retrying.";
  return `sympp answered ${status}.`;
}

export function networkError(endpoint, caught) {
  const host = (normalizeEndpoint(endpoint) ?? "").replace(/^https?:\/\//i, "");
  return `Can't reach sympp at ${host || "the configured endpoint"}. Check the connection and retry.`;
}

export function nextDelay(state, active) {
  if (state.error) return POLL.retry[Math.min(state.failures - 1, POLL.retry.length - 1)] ?? POLL.retry[0];
  if (!active) return POLL.background;
  return state.data?.jobs.some((job) => job.state === "live" || job.needs.length > 0) ? POLL.live : POLL.quiet;
}

export function fetchDue(state, now, active) {
  if (state.attemptAt === null) return true;
  return now - state.attemptAt >= nextDelay(state, active);
}

// Shown data is stale once a read failed, or once it is much older than the schedule allows.
export function isStale(state, now) {
  if (!state.data) return false;
  return Boolean(state.error) || now - state.receivedAt > 3 * POLL.quiet;
}

/// ---------- Board ----------

export function parseBoard(payload) {
  if (!payload || typeof payload !== "object" || !Array.isArray(payload.work_request_details)) {
    throw new Error("sympp answered with something other than a board.");
  }
  const now = ms(payload.generated_at) ?? Date.now();
  const jobs = payload.work_request_details.filter((detail) => detail?.work_request?.id).map((detail) => buildJob(detail, now));
  return { now, jobs, cards: cardsOf(payload.cards, now), offline: typeof payload.runtime?.offline === "boolean" ? payload.runtime.offline : null,
    reposRoot: typeof payload.runtime?.repos_root === "string" && payload.runtime.repos_root ? payload.runtime.repos_root : null };
}

// Current domain chiefs: live terminals labelled sympp.role=chief with a sympp.domain, as Start chief
// labels them. Labels name a candidate, never authority or liveness; the terminal only picks which
// bound session to check.
export function chiefsOf(terminalList) {
  return (terminalList ?? []).filter((t) => t?.state === "live" && typeof t.address === "string" && t.address &&
    t.labels?.["sympp.role"] === "chief" && typeof t.labels["sympp.domain"] === "string" && t.labels["sympp.domain"].trim())
    .map((t) => {
      const domain = t.labels["sympp.domain"].trim();
      return { domain, key: domain.toLowerCase(), repos: [], terminal: t.address, location: null };
    });
}

// The chief domain a request or package was created or dispatched under, if any.
function chiefOf(by) {
  return by?.kind === "chief" && typeof by.domain === "string" && by.domain.trim() ? by.domain.trim() : null;
}

function buildJob(detail, now) {
  const request = detail.work_request;
  const repo = request.repo_display || request.repo || "";
  const repoShort = shortRepo(repo);
  const area = Array.isArray(request.area_path) && request.area_path.length ? request.area_path : ["Unfiled", repoShort || "Unknown"];
  const packages = (detail.work_packages ?? []).map((slice) => buildPackage(slice, repo, now)).sort((a, b) => a.seq - b.seq);
  // Phases are the first segment of each package's group path, in the order their packages are planned.
  const phases = [...new Set(packages.map((pkg) => pkg.phase).filter(Boolean))];
  const titles = new Map(packages.map((pkg) => [pkg.id, pkg.title]));
  for (const pkg of packages) pkg.after = pkg.unmet.map((id) => titles.get(id) ?? id);

  const report = reportOf(request.operator_report, now);
  const asks = asksOf(detail.asks, now).map((ask) => ({ ...ask, jobId: request.id }));
  const needs = asks.map((ask) => ({ key: ask.key, kind: "ask", label: "Needs you", text: ask.text, since: ask.since, jobId: request.id, pkgId: ask.pkgId, ask }));
  const live = packages.filter((pkg) => LIVE_STAGES.includes(pkg.stage));
  const done = packages.filter((pkg) => pkg.stage === "ended");
  const queued = packages.filter((pkg) => pkg.stage === "planned");
  const createdAt = ms(request.inserted_at) ?? now;
  const phase = PHASE_LABEL[request.phase] ? request.phase : packages.length ? "planned" : "intake";
  const settled = phase === "done" || phase === "archived";
  const job = {
    id: request.id,
    title: request.title || request.id,
    phase,
    repo,
    repoShort,
    repos: [...new Set([repo, ...packages.map((pkg) => pkg.repo)].filter(Boolean))],
    area,
    baseBranch: request.base_branch ?? null,
    offPrimary: offPrimary(request.base_branch, request.default_branch),
    createdAt,
    closedAt: ms(request.operator_completed_at) ?? ms(request.archived_at),
    report,
    asks,
    needs,
    decisions: decisionsOf(detail.decisions, now).map((d) => ({ ...d, jobId: request.id })),
    owner: workedOnOf(request.worked_on),
    dispatchedBy: chiefOf(request.dispatched_by),
    packages,
    // Prerequisite → dependent package pairs from the effective execution graph.
    edges: (detail.product_tree?.execution_graph?.effective_edges ?? [])
      .map((edge) => [edge?.prerequisite_work_package_id, edge?.dependent_work_package_id]).filter(([pre, dep]) => pre && dep),
    counts: { live: live.length, queued: queued.length, done: done.length, dropped: done.filter((pkg) => pkg.outcome === "dropped").length, total: packages.length },
    state: settled ? "settled" : live.length > 0 || needs.length > 0 || phase === "unresolved" ? "live" : "resting",
    lastMoveAt: Math.max(createdAt, ...packages.map((pkg) => pkg.since ?? 0)),
    deployFailed: deployFailed(request.deployments),
    phases,
  };
  job.verdict = verdictOf(job);
  job.lane = laneOf(job, now);
  job.brief = report.brief ? report.brief.text : draftBrief(job);
  return job;
}

// The terminal working on a task, package or card, as the factory last observed it: live, not
// answering (unknown) or finished. An address the panel can focus, never proof by itself.
function workedOnOf(owner) {
  if (typeof owner?.address !== "string" || !owner.address.trim()) return null;
  return { address: owner.address.trim(), role: typeof owner.role === "string" ? owner.role : null,
    liveness: LIVENESS.has(owner.liveness) ? owner.liveness : "unknown", since: ms(owner.since) };
}

// Open asks: the only source of Needs you. Each answers through its own operator route on this factory.
function asksOf(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((ask) => ask && (typeof ask.id === "string" || typeof ask.id === "number") && typeof ask.question === "string" && ask.question.trim())
    .map((ask) => ({
      key: `ask:${ask.id}`, id: String(ask.id), text: ask.question.trim(), prompt: promptOf(ask.decision_prompt),
      pkgId: ask.work_package_id ?? null, by: workedOnOf(ask.asked_by), since: ms(ask.asked_at), status: "open",
      route: `/api/v1/sympp/herdr/asks/${encodeURIComponent(String(ask.id))}/answer`,
    }));
}

function promptOf(prompt) {
  if (!prompt || typeof prompt !== "object" || !Array.isArray(prompt.options)) return null;
  const options = prompt.options.filter((o) => o?.id && o.label);
  return options.length ? { ...prompt, options } : null;
}

// Flagged decisions the person reviews: recorded ones wait for Ack or Feedback; feedback that never
// reached its terminal stays until dismissed. Acknowledged and delivered ones are done.
function decisionsOf(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((d) => d && (typeof d.id === "string" || typeof d.id === "number") && typeof d.decision === "string" && d.decision.trim())
    .map((d) => ({
      key: `decision:${d.id}`, id: String(d.id), text: d.decision.trim(), rationale: typeof d.rationale === "string" && d.rationale.trim() ? d.rationale.trim() : null,
      by: workedOnOf(d.recorded_by), at: ms(d.recorded_at), state: d.review_state ?? "recorded",
      feedback: typeof d.feedback === "string" ? d.feedback : null, undelivered: d.review_state === "feedback" && d.delivered === false && !d.dismissed_at,
    }))
    .filter((d) => d.state === "recorded" || d.undelivered);
}

// Small work outside any task: one card per eligible terminal with a branch or PR.
const CARD_STATES = new Set(["working", "review_ci", "merged", "done"]);
function cardsOf(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((c) => c?.id && typeof c.task === "string" && CARD_STATES.has(c.state)).map((c) => {
    const review = c.review_signal ?? {};
    const id = String(c.id);
    const asks = asksOf(c.asks).map((ask) => ({ ...ask, cardId: id }));
    return {
      id, task: c.task.trim(), repo: c.repo ?? null, repos: c.repo ? [c.repo] : [], branch: c.branch ?? null,
      owner: workedOnOf(c.worked_on), state: c.state, since: ms(c.since),
      pr: prOf(c.pr_signal ?? {}), review: { mode: review.mode ?? null, state: review.state ?? null, round: roundOf(review) },
      ci: typeof c.repo_signal?.has_ci === "boolean" ? c.repo_signal.has_ci : null,
      asks, needs: asks.map((ask) => ({ key: ask.key, kind: "ask", label: "Needs you", text: ask.text, since: ask.since, cardId: id, pkgId: null, ask })),
    };
  });
}

function prOf(pr) {
  const repo = pr.repository ?? (typeof pr.url === "string" ? pr.url.match(/github\.com\/([^/]+\/[^/]+)\/pull\//i)?.[1] : null) ?? null;
  return { status: pr.status ?? null, number: pr.number ?? null, url: pr.url ?? null, repo, checks: pr.checks?.status ?? null, checksAt: ms(pr.checks?.changed_at) };
}

// Review Suite counts rounds from zero before the first; older signals carry no count.
function roundOf(review) {
  return Number.isSafeInteger(Number(review.round)) && review.round !== null && review.round !== undefined && review.round !== "" ? Number(review.round) : 1;
}

const DISPATCHED = new Set(["launching", "implementing", "review_ci"]);
const repoKey = (repo) => String(repo).toLowerCase().replace(/\.git$/, "").split(/[\\/:]/).filter(Boolean).slice(-2).join("/");

function buildPackage(slice, jobRepo) {
  const pr = prOf(slice.pr_signal ?? {});
  const review = slice.review_signal ?? {};
  const ending = slice.status === "ended" || slice.delivery?.outcome ? endingOf(slice.delivery) ?? "abandoned" : null;
  const stage = ending ? "ended" : slice.status === "ready" ? "ready"
    : slice.status === "dispatched" ? (DISPATCHED.has(slice.progress?.stage) ? slice.progress.stage : "launching") : "planned";
  const since = stage === "ended" ? ms(slice.delivery?.recorded_at) : stage === "planned" ? null : ms(slice.progress?.since) ?? ms(slice.dispatched_at);
  const repo = slice.repo_display || slice.repo || jobRepo || null;
  const group = typeof slice.group === "string" ? slice.group.split("/").map((part) => part.trim()).filter(Boolean) : [];
  return {
    id: slice.work_package_id || slice.id,
    title: slice.title || slice.id,
    repo,
    seq: slice.sequence ?? 0,
    // The architect's group path ("Backend / Ledger"): its first segment is the package's phase.
    group,
    phase: group[0] ?? null,
    stage,
    ending,
    outcome: ending ? OUTCOMES[ending] : null,
    since: since ?? ms(slice.inserted_at),
    untimed: since === null,
    createdAt: ms(slice.inserted_at),
    dispatchedAt: ms(slice.dispatched_at),
    dispatchedBy: chiefOf(slice.dispatched_by),
    doneAt: stage === "ended" ? since : null,
    failed: pr.checks === "failing",
    // Whether the package's repository runs CI at all; null while the board doesn't say.
    ci: typeof slice.repo_signal?.has_ci === "boolean" ? slice.repo_signal.has_ci : null,
    round: roundOf(review),
    pr,
    // An open PR into a repository this factory doesn't merge into: only Finish ends it.
    finishable: LIVE_STAGES.includes(stage) && pr.status === "open" && Boolean(pr.repo && repo) && repoKey(pr.repo) !== repoKey(repo),
    owner: workedOnOf(slice.worked_on),
    review: {
      type: review.type ?? null,
      mode: review.mode ?? null,
      // Review Suite's state for the current head: running, findings, done or unknown.
      state: review.state ?? null,
      round: roundOf(review),
      status: review.status ?? null,
      providerStatus: review.provider_status ?? null,
      nextAction: review.next_action ?? null,
      step: review.step ?? null,
      current: review.current ?? null,
      total: review.total ?? null,
      steps: Array.isArray(review.steps) ? review.steps.filter((s) => s?.name).map((s) => ({ name: s.name, state: s.state ?? null })) : null,
      observation: review.observation_state ?? null,
      observedAt: ms(review.observed_at),
      startedAt: ms(review.started_at),
      roundStartedAt: ms(review.round_started_at),
      history: (Array.isArray(review.round_history) ? review.round_history : []).map((h) => ({
        n: Number(h?.number), lane: h?.lane ?? null, step: h?.step ?? null, status: h?.status ?? null,
        startedAt: ms(h?.started_at), finishedAt: ms(h?.finished_at),
        outcome: h?.outcome ?? null, findings: Number.isSafeInteger(h?.findings) ? h.findings : null,
      })).filter((h) => Number.isSafeInteger(h.n) && h.n > 0),
    },
    unmet: slice.dependency_signal?.unmet_work_package_ids ?? [],
    after: [],
  };
}

function reportOf(report, now) {
  const note = (text, at) => (text ? { text, at: ms(at) ?? now } : null);
  const parking = report?.parking && !report.parking.resumed_at ? report.parking : null;
  return {
    brief: note(report?.brief?.text, report?.brief?.written_at),
    eta: note(report?.eta?.text, report?.eta?.written_at),
    parked: note(parking?.reason, parking?.parked_at),
  };
}

function deployFailed(deployments) {
  return Object.values(deployments ?? {}).some((repo) => repo?.dev?.status === "failed" || repo?.prod?.status === "failed");
}

// A review in its third round or past three hours is a road bump. Its time runs from the recorded
// review start, else from when the package reached Review/CI.
export function reviewBumps(pkg, now) {
  if (pkg.stage !== "review_ci") return [];
  const from = pkg.review.startedAt ?? pkg.review.roundStartedAt ?? (pkg.untimed ? null : pkg.since);
  return [
    pkg.round >= 3 ? { kind: "rounds", text: `Review is on round ${pkg.round}` } : null,
    from !== null && now - from > LONG_REVIEW ? { kind: "long", text: `In review for ${span(now - from)}` } : null,
  ].filter(Boolean);
}

function verdictOf(job) {
  if (job.needs.length > 0) return "needs_you";
  if (job.report.parked) return "parked";
  if (job.state === "settled") return "settled";
  return job.counts.live === 0 ? "idle" : "on_track";
}

function laneOf(job, now) {
  if (job.phase === "archived") return "archived";
  if (job.report.parked && job.needs.length === 0 && job.state !== "settled") return "parked";
  if (job.needs.length > 0 || job.state === "live") return "moving";
  if (job.state === "settled") return job.deployFailed ? "moving" : now - job.lastMoveAt < DAY ? "landed" : "settled";
  if (job.counts.done === 0) return "backlog";
  return now - job.lastMoveAt < DORMANT_AFTER ? "moving" : "dormant";
}

function draftBrief(job) {
  const { live, queued, done, total } = job.counts;
  if (job.needs.length > 0) return `Waiting on you: ${job.needs[0].text}`;
  if (job.report.parked) return `Parked: ${job.report.parked.text}`;
  if (job.phase === "unresolved") return "Every package has ended, but not all of them landed.";
  if (job.state === "settled") {
    if (job.counts.dropped) return `${total - job.counts.dropped} of ${total} packages finished; ${job.counts.dropped} dropped.`;
    return total ? `All ${total} packages have landed.` : "Closed.";
  }
  if (total === 0) return "Not sliced into packages yet.";
  if (live === 0) return `Between packages: ${done} of ${total} landed, ${queued} up next.`;
  return `${live} of ${total} packages moving. ${done} landed.`;
}

// ---------- Board view ----------

// Lanes in reading order. Needs-you items are pulled out separately; their jobs still sit in "moving".
export function lanesOf(jobs) {
  const lanes = { moving: [], parked: [], backlog: [], landed: [], dormant: [], settled: [], archived: [] };
  for (const job of jobs) lanes[job.lane].push(job);
  lanes.moving.sort((a, b) => RANK[a.verdict] - RANK[b.verdict] || b.lastMoveAt - a.lastMoveAt);
  for (const key of ["parked", "backlog", "landed", "dormant", "settled", "archived"]) lanes[key].sort((a, b) => b.lastMoveAt - a.lastMoveAt);
  return lanes;
}

// How many tasks and cards need the person, and how many packages move.
export function verdictCounts(jobs, cards = []) {
  const counts = { needs: 0, moving: 0, planned: 0 };
  for (const item of [...jobs, ...cards]) {
    if (item.needs.length > 0) counts.needs += 1;
    counts.moving += item.counts?.live ?? 0;
    if (item.lane === "backlog") counts.planned += 1;
  }
  return counts;
}

// ---------- Terminal bindings ----------

// Another machine's agents are checked by the helper of the sympp skill setup installed there, with
// that machine's node. Its commands start in its home, on its core session.
export const INSTALLED_HELPER = { node: "node", helper: ".agents/skills/sympp/scripts/sympp-herdr.js" };

// Labels identify candidates, never proof. Only trusted host configuration, or the installed helper on
// another machine, chooses executable paths.
export function discoverBindings(hosts, terminalList) {
  return (terminalList ?? []).flatMap((terminal) => ["launch", "session"].flatMap(kind => {
    const labels = terminal.labels ?? {};
    const prefix = kind === "session" ? "sympp.session_" : "sympp.";
    const identityKey = kind === "session" ? "sympp.session_id" : "sympp.launch_id";
    const jobId = labels[`${prefix}work_request_id`] || null;
    const pkgId = labels[`${prefix}work_package_id`] || null;
    const role = labels[`${prefix}role`] || "agent";
    if (!labels[identityKey] || (!jobId && (kind !== "session" || (!pkgId && role !== "chief")))) return [];
    const address = terminal.address;
    if (typeof address !== "string" || !address) return [];
    const split = address.indexOf("/");
    const machine = split < 0 ? null : address.slice(0, split);
    const terminalId = split < 0 ? address : address.slice(split + 1);
    const host = hosts?.[machine ?? "local"] ?? (machine ? INSTALLED_HELPER : null);
    const pid = Number(labels[`${prefix}pid`]);
    const processId = kind === "session" ? Number(labels[`${prefix}process_id`]) : null;
    const receipt = labels[`${prefix}receipt`];
    const identity = typeof labels[`${prefix}core_id`] === "string" && Number.isSafeInteger(pid) && pid > 0 && pid === terminal.pid
      && (kind !== "session" || (Number.isSafeInteger(processId) && processId > 0));
    const absoluteReceipt = typeof receipt === "string" && /^(?:[A-Za-z]:[\\/]|\/|\\\\)/.test(receipt);
    const configured = typeof host?.node === "string" && Boolean(host.node) && typeof host?.helper === "string" && Boolean(host.helper);
    return [{
      kind, processId, jobId, pkgId,
      role, address, terminalId, machine,
      provider: { codex: "Codex", claude: "Claude", opencode: "OpenCode" }[labels["sympp.provider"]] || "Agent",
      status: typeof terminal.status === "string" ? terminal.status : terminal.status?.state ?? null,
      launchId: labels[identityKey], coreId: labels[`${prefix}core_id`], pid, receipt,
      host: configured ? host : null,
      available: configured && identity && absoluteReceipt && terminal.state === "live",
      unavailable: !configured ? "Agent helper unavailable" : "Agent is no longer running",
    }];
  }));
}

export function bindingsFor(bindings, jobId, pkgId) {
  return bindings.filter(b => b.pkgId === (pkgId ?? null) &&
    (b.jobId === jobId || (b.kind === "session" && b.jobId === null && b.pkgId !== null)))
    .filter((b, index, matches) => matches.findIndex(other => other.address === b.address && other.role === b.role) === index);
}

// A chief has no job of its own: its bindings are the chief sessions bound in its own terminal. They
// still need the helper check before anything says Live.
export function chiefBindings(bindings, chief) {
  if (!chief?.terminal) return [];
  return bindings.filter((b) => b.kind === "session" && b.role === "chief" && b.address === chief.terminal)
    .filter((b, index, matches) => matches.findIndex((other) => other.address === b.address) === index);
}

export function bindingCheckArgs(binding) {
  return [binding.host.helper, "check", "--receipt", binding.receipt,
    ...(binding.host.session ? ["--session", binding.host.session] : []), "--json"];
}

export function agentDestination(binding, paneList, spaceList) {
  const pane = paneList.find(p => p.terminal === binding.address);
  if (pane) return { pane: pane.pane };
  const sameMachine = space => (space.machine ?? null) === binding.machine;
  const space = spaceList.find(space => space.active && sameMachine(space)) || spaceList.find(sameMachine);
  if (!space) throw new Error("Open a space on the agent's machine, then try again.");
  return { space: space.id, alongside: space.active === true };
}

// Recheck after the asynchronous helper call: the terminal may have been replaced meanwhile.
export function checkedBinding(binding, result, terminalList) {
  if (!binding.available || result?.code !== 0) return false;
  let receipt;
  try { receipt = JSON.parse(result.stdout); } catch { return false; }
  if (binding.kind === "session" && (receipt.kind !== "session" || receipt.process_id !== binding.processId || receipt.role !== binding.role)) return false;
  if (receipt.state !== "live" || receipt.core_id !== binding.coreId || receipt.terminal_id !== binding.terminalId ||
      receipt.pid !== binding.pid || receipt.launch_id !== binding.launchId ||
      receipt.work_request_id !== binding.jobId || (receipt.work_package_id ?? null) !== binding.pkgId) return false;
  const current = discoverBindings({ [binding.machine ?? "local"]: binding.host }, terminalList)
    .find(b => b.address === binding.address && b.kind === binding.kind);
  return Boolean(current?.available && current.coreId === binding.coreId && current.launchId === binding.launchId &&
    current.pid === binding.pid && current.processId === binding.processId && current.role === binding.role &&
    current.receipt === binding.receipt && current.jobId === binding.jobId && current.pkgId === binding.pkgId);
}

export function span(value) {
  const minutes = Math.max(0, Math.round(value / MINUTE));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ${String(minutes % 60).padStart(2, "0")}m` : `${Math.round(hours / 24)}d`;
}

export function ago(at, now) {
  if (at === null || at === undefined) return null;
  const text = span(now - at);
  return text === "now" ? "just now" : `${text} ago`;
}

function sentence(code) {
  const text = String(code).replace(/_/g, " ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

export function shortRepo(repo) {
  return String(repo).replace(/[\\/]+$/, "").replace(/\.git$/i, "").split(/[\\/:]/).filter(Boolean).pop() ?? "";
}

function offPrimary(base, defaultBranch) {
  if (!base) return false;
  return defaultBranch ? base !== defaultBranch : !/^(main|master)$/.test(base);
}

function ms(value) {
  const time = Date.parse(value ?? "");
  return Number.isFinite(time) ? time : null;
}
