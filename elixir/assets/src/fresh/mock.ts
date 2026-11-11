// The demo ledger: invented work shaped like the owner's real repositories and chief topics, in the backend's
// own payload, with every v2 state on it at least once. Operator actions change it in memory the way the
// backend would. It is the preview's data and the model's test fixture.
import type { Delivery } from "./delivery";
import type { Archived, AskEntry, CardEntry, DecisionEntry, Detail, Hydrated, Owned, Prompt, Request, Slice } from "./model";
import type { OperatorAction } from "./operator";

const MIN = 60e3;
const DAY = 24 * 60;

export type DemoLedger = { hydrated: Hydrated; archived: Archived };

type Liveness = "live" | "unknown" | "finished";
type Mode = "fast" | "normal" | "deep";
// Review Suite's status for the PR head: in_progress, failed (findings), inspection_needed, passed; pending before round one.
type Reviewed = [mode: Mode, status: string, round?: number];
type Worker = [address: string, liveness?: Liveness];
// One package. Times are minutes before now: `started` when it was dispatched, `since` when it reached its stage.
type Plan = {
  title: string;
  group?: string;
  progress?: "launching" | "implementing" | "worker_exited" | "review_ci" | "ready";
  started?: number;
  since?: number;
  outcome?: "pr_merged" | "finished" | "completed_no_pr" | "superseded" | "abandoned" | "skipped";
  ended?: number;
  pr?: [repo: string, number: number];
  ci?: "passing" | "pending" | "failing";
  review?: Reviewed;
  worker?: Worker;
  stale?: Array<"github" | "review">;
  // The sequence number of the package that took over.
  successor?: number;
};
type GoalPlan = { id: string; title: string; repo: string; phase: string; owner?: Owned; age?: number; completed?: number; brief?: [text: string, ago: number, eta?: string]; parked?: [text: string, ago: number]; plans: Plan[] };

const AREAS: Record<string, string[]> = {
  "JJLiebig/sympp": ["Herdr", "sympp"],
  "JJLiebig/herdr-core": ["Herdr", "herdr-core"],
  "nextidemedia/vod-kraken": ["Nextide-Kraken", "vod-kraken"],
  "nextidemedia/nextide-web": ["Nextide-Misc", "nextide-web"],
};
const SYMPP = "JJLiebig/sympp";
const HERDR_CORE = "JJLiebig/herdr-core";
const KRAKEN = "nextidemedia/vod-kraken";
const WEB = "nextidemedia/nextide-web";

const iso = (now: number, minutesAgo: number) => new Date(now - minutesAgo * MIN).toISOString();
const url = (repo: string, number: number) => `https://github.com/${repo}/pull/${number}`;
const architect = (address: string, liveness: Liveness = "live"): Owned => ({ address, role: "architect", liveness });
const chief = (address: string, domain: string): Owned => ({ address, role: "chief", domain, liveness: "live" });

function workerTerminal([address, liveness = "live"]: Worker) {
  return { address, state: liveness === "finished" ? "finished" : "live", status: liveness === "unknown" ? "unknown" : liveness === "finished" ? "finished" : "working" };
}

function prSignal(plan: Plan, now: number) {
  if (!plan.pr) return { status: "none" };
  const [repo, number] = plan.pr;
  const status = plan.outcome === "pr_merged" ? "merged" : plan.outcome && plan.outcome !== "finished" ? "closed" : "open";
  const opened = iso(now, plan.progress === "review_ci" ? (plan.since ?? 0) : (plan.started ?? plan.ended ?? 0) - 60);
  return { status, number, url: url(repo, number), repository: repo, created_at: opened, checks: plan.ci ? { status: plan.ci } : undefined };
}

function statusOf(plan: Plan) {
  if (plan.outcome) return "ended";
  if (!plan.progress) return "planned";
  return plan.progress === "ready" ? "ready" : "dispatched";
}

// How the package ended, or since when it has been ready.
function endingOf(goalId: string, plan: Plan, now: number): Pick<Slice, "delivery" | "board_state"> {
  const endedAt = iso(now, plan.ended ?? 0);
  if (plan.outcome) return { delivery: { outcome: plan.outcome, recorded_at: endedAt, pr_merged_at: plan.outcome === "pr_merged" ? endedAt : null, successor_work_package_id: plan.successor === undefined ? null : `${goalId}-${plan.successor}` }, board_state: { stage: "done", entered_at: endedAt, outcome: plan.outcome } };
  return { delivery: null, board_state: plan.progress === "ready" ? { stage: "merge", entered_at: iso(now, plan.since ?? 0) } : null };
}

function slice(goal: GoalPlan, seq: number, plan: Plan, now: number): Slice {
  const id = `${goal.id}-${seq}`;
  const status = statusOf(plan);
  return {
    id,
    work_package_id: id,
    title: plan.title,
    sequence: seq,
    status,
    group: plan.group ?? null,
    inserted_at: iso(now, 3 * DAY),
    dispatched_at: plan.started === undefined ? null : iso(now, plan.started),
    progress: status === "dispatched" ? plan.progress : null,
    worker_terminal: plan.worker ? workerTerminal(plan.worker) : null,
    observation_stale: plan.stale ?? [],
    ...endingOf(goal.id, plan, now),
    pr_signal: prSignal(plan, now),
    review_signal: plan.review ? { mode: plan.review[0], status: plan.review[1], round: plan.review[2] ?? 1 } : null,
  };
}

function detail(goal: GoalPlan, now: number): Detail {
  const note = (text: string, ago: number) => ({ text, written_at: iso(now, ago) });
  const report = goal.brief || goal.parked ? { brief: goal.brief ? note(goal.brief[0], goal.brief[1]) : null, eta: goal.brief?.[2] ? note(goal.brief[2], goal.brief[1]) : null, parking: goal.parked ? { reason: goal.parked[0], parked_at: iso(now, goal.parked[1]), resumed_at: null } : null } : null;
  const request: Request = {
    id: goal.id,
    title: goal.title,
    phase: goal.phase,
    repo: goal.repo,
    repo_display: goal.repo,
    base_branch: "main",
    inserted_at: iso(now, goal.age ?? 3 * DAY),
    completed_at: goal.completed === undefined ? null : iso(now, goal.completed),
    archived_at: null,
    worked_on: goal.owner ? { since: iso(now, (goal.age ?? 3 * DAY) - 5), ...goal.owner } : null,
    operator_report: report,
    area_path: AREAS[goal.repo],
  };
  return { work_request: request, work_packages: goal.plans.map((plan, index) => slice(goal, index + 1, plan, now)), asks: [], decisions_to_review: [] };
}

const HERDR = chief("jjdev/t0hd", "Herdr");
const NEXTIDE_KRAKEN = chief("jjdesktop/t0kr", "Nextide-Kraken");

const GOALS: GoalPlan[] = [
  {
    id: "wr-owner", title: "sympp v2: worked-on-by ownership", repo: SYMPP, phase: "active", owner: architect("jjdev/t1q1"),
    brief: ["Ledger acquisition is merged and takeover is green. The bridge heartbeat is on its second normal review round; labels are being wired now.", 22, "Backend done tonight; board slice tomorrow"],
    plans: [
      { title: "sympp_worked_on table and atomic acquisition", group: "Backend / Ledger", outcome: "pr_merged", started: 600, ended: 310, pr: [SYMPP, 848], ci: "passing" },
      { title: "Takeover when the owner has finished", group: "Backend / Ledger", progress: "ready", started: 260, since: 18, pr: [SYMPP, 851], ci: "passing", review: ["fast", "passed"], worker: ["jjdev/t3fa"] },
      { title: "Bridge heartbeat and clean detach", group: "Backend / Bridge", progress: "review_ci", started: 190, since: 52, pr: [SYMPP, 853], ci: "pending", review: ["normal", "in_progress", 2], worker: ["jjdev/t3fb"], stale: ["review"] },
      { title: "Forward Herdr labels in _meta", group: "Backend / Bridge", progress: "implementing", started: 41, worker: ["jjdev/t3fc"] },
      { title: "Release route for unknown owners", group: "Board", progress: "launching", started: 3 },
      { title: "Owner chip on WorkRequest rows", group: "Board" },
    ],
  },
  {
    id: "wr-alerts", title: "Kraken: alert routing for missed sponsor segments", repo: KRAKEN, phase: "active", owner: architect("jjdesktop/t2dq"),
    brief: ["Detection is done. Slack delivery is stuck on its third deep review round with a failing check, and the digest worker's laptop stopped answering.", 35],
    plans: [
      { title: "Missed-segment detector", group: "Backend / Detection", outcome: "pr_merged", started: 2000, ended: 1400, pr: [KRAKEN, 311], ci: "passing" },
      { title: "Backfill the last 30 days", group: "Backend / Detection", outcome: "pr_merged", started: 1300, ended: 980, pr: [KRAKEN, 314], ci: "passing" },
      { title: "Slack delivery with dedupe", group: "Backend / Delivery", progress: "review_ci", started: 300, since: 95, pr: [KRAKEN, 318], ci: "failing", review: ["deep", "failed", 3], worker: ["jjdesktop/t5k2"] },
      { title: "Daily email digest", group: "Backend / Delivery", progress: "implementing", started: 140, worker: ["jjlaptop/t1x9", "unknown"] },
      { title: "Creator time zones for digests", group: "Backend / Delivery", progress: "worker_exited", started: 220, worker: ["jjdesktop/t5k4", "finished"] },
      { title: "Alert list on the stream page", group: "Dashboard / Stream page" },
      { title: "Mute rules per creator", group: "Dashboard / Settings" },
    ],
  },
  {
    id: "wr-focus", title: "herdr-core: focus a terminal from panel actions", repo: HERDR_CORE, phase: "active", owner: architect("jjlaptop/t2m4", "unknown"),
    plans: [
      { title: "hc send --no-submit", outcome: "pr_merged", started: 1100, ended: 700, pr: [HERDR_CORE, 204], ci: "passing" },
      { title: "Panel focus API", progress: "ready", started: 900, since: 240, pr: ["herdrdev/herdr-app", 212], ci: "passing", worker: ["jjdev/t6ab", "finished"] },
      { title: "Focus action in the sympp mod", progress: "implementing", started: 75, worker: ["jjdev/t6ac"] },
    ],
  },
  {
    id: "wr-backoff", title: "Upstream: tracker poll backoff for Symphony", repo: SYMPP, phase: "active",
    plans: [
      { title: "Port backoff into sympp", outcome: "pr_merged", started: 2600, ended: 2000, pr: [SYMPP, 802], ci: "passing" },
      { title: "Back off on Linear rate limits", progress: "ready", started: 3000, since: 1500, pr: ["openai/symphony", 97], ci: "passing", review: ["fast", "passed"], worker: ["jjdesktop/t7aa", "finished"] },
    ],
  },
  {
    id: "wr-ci-audit", title: "CI: workflow audit across repositories", repo: SYMPP, phase: "active", owner: architect("jjdev/t1q7"),
    brief: ["Opus inventoried25repos/115workflowfiles/221jobdefinitions and grouped them by runner, cache and secret use; 14 jobs still pin actions by tag. Report /tmp/ci-audit/2026-11-09/report.txt lists each job with its repo, file and line so the pinning slice can start from it.", 64, "Audit delivered."],
    plans: [
      { title: "Inventory workflows and jobs", outcome: "pr_merged", started: 900, ended: 300, pr: [SYMPP, 861], ci: "passing" },
      { title: "Pin third-party actions by SHA", progress: "implementing", started: 60, worker: ["jjdev/t3fd"] },
      { title: "Share one cache key scheme" },
    ],
  },
  {
    id: "wr-recap", title: "Nextide web: sponsored-stream recap export", repo: WEB, phase: "unresolved",
    plans: [
      { title: "Recap PDF layout", outcome: "pr_merged", started: 900, ended: 600, pr: [WEB, 1290], ci: "passing" },
      { title: "XLSX export", outcome: "abandoned", started: 700, ended: 420 },
      { title: "Share link for recaps", outcome: "skipped", ended: 400 },
    ],
  },
  { id: "wr-language", title: "Kraken: creator language detection v2", repo: KRAKEN, phase: "intake", owner: NEXTIDE_KRAKEN, age: 50, plans: [] },
  { id: "wr-failed-calls", title: "sympp: durable failed-call counts", repo: SYMPP, phase: "planned", owner: architect("jjdev/t1q1"), age: 2 * DAY, plans: [{ title: "sympp_failed_calls table" }, { title: "Summarize failed calls from the table" }] },
  {
    id: "wr-restore", title: "herdr-core: restore sessions after a reboot", repo: HERDR_CORE, phase: "done", completed: 185,
    brief: ["Sessions come back after a reboot. The session-file fix waits upstream; it was finished here.", 180],
    plans: [
      { title: "Persist pane layout on exit", outcome: "pr_merged", started: 700, ended: 400, pr: [HERDR_CORE, 190], ci: "passing" },
      { title: "Restore layout on start", outcome: "pr_merged", started: 500, ended: 260, pr: [HERDR_CORE, 193], ci: "passing" },
      { title: "Crash-safe session file write", outcome: "finished", started: 450, ended: 200, pr: ["herdrdev/herdr-app", 198], ci: "passing" },
      { title: "Check restore on Windows", outcome: "completed_no_pr", started: 300, ended: 190 },
      { title: "Reattach agents (first take)", outcome: "superseded", started: 600, ended: 300, successor: 6 },
      { title: "Reattach agents", outcome: "pr_merged", started: 290, ended: 185, pr: [HERDR_CORE, 196], ci: "passing" },
    ],
  },
  {
    id: "wr-qr", title: "Nextide web: QR codes for campaign links", repo: WEB, phase: "done", completed: 5 * DAY - 30,
    plans: [
      { title: "QR generator endpoint", outcome: "pr_merged", started: 5 * DAY + 200, ended: 5 * DAY, pr: [WEB, 1244], ci: "passing" },
      { title: "Download button on campaign links", outcome: "pr_merged", started: 5 * DAY + 100, ended: 5 * DAY - 30, pr: [WEB, 1246], ci: "passing" },
    ],
  },
  {
    id: "wr-roster", title: "Nextide web: roster import from CSV", repo: WEB, phase: "planned", parked: ["Waiting for the agency's final column list.", 2 * DAY],
    plans: [{ title: "CSV parser and column mapping", outcome: "pr_merged", started: 3 * DAY + 300, ended: 3 * DAY, pr: [WEB, 1260], ci: "passing" }, { title: "Import preview" }],
  },
];

type CardPlan = { title: string; repo: string; branch: string; address: string; liveness?: Liveness; state: "working" | "review_ci" | "merged" | "done"; since: number; pr?: number; ci?: "passing" | "pending" | "failing"; review?: [state: string, status: string] };

const CARDS: CardPlan[] = [
  { title: "Fix panel flicker on resize", repo: HERDR_CORE, branch: "fix/panel-flicker", address: "jjdev/t4aa", state: "working", since: 34 },
  { title: "Dark theme tokens for the panel", repo: HERDR_CORE, branch: "feat/panel-tokens", address: "jjdev/t4ab", state: "review_ci", since: 12, pr: 207, ci: "passing", review: ["pending", "in_progress"] },
  { title: "Rotate bridge logs", repo: SYMPP, branch: "fix/bridge-log-rotation", address: "jjdev/t4ac", liveness: "finished", state: "merged", since: 190, pr: 846, ci: "passing", review: ["done", "passed"] },
  { title: "Parse Twitch VOD ids from share links", repo: WEB, branch: "fix/twitch-vod-ids", address: "jjdesktop/t6vv", state: "working", since: 58 },
  { title: "Campaign CSV export column order", repo: WEB, branch: "fix/csv-columns", address: "jjdesktop/t6vw", liveness: "finished", state: "merged", since: 20 * 60, pr: 1298, ci: "passing" },
  { title: "Creator search typo tolerance", repo: WEB, branch: "spike/search-typos", address: "jjlaptop/t6vx", liveness: "finished", state: "done", since: 5 * 60 },
  { title: "OCR confidence threshold for overlays", repo: KRAKEN, branch: "feat/ocr-threshold", address: "jjlaptop/t2pp", liveness: "unknown", state: "review_ci", since: 80, pr: 322, ci: "failing", review: ["pending", "failed"] },
  { title: "Empty state for the stream dashboard", repo: KRAKEN, branch: "feat/dashboard-empty", address: "jjdesktop/t2pq", liveness: "finished", state: "merged", since: 2 * DAY, pr: 319, ci: "passing", review: ["done", "passed"] },
];

const cardId = (address: string) => `card-${address.replace("/", "-")}`;

function card(plan: CardPlan, now: number): CardEntry {
  const ended = plan.state === "merged" || plan.state === "done";
  return {
    id: cardId(plan.address),
    state: plan.state,
    title: plan.title,
    worked_on: { address: plan.address, role: "card", liveness: plan.liveness ?? "live" },
    repository: plan.repo,
    branch: plan.branch,
    pr: plan.pr ? { repository: plan.repo, number: plan.pr, url: url(plan.repo, plan.pr), state: plan.state === "merged" ? "merged" : "open", ci: plan.ci ? { status: plan.ci } : null } : null,
    review: plan.review ? { state: plan.review[0], status: plan.review[1] } : null,
    stale: [],
    asks: [],
    since: iso(now, ended ? plan.since + 120 : plan.since),
    ended_at: ended ? iso(now, plan.since) : null,
  };
}

const RELEASE_PROMPT: Prompt = {
  details: "Its workers may still be running on that machine; the factory just can't see them.",
  custom_redirect_label: "Neither: tell the architect what to do instead",
  options: [
    { id: "owner-only", label: "Release only the owner", answer: "Release only the owner.", pros: ["Nothing that is still running is touched", "Matches how Release reads on the board"], cons: ["Workers keep a dead owner until each is released"] },
    { id: "owner-and-workers", label: "Release the owner and its workers", answer: "Release the owner and its workers.", pros: ["One click cleans up a crashed machine"], cons: ["Can take packages away from workers that are fine but unseen"] },
  ],
};

function asks(now: number): Array<AskEntry & { work_request_id?: string | null }> {
  const ask = (id: string, question: string, ago: number, by: string, subject: Partial<AskEntry>, prompt: Prompt | null = null): AskEntry => ({ id, question, decision_prompt: prompt, state: "open", asked_by: by, asked_at: iso(now, ago), work_package_id: null, ...subject });
  return [
    ask("ask-release", "When you release an owner whose machine stopped answering, should its workers be released too?", 25, "jjdev/t1q1", { work_request_id: "wr-owner" }, RELEASE_PROMPT),
    ask("ask-slack", "The Slack alerts bot has no workspace credential on the factory. Can you add it to the Kraken secrets store?", 70, "jjdesktop/t2dq", { work_request_id: "wr-alerts", work_package_id: "wr-alerts-3" }),
    ask("ask-vod", "OK to drop the old /videos/v… share links? They stopped resolving on Twitch in 2024.", 9, "jjdesktop/t6vv", { card_id: cardId("jjdesktop/t6vv") }),
  ];
}

function decisions(now: number): DecisionEntry[] {
  const decision = (id: string, goal: string, text: string, rationale: string, by: string, ago: number): DecisionEntry => ({ id, work_request_id: goal, decision: text, rationale, recorded_by: by, created_at: iso(now, ago), review_state: "recorded", feedback: null, undelivered_reason: null });
  return [
    decision("dec-alerts-scope", "wr-alerts", "Alerts fire only for streams with a signed sponsor contract.", "Prospect streams have no segment schedule to compare against, so every one would alert.", NEXTIDE_KRAKEN.address!, 140),
    decision("dec-cards", "wr-owner", "A card appears once a chief's child terminal has a branch or a PR.", "Reviewers and explorers never open branches, so they stay off the board without a special case.", HERDR.address!, 55),
    decision("dec-recap-pdf", "wr-recap", "Recaps ship as PDF only; the XLSX export is dropped.", "Finance reads the PDF; nobody opened the XLSX in the pilot.", "jjlaptop/t0nm", 430),
    { ...decision("dec-recap-share", "wr-recap", "Share links for recaps are skipped this round.", "Agencies download and forward the PDF.", "jjlaptop/t0nm", 410), review_state: "feedback", feedback: "Keep share links on the list for Q1; two agencies asked.", undelivered_reason: "terminal_finished" },
  ];
}

// Terminals that finished, so feedback typed for them is not delivered.
const GONE = new Set(["jjlaptop/t0nm"]);

// `quiet` is the board when nobody needs the operator; `empty` is a board with nothing on it.
export type DemoVariant = "busy" | "quiet" | "empty";

export function demoLedger(now: number, variant: DemoVariant = "busy"): DemoLedger {
  if (variant === "empty") return { hydrated: { generated_at: new Date(now).toISOString(), settings: {}, work_request_details: [], cards: [] }, archived: { archived_work_requests: { work_requests: [] } } };
  const details = GOALS.map((goal) => detail(goal, now));
  const cards = CARDS.map((plan) => card(plan, now));
  if (variant === "busy") {
    for (const entry of asks(now)) {
      const target = entry.card_id ? cards.find((item) => item.id === entry.card_id)?.asks : details.find((item) => item.work_request.id === entry.work_request_id)?.asks;
      target?.push(entry);
    }
    for (const entry of decisions(now)) details.find((item) => item.work_request.id === entry.work_request_id)?.decisions_to_review?.push(entry);
  }
  const vod: Request = { id: "wr-vod", title: "Kraken: VOD playback retry", phase: "archived", repo: KRAKEN, repo_display: KRAKEN, base_branch: "main", inserted_at: iso(now, 12 * DAY), completed_at: iso(now, 9 * DAY), archived_at: iso(now, 6 * DAY), area_path: AREAS[KRAKEN] };
  return { hydrated: { generated_at: new Date(now).toISOString(), settings: {}, work_request_details: details, cards }, archived: { archived_work_requests: { work_requests: [vod] } } };
}

// What became of an answer once the demo typed it: the alerts worker's terminal stopped mid-send, the rest arrived.
export function demoDelivery(askId: string): Delivery {
  return askId === "ask-slack" ? { state: "not_delivered", reason: "delivery_interrupted" } : { state: "delivered" };
}

// The demo answers an action the way the backend would, on a copy of the ledger.
export function applyDemo(ledger: DemoLedger, action: OperatorAction, now: number): DemoLedger {
  const next = structuredClone(ledger);
  const details = next.hydrated.work_request_details ?? [];
  const cards = next.hydrated.cards ?? [];
  const allAsks = [...details.flatMap((item) => item.asks ?? []), ...cards.flatMap((item) => item.asks ?? [])];
  const stamp = new Date(now).toISOString();

  switch (action.kind) {
    case "answer":
      allAsks.filter((entry) => entry.id === action.askId).forEach((entry) => (entry.state = "answered"));
      break;
    case "ack":
    case "dismiss_feedback":
    case "feedback":
      review(details, action);
      break;
    case "finish":
      finish(details, action.pkgId, stamp);
      allAsks.filter((entry) => entry.work_package_id === action.pkgId).forEach((entry) => (entry.state = "withdrawn"));
      break;
    case "dismiss":
      cards.filter((entry) => action.cardIds.includes(entry.id)).forEach((entry) => Object.assign(entry, { state: "dismissed", ended_at: entry.ended_at ?? stamp }));
      break;
    case "release":
      details.filter((item) => item.work_request.id === action.goalId).forEach((item) => (item.work_request.worked_on = null));
      break;
    case "goal":
      moveGoal(next, action.goalId, action.step, stamp);
      break;
    case "archive":
      action.goalIds.forEach((goalId) => moveGoal(next, goalId, "archive", stamp));
      break;
  }
  return next;
}

// A reviewed decision leaves the list, unless its feedback could not reach a terminal that has finished.
function review(details: Detail[], action: Extract<OperatorAction, { decisionId: string }>) {
  const decision = details.flatMap((item) => item.decisions_to_review ?? []).find((entry) => entry.id === action.decisionId);
  if (action.kind === "feedback" && decision && GONE.has(decision.recorded_by ?? "")) {
    Object.assign(decision, { review_state: "feedback", feedback: action.text, undelivered_reason: "terminal_finished" });
    return;
  }
  details.forEach((item) => (item.decisions_to_review = (item.decisions_to_review ?? []).filter((entry) => entry.id !== action.decisionId)));
}

function finish(details: Detail[], pkgId: string, stamp: string) {
  for (const pkg of details.flatMap((item) => item.work_packages ?? []).filter((entry) => entry.id === pkgId)) {
    Object.assign(pkg, { status: "ended", progress: null, delivery: { outcome: "finished", recorded_at: stamp }, board_state: { stage: "done", entered_at: stamp, outcome: "finished" } });
  }
}

// Deleting removes a goal wherever it is; restoring puts an archived one back on the board.
function unshelve(ledger: DemoLedger, goalId: string, restore: boolean) {
  const shelf = ledger.archived.archived_work_requests?.work_requests ?? [];
  const restored = restore ? shelf.find((entry) => entry.id === goalId) : undefined;
  const details = (ledger.hydrated.work_request_details ?? []).filter((item) => item.work_request.id !== goalId);
  if (restored) details.push({ work_request: { ...restored, phase: restored.completed_at ? "done" : "intake", archived_at: null }, work_packages: [], asks: [], decisions_to_review: [] });
  ledger.hydrated.work_request_details = details;
  ledger.archived.archived_work_requests = { work_requests: shelf.filter((request) => request.id !== goalId) };
}

// Completing or archiving withdraws the goal's asks; archiving takes it off the board onto the archived list.
function moveGoal(ledger: DemoLedger, goalId: string, step: "complete" | "archive" | "restore" | "delete", stamp: string) {
  if (step === "delete" || step === "restore") return unshelve(ledger, goalId, step === "restore");
  const hydrated = ledger.hydrated;
  const shelf = ledger.archived.archived_work_requests?.work_requests ?? [];
  const found = (hydrated.work_request_details ?? []).find((item) => item.work_request.id === goalId);
  if (!found) return;
  found.asks = (found.asks ?? []).map((entry) => ({ ...entry, state: "withdrawn" }));
  if (step === "complete") {
    Object.assign(found.work_request, { phase: "done", completed_at: stamp, operator_completed_at: stamp });
    return;
  }
  hydrated.work_request_details = (hydrated.work_request_details ?? []).filter((item) => item.work_request.id !== goalId);
  ledger.archived.archived_work_requests = { work_requests: [{ ...found.work_request, phase: "archived", archived_at: stamp, worked_on: null }, ...shelf] };
}
