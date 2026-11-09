// Clean-slate model. A Goal is a WorkRequest; a Pkg is a WorkPackage with the stages it has moved through.
import { areaFor } from "./areas";

// A package's progress is derived from what its worker terminal, its PR, CI and Review Suite show.
export type Stage = "planned" | "launching" | "implementing" | "review_ci" | "ready" | "ended";
export type Outcome = "merged" | "finished" | "completed" | "superseded" | "abandoned" | "skipped";
export type ReviewMode = "fast" | "normal" | "deep" | "none";
// `state` is the Review Suite state for the PR's current head; null until a review has started.
export type Review = { mode: ReviewMode | null; state: "running" | "findings" | "done" | "unknown" | null; round: number };
export type Ci = "pending" | "passing" | "failing";
// "unknown" means the terminal's machine stopped answering without the agent saying it left.
export type Liveness = "live" | "unknown" | "finished";
export type Role = "chief" | "architect" | "worker" | "card";
// The terminal working on something, by its Herdr address such as `jjdev/t1q1`. Askers and deciders are known
// by address only, so their role and liveness are null.
export type Terminal = { address: string; role: Role | null; liveness: Liveness | null; topic?: string | null };
// `open` is false once the PR is merged or closed. A PR to another repository waits on its maintainers.
export type Pr = { number: number; url: string; repo: string; open: boolean };
// `untimed` marks a stage whose start nobody observed: `from` is then only the closest known time.
export type Seg = { stage: Stage; from: number; to: number; failed: boolean; untimed?: boolean };
export type HistoryEvent = { t: string; s?: string; y?: string; c?: string; m?: boolean; n?: number; u?: string; a?: string; r?: string; x?: string };
// What the factory could not read on its last look: GitHub, or the Review Suite host. Nothing moves on it until it can.
export type Stale = "github" | "review";

export type Pkg = {
  id: string;
  title: string;
  seq: number;
  // A path such as "Backend / Billing": the first part is the phase, the rest nests beneath it.
  group: string | null;
  goalTitle: string;
  goalRepo: string;
  area: string[];
  createdAt: number;
  segs: Seg[];
  endAt: number | null;
  outcome: Outcome | null;
  pr: Pr | null;
  ci: Ci | null;
  review: Review | null;
  owner: Terminal | null;
  // The worker terminal finished without opening a PR.
  exited: boolean;
  stale: Stale[];
};

// Something the architect wrote, and when.
export type Note = { text: string; at: number };
// The architect's own words about a goal. `parked` is set only while the goal is set aside.
export type ArchitectReport = { brief: Note | null; eta: Note | null; parked: Note | null };
// Where the result runs after the last merge: one step per environment whose deploy workflow is tagged.
// "waiting" means nothing has been deployed or started yet.
export type DeployStep = { env: "Dev" | "Prod"; state: "ok" | "failed" | "pending" | "waiting"; at: number | null };
export type Phase = "intake" | "planned" | "active" | "done" | "unresolved" | "archived";
// `phase` is the backend's reading of the goal when it was read. `completedAt` and `archivedAt` place it in time for a replay.
export type Goal = { id: string; title: string; area: string[]; repo: string; baseBranch: string | null; defaultBranch: string | null; createdAt: number; phase: Phase; completedAt: number | null; archivedAt: number | null; pkgs: Pkg[]; owner: Terminal | null; report?: ArchitectReport; deploy?: DeployStep[] };

// A question for the operator. Its subject is a goal (optionally one of its packages) or a card.
// With choices the answer is one of them; `redirect` names the extra choice of answering in free text instead.
export type Choice = { id: string; label: string; description: string | null; pros: string[]; cons: string[] };
export type Ask = { id: string; question: string; details: string | null; from: number; by: Terminal | null; goalId: string | null; pkgId: string | null; cardId: string | null; choices: Choice[]; redirect: string | null };
// Why feedback did not reach the terminal that recorded the decision. "delivering" means it is still being typed.
export type Undelivered = "delivering" | "delivery_interrupted" | "terminal_finished" | "terminal_unreachable" | "send_failed" | "no_recording_terminal";
// A product call a chief or architect flagged for review.
export type Decision = { id: string; goalId: string; text: string; rationale: string | null; by: Terminal | null; at: number; state: "recorded" | "acknowledged" | "feedback"; feedback: string | null; undelivered: Undelivered | null };
// Small work without a WorkRequest: a chief's child terminal with a branch or a PR. `since` is when it reached its state.
export type CardState = "working" | "review_ci" | "merged" | "done" | "dismissed";
export type Card = { id: string; task: string; repo: string; area: string[]; branch: string; by: Terminal | null; pr: Pr | null; ci: Ci | null; review: Review | null; state: CardState; since: number; stale: Stale[] };
// `readAt` is when the backend was read: the goals' phases describe that moment.
export type Board = { goals: Goal[]; cards: Card[]; asks: Ask[]; decisions: Decision[]; readAt: number };

export type PkgView = { pkg: Pkg; stage: Stage; since: number; untimed: boolean; failed: boolean };
export type GoalView = { goal: Goal; live: PkgView[]; queued: Pkg[]; done: Pkg[]; asks: Ask[]; ask: Ask | null; phase: Phase; lastMoveAt: number };

// The hydrated board as the backend sends it, limited to what the board reads.
export type Owned = { address?: string | null; role?: string | null; domain?: string | null; liveness?: string | null; since?: string | null };
export type PrSignal = { status?: string | null; number?: number | null; url?: string | null; repository?: string | null; created_at?: string | null; head_changed_at?: string | null; checks?: { status?: string | null; changed_at?: string | null } | null };
export type ReviewSignal = { status?: string | null; mode?: string | null; round?: number | null; started_at?: string | null; round_started_at?: string | null };
export type Slice = {
  id: string;
  work_package_id?: string | null;
  title?: string | null;
  sequence?: number;
  status?: string | null;
  group?: string | null;
  inserted_at?: string | null;
  dispatched_at?: string | null;
  // Inside `dispatched`: launching, implementing, worker_exited or review_ci.
  progress?: string | null;
  worker_terminal?: { address?: string | null; state?: string | null; status?: string | null } | null;
  observation_stale?: string[] | null;
  delivery?: { outcome?: string | null; legacy_status?: string | null; recorded_at?: string | null; pr_merged_at?: string | null } | null;
  board_state?: { stage?: string | null; entered_at?: string | null; outcome?: string | null } | null;
  pr_signal?: PrSignal | null;
  review_signal?: ReviewSignal | null;
};
type Observed = { status?: string | null; at?: string | null };
type Deployments = Record<string, { dev?: Observed | null; prod?: Observed | null } | null>;
type Written = { text?: string | null; written_at?: string | null };
export type OperatorReport = { brief?: Written | null; eta?: Written | null; parking?: { reason?: string | null; parked_at?: string | null; resumed_at?: string | null } | null };
export type Prompt = { tl_dr?: string | null; details?: string | null; custom_redirect_label?: string | null; options?: Array<{ id: string; label?: string | null; answer?: string | null; description?: string | null; pros?: string[] | null; cons?: string[] | null }> | null };
export type AskEntry = { id: string; work_request_id?: string | null; work_package_id?: string | null; card_id?: string | null; question?: string | null; decision_prompt?: Prompt | null; state?: string | null; asked_by?: string | null; asked_at?: string | null };
export type DecisionEntry = { id: string; work_request_id: string; decision?: string | null; rationale?: string | null; recorded_by?: string | null; created_at?: string | null; review_state?: string | null; feedback?: string | null; undelivered_reason?: string | null };
export type Request = { id: string; title?: string | null; phase?: string | null; repo?: string | null; repo_display?: string | null; base_branch?: string | null; inserted_at?: string | null; completed_at?: string | null; operator_completed_at?: string | null; archived_at?: string | null; worked_on?: Owned | null; operator_report?: OperatorReport | null; area_path?: string[] | null; default_branch?: string | null; deployments?: Deployments | null };
export type Detail = { work_request: Request; work_packages?: Slice[]; asks?: AskEntry[]; decisions_to_review?: DecisionEntry[] };
export type CardEntry = { id: string; state?: string | null; title?: string | null; worked_on?: Owned | null; repository?: string | null; branch?: string | null; pr?: { repository?: string | null; number?: number | null; url?: string | null; state?: string | null; ci?: { status?: string | null } | null } | null; review?: { state?: string | null; status?: string | null } | null; stale?: string[] | null; asks?: AskEntry[] | null; since?: string | null; ended_at?: string | null; updated_at?: string | null };
// What the operator can change. A backend that lacks a setting leaves it out.
export type Settings = {
  work_request_archive_after_days?: number;
  work_request_never_started_archive_after_days?: number;
  card_retention_days?: number;
  open_dashboard_on_boot?: boolean;
};
export type Hydrated = { generated_at?: string; settings?: Settings | null; work_request_details?: Detail[]; cards?: CardEntry[] };
// Archived goals come from their own read, as goal headers without packages.
export type Archived = { archived_work_requests?: { work_requests?: Request[] } | null };
type Timed = { event: HistoryEvent; at: number };

const OUTCOMES: Record<string, Outcome> = { pr_merged: "merged", finished: "finished", completed_no_pr: "completed", superseded: "superseded", abandoned: "abandoned", skipped: "skipped" };
// Packages ended before v2 keep their old status: merged or closed ones resolved, anything else did not.
const LEGACY: Record<string, Outcome> = { merged: "merged", closed: "completed" };
const PROGRESS: Record<string, Stage> = { launching: "launching", implementing: "implementing", worker_exited: "implementing", review_ci: "review_ci" };
const PHASES: Phase[] = ["intake", "planned", "active", "done", "unresolved", "archived"];
const REVIEW_MODES: Record<string, ReviewMode> = { fast: "fast", base: "normal", normal: "normal", deep: "deep", none: "none" };
// Review Suite's status for the PR's current head. "pending" means no round has started yet.
const REVIEW_STATES: Record<string, Review["state"]> = { in_progress: "running", failed: "findings", inspection_needed: "findings", passed: "done" };
const ROLES: Record<string, Role> = { chief: "chief", architect: "architect", worker: "worker", card: "card" };
const LIVENESS: Record<string, Liveness> = { live: "live", unknown: "unknown", finished: "finished" };
const UNDELIVERED = new Set<string>(["delivering", "delivery_interrupted", "terminal_finished", "terminal_unreachable", "send_failed", "no_recording_terminal"]);
const CARD_STATES = new Set<string>(["working", "review_ci", "merged", "done", "dismissed"]);
// Replays read recorded history, which holds whatever statuses agents wrote, so these are deliberately loose. First match wins.
const STATUS_RULES: Array<[RegExp, Stage]> = [
  [/^(merged|github_pr_merged)$/, "ended"],
  [/^ready$|merge_ready|ready_for_merge|review_complete|^reviewed$|review_owner_accepted|acceptance|ready_for_close/, "ready"],
  [/review|validat|ci_waiting/, "review_ci"],
];
// Used only to replay the past: the backend's phase describes the present.
const RESOLVES: Record<Outcome, boolean> = { merged: true, finished: true, completed: true, superseded: true, abandoned: false, skipped: false };

export function buildBoard(hydrated: Hydrated, history: Record<string, HistoryEvent[]>, archived: Archived | null = null): { board: Board; now: number } {
  const now = Date.parse(hydrated.generated_at ?? "") || Date.now();
  const details = hydrated.work_request_details ?? [];
  const onBoard = new Set(details.map((detail) => detail.work_request.id));
  const shelved = (archived?.archived_work_requests?.work_requests ?? []).filter((request) => !onBoard.has(request.id));
  const cards = hydrated.cards ?? [];
  const asks = [...details.flatMap((detail) => detail.asks ?? []), ...cards.flatMap((card) => (card.asks ?? []).map((ask) => ({ ...ask, card_id: card.id })))];

  const goals = [...details, ...shelved.map((request) => ({ work_request: { ...request, phase: "archived" } }))].map((detail) => buildGoal(detail, history, now));
  // A card is filed under the area of a goal in the same repository; the board carries no area for cards.
  const areas = new Map(goals.map((goal) => [goal.repo, goal.area]));

  return {
    board: {
      goals,
      cards: cards.map((card) => cardOf(card, areas, now)),
      asks: asks.filter((ask) => (ask.state ?? "open") === "open").map((ask) => askOf(ask, now)),
      decisions: details.flatMap((detail) => (detail.decisions_to_review ?? []).map((entry) => decisionOf(entry, now))),
      readAt: now,
    },
    now,
  };
}

function buildGoal(detail: Detail, history: Record<string, HistoryEvent[]>, now: number): Goal {
  const request = detail.work_request;
  const title = request.title || request.id;
  const repo = request.repo_display || request.repo || "";
  const area = areaOf(request.area_path, repo);

  return {
    id: request.id,
    title,
    area,
    repo,
    baseBranch: request.base_branch ?? null,
    defaultBranch: request.default_branch ?? null,
    deploy: deployOf(request.deployments),
    createdAt: ms(request.inserted_at) ?? now,
    phase: PHASES.find((phase) => phase === request.phase) ?? "intake",
    completedAt: ms(request.completed_at),
    archivedAt: ms(request.archived_at),
    pkgs: (detail.work_packages ?? []).map((slice) => ({ ...buildPkg(slice, history[slice.work_package_id || slice.id] ?? [], now), goalTitle: title, goalRepo: repo, area })),
    owner: ownerOf(request.worked_on),
    report: reportOf(request.operator_report, now),
  };
}

function ownerOf(owned: Owned | null | undefined): Terminal | null {
  if (!owned?.address) return null;
  return { address: owned.address, role: ROLES[owned.role ?? ""] ?? null, liveness: LIVENESS[owned.liveness ?? ""] ?? "unknown", topic: owned.domain ?? null };
}

// Someone known only by the address they wrote from.
function addressed(address: string | null | undefined): Terminal | null {
  return address ? { address, role: null, liveness: null } : null;
}

function askOf(entry: AskEntry, now: number): Ask {
  const prompt = entry.decision_prompt;
  const choices = choicesOf(prompt);
  return {
    id: entry.id,
    question: entry.question ?? "",
    details: prompt?.details || null,
    from: ms(entry.asked_at) ?? now,
    by: addressed(entry.asked_by),
    goalId: entry.work_request_id ?? null,
    pkgId: entry.work_package_id ?? null,
    cardId: entry.card_id ?? null,
    choices,
    redirect: choices.length > 0 ? prompt?.custom_redirect_label || null : null,
  };
}

function choicesOf(prompt: Prompt | null | undefined): Choice[] {
  return (prompt?.options ?? []).map((option) => ({ id: option.id, label: option.label || option.id, description: option.description || null, pros: option.pros ?? [], cons: option.cons ?? [] }));
}

function decisionOf(entry: DecisionEntry, now: number): Decision {
  const reason = entry.undelivered_reason ?? "";
  return {
    id: entry.id,
    goalId: entry.work_request_id,
    text: entry.decision ?? "",
    rationale: entry.rationale || null,
    by: addressed(entry.recorded_by),
    at: ms(entry.created_at) ?? now,
    state: entry.review_state === "feedback" || entry.review_state === "acknowledged" ? entry.review_state : "recorded",
    feedback: entry.feedback ?? null,
    undelivered: UNDELIVERED.has(reason) ? (reason as Undelivered) : null,
  };
}

function cardOf(entry: CardEntry, areas: Map<string, string[]>, now: number): Card {
  const repo = entry.repository ?? entry.pr?.repository ?? "";
  const state = CARD_STATES.has(entry.state ?? "") ? (entry.state as CardState) : "working";
  return {
    id: entry.id,
    task: entry.title || entry.branch || entry.id,
    repo,
    area: areas.get(repo) ?? areaFor(repo),
    branch: entry.branch ?? "",
    by: ownerOf(entry.worked_on),
    ...cardPrOf(entry.pr, repo),
    review: cardReviewOf(entry.review),
    state,
    since: cardSince(entry, state) ?? now,
    stale: staleOf(entry.stale),
  };
}

function cardPrOf(pr: CardEntry["pr"], repo: string): Pick<Card, "pr" | "ci"> {
  if (!pr) return { pr: null, ci: null };
  return { pr: prOf({ ...pr, status: pr.state }, repo), ci: ciOf(pr.ci?.status) };
}

// An open card has been in its state since it was seen; an ended one since it ended.
function cardSince(entry: CardEntry, state: CardState) {
  const ended = state === "merged" || state === "done" || state === "dismissed";
  return (ended ? ms(entry.ended_at) : null) ?? ms(entry.since) ?? ms(entry.updated_at);
}

// A card's review is read by the id its terminal was labelled with; its mode is not reported.
function cardReviewOf(review: CardEntry["review"]): Review | null {
  if (!review) return null;
  const state = review.state === "done" ? "done" : review.state === "unknown" ? "unknown" : (REVIEW_STATES[review.status ?? ""] ?? null);
  return { mode: null, state, round: 0 };
}

function staleOf(values: string[] | null | undefined): Stale[] {
  return (values ?? []).filter((value): value is Stale => value === "github" || value === "review");
}

// The backend's operator-owned labels come first; the local mapping only files what they leave out.
function areaOf(labelled: string[] | null | undefined, repo: string) {
  return labelled?.length ? labelled : areaFor(repo);
}

const ENVS = [["dev", "Dev"], ["prod", "Prod"]] as const;
const WORST_FIRST: Array<DeployStep["state"]> = ["failed", "pending", "waiting", "ok"];

// One step per tagged environment. A goal spanning several repositories shows the one furthest behind.
function deployOf(deployments: Deployments | null | undefined): DeployStep[] | undefined {
  const repos = Object.values(deployments ?? {});
  const steps = ENVS.flatMap(([key, env]) => {
    const seen = repos.flatMap((repo) => (repo?.[key] ? [stepOf(env, repo[key])] : []));
    return seen.sort((left, right) => WORST_FIRST.indexOf(left.state) - WORST_FIRST.indexOf(right.state)).slice(0, 1);
  });
  return steps.length > 0 ? steps : undefined;
}

function stepOf(env: DeployStep["env"], seen: Observed): DeployStep {
  const at = ms(seen.at);
  if (seen.status === "ok" || seen.status === "failed") return { env, state: seen.status, at };
  return { env, state: at === null ? "waiting" : "pending", at };
}

function reportOf(report: OperatorReport | null | undefined, now: number): ArchitectReport | undefined {
  if (!report) return undefined;
  const note = (text?: string | null, at?: string | null): Note | null => (text ? { text, at: ms(at) ?? now } : null);
  const parking = report.parking?.resumed_at ? null : report.parking;
  return { brief: note(report.brief?.text, report.brief?.written_at), eta: note(report.eta?.text, report.eta?.written_at), parked: note(parking?.reason, parking?.parked_at) };
}

function blankPkg(slice: Slice, now: number): Pkg {
  const stale = staleOf(slice.observation_stale);
  return {
    id: slice.work_package_id || slice.id,
    title: slice.title || slice.id,
    seq: slice.sequence ?? 0,
    group: slice.group || null,
    goalTitle: "",
    goalRepo: "",
    area: [],
    createdAt: ms(slice.inserted_at) ?? now,
    segs: [],
    endAt: null,
    outcome: null,
    pr: prOf(slice.pr_signal, ""),
    ci: ciOf(slice.pr_signal?.checks?.status),
    review: reviewOf(slice.review_signal, stale),
    owner: workerOf(slice.worker_terminal),
    exited: slice.status === "dispatched" && slice.progress === "worker_exited",
    stale,
  };
}

// The worker terminal as the factory's herdr-core last saw it.
function workerOf(terminal: Slice["worker_terminal"]): Terminal | null {
  if (!terminal?.address) return null;
  const liveness: Liveness = terminal.state === "finished" ? "finished" : terminal.status === "unknown" ? "unknown" : "live";
  return { address: terminal.address, role: "worker", liveness };
}

function prOf(signal: PrSignal | null | undefined, repo: string): Pr | null {
  if (!signal?.number || !signal.url) return null;
  return { number: signal.number, url: signal.url, repo: signal.repository ?? repo, open: signal.status === "open" };
}

function ciOf(checks: string | null | undefined): Ci | null {
  return checks === "passing" || checks === "pending" || checks === "failing" ? checks : null;
}

// A review host the factory could not read leaves the state unknown, whatever it said last.
function reviewOf(signal: ReviewSignal | null | undefined, stale: Stale[]): Review | null {
  const mode = REVIEW_MODES[signal?.mode ?? ""];
  if (!signal || !mode) return null;
  const state = stale.includes("review") ? "unknown" : (REVIEW_STATES[signal.status ?? ""] ?? null);
  return { mode, state, round: signal.round ?? 0 };
}

function outcomeOf(slice: Slice): Outcome | null {
  const delivery = slice.delivery;
  const recorded = delivery?.outcome ?? slice.board_state?.outcome ?? "";
  if (recorded === "legacy") return LEGACY[delivery?.legacy_status ?? ""] ?? "abandoned";
  return OUTCOMES[recorded] ?? (slice.status === "ended" ? "abandoned" : null);
}

function buildPkg(slice: Slice, events: HistoryEvent[], now: number): Pkg {
  const present = boardPkg(slice, now);
  return events.length > 0 ? withPast(present, historyPkg(slice, events, now)) : present;
}

// A snapshot also carries recorded history. The backend's reading stays the present; the history fills in how the package got there, for the replay.
function withPast(present: Pkg, past: Pkg): Pkg {
  const [current] = present.segs;
  const last = past.segs.at(-1);
  // Where the backend did not see the current stage begin, it begins at the history's last change.
  const now = current?.untimed && last ? [{ ...current, from: last.from, untimed: last.stage !== current.stage }] : present.segs;
  const cut = now[0]?.from ?? present.endAt;
  if (cut === null) return present;
  const earlier = past.segs.filter((seg) => seg.from < cut).map((seg) => ({ ...seg, to: Math.min(seg.to, cut) }));
  return { ...present, segs: [...earlier, ...now] };
}

// The backend's reading of a package: its status, its progress inside `dispatched`, and how it ended.
function boardPkg(slice: Slice, now: number): Pkg {
  const pkg = blankPkg(slice, now);
  pkg.outcome = outcomeOf(slice);
  if (pkg.outcome) return { ...pkg, endAt: endOf(slice) ?? now };
  if (slice.status !== "dispatched" && slice.status !== "ready") return pkg;

  const stage = slice.status === "ready" ? "ready" : (PROGRESS[slice.progress ?? ""] ?? "launching");
  const observed = stageTime(slice, stage);
  pkg.segs = [{ stage, from: observed ?? ms(slice.dispatched_at) ?? pkg.createdAt, to: now, failed: pkg.ci === "failing", untimed: observed === null }];
  return pkg;
}

function endOf(slice: Slice) {
  return [slice.delivery?.pr_merged_at, slice.delivery?.recorded_at, slice.board_state?.entered_at].map(ms).find((at) => at !== null) ?? null;
}

// When the package reached its stage: the backend's evidence first, then the closest thing it observed about that stage.
function stageTime(slice: Slice, stage: Stage) {
  const pr = slice.pr_signal ?? {};
  const checks = pr.checks ?? {};
  const entered = slice.board_state?.stage === "merge" ? slice.board_state.entered_at : null;
  const observed: Partial<Record<Stage, Array<string | null | undefined>>> = {
    launching: [slice.dispatched_at],
    implementing: [slice.dispatched_at],
    review_ci: [pr.created_at, pr.head_changed_at, checks.changed_at],
    ready: [entered, checks.changed_at, pr.head_changed_at],
  };
  return (observed[stage] ?? []).map(ms).find((at) => at !== null) ?? null;
}

// The recorded history of a package, read for a replay of how it moved.
function historyPkg(slice: Slice, events: HistoryEvent[], now: number): Pkg {
  const pkg = blankPkg(slice, now);
  pkg.outcome = outcomeOf(slice);
  pkg.endAt = pkg.outcome ? (endOf(slice) ?? (ms(events.at(-1)?.t) ?? now)) : null;
  const until = pkg.endAt ?? Infinity;
  const timed = events.map((event) => ({ event, at: Date.parse(event.t) })).filter(({ at }) => at <= until);
  const startAt = startOf(slice, timed, pkg.endAt);
  if (startAt === null) return pkg;

  pkg.segs = segsOf(pkg, timed, startAt, pkg.endAt ?? now);
  return pkg;
}

// Work starts when the package is dispatched.
function startOf(slice: Slice, timed: Timed[], endAt: number | null) {
  const dispatched = ms(slice.dispatched_at);
  const starts = [dispatched !== null && (endAt === null || dispatched <= endAt) ? dispatched : null, timed[0]?.at ?? null].filter((at) => at !== null);
  return starts.length > 0 ? Math.min(...starts) : null;
}

function segsOf(pkg: Pkg, timed: Timed[], startAt: number, until: number): Seg[] {
  const segs: Seg[] = [];
  let current: Seg = { stage: "implementing", from: startAt, to: until, failed: false };

  for (const { event, at } of timed) {
    if (event.y === "pr" && !pkg.pr && event.n && event.u) pkg.pr = { number: event.n, url: event.u, repo: "", open: !pkg.outcome };
    const next = nextStage(event, current.stage);
    const failed = event.y === "pr" && event.c === "failing";
    if (next && (next !== current.stage || failed !== current.failed)) {
      segs.push({ ...current, to: at });
      current = { stage: next, from: at, to: until, failed };
    }
  }
  return [...segs, current];
}

function nextStage(event: HistoryEvent, current: Stage): Stage | null {
  if (event.m) return "ended";
  if (event.y === "pr") return current === "ready" && event.c !== "failing" ? "ready" : "review_ci";
  return STATUS_RULES.find(([pattern]) => pattern.test(event.s ?? ""))?.[1] ?? null;
}

export function viewAt(board: Board, at: number): GoalView[] {
  return board.goals.filter((goal) => goal.createdAt <= at).map((goal) => goalViewAt(goal, board, at));
}

function goalViewAt(goal: Goal, board: Board, at: number): GoalView {
  const pkgs = goal.pkgs.filter((pkg) => pkg.createdAt <= at);
  const views = pkgs.map((pkg) => pkgViewAt(pkg, at));
  const live = views.filter((view) => view.stage !== "planned" && view.stage !== "ended");
  const queued = views.filter((view) => view.stage === "planned").map((view) => view.pkg);
  const done = views.filter((view) => view.stage === "ended").map((view) => view.pkg);
  const asks = board.asks.filter((ask) => ask.goalId === goal.id && ask.from <= at);
  const phase = at >= board.readAt ? goal.phase : phaseAt(goal, at, live.length, queued.length, done);

  return { goal, live, queued, done, asks, ask: asks[0] ?? null, phase, lastMoveAt: Math.max(goal.createdAt, ...views.map((view) => view.since)) };
}

// A replay has no backend reading of the past, so it derives the phase the way the backend does. First match wins.
function phaseAt(goal: Goal, at: number, live: number, queued: number, ended: Pkg[]): Phase {
  if (goal.archivedAt !== null && goal.archivedAt <= at) return "archived";
  if (goal.completedAt !== null && goal.completedAt <= at) return "done";
  if (live + queued + ended.length === 0) return "intake";
  if (live > 0) return "active";
  if (queued > 0) return "planned";
  const counted = ended.filter((pkg) => pkg.outcome !== "skipped");
  return counted.length === 0 || counted.some((pkg) => !RESOLVES[pkg.outcome ?? "abandoned"]) ? "unresolved" : "done";
}

// The ended packages that keep a goal from resolving.
export function unresolvedPkgs(view: GoalView) {
  const counted = view.done.filter((pkg) => pkg.outcome !== "skipped");
  return counted.length === 0 ? view.done : counted.filter((pkg) => !RESOLVES[pkg.outcome ?? "abandoned"]);
}

function pkgViewAt(pkg: Pkg, at: number): PkgView {
  const ended = pkg.endAt !== null && at >= pkg.endAt;
  const seg = ended ? undefined : pkg.segs.findLast((entry) => entry.from <= at);
  if (ended) return { pkg, stage: "ended", since: pkg.endAt!, untimed: false, failed: false };
  if (!seg) return { pkg, stage: "planned", since: pkg.createdAt, untimed: false, failed: false };
  return { pkg, stage: seg.stage, since: seg.from, untimed: seg.untimed === true, failed: seg.failed };
}

export function deployAt(goal: Goal, at: number): DeployStep[] {
  return (goal.deploy ?? []).map((step) => (step.at !== null && step.at > at ? { ...step, state: "waiting", at: null } : step));
}

export function liveCountAt(goals: Goal[], at: number) {
  return goals.reduce((sum, goal) => sum + goal.pkgs.filter((pkg) => isLiveAt(pkg, at)).length, 0);
}

// A package that never reported an end stops counting as live a day after its last stage change.
function isLiveAt(pkg: Pkg, at: number) {
  if (pkg.segs.length === 0 || pkg.segs[0].from > at) return false;
  return pkg.endAt === null ? at - pkg.segs.at(-1)!.from < 24 * 3600e3 : at < pkg.endAt;
}

// A PR to another repository than the goal's waits on someone else, such as upstream maintainers.
export function waitsOnOthers(pkg: Pkg) {
  return pkg.outcome === null && pkg.pr !== null && pkg.pr.open && pkg.pr.repo !== "" && pkg.pr.repo !== pkg.goalRepo;
}

export function span(msValue: number) {
  const minutes = Math.max(0, Math.round(msValue / 60000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours}h ${String(minutes % 60).padStart(2, "0")}m` : `${Math.round(hours / 24)}d`;
}

function ms(value?: string | null) {
  const time = Date.parse(value ?? "");
  return Number.isFinite(time) ? time : null;
}
