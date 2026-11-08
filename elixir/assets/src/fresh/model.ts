// Clean-slate model. A Goal is a WorkRequest; a Pkg is a WorkPackage with the stages it has moved through.
import { areaFor } from "./areas";

// A package's progress is derived from what its worker terminal, its PR, CI and Review Suite show.
export type Stage = "planned" | "launching" | "implementing" | "review_ci" | "ready" | "ended";
export type Outcome = "merged" | "finished" | "completed" | "superseded" | "abandoned" | "skipped";
export type ReviewMode = "fast" | "normal" | "deep" | "none";
// `state` is the Review Suite state for the PR's current head; null until a review has started.
export type Review = { mode: ReviewMode; state: "running" | "findings" | "done" | "unknown" | null; round: number };
export type Ci = "pending" | "passing" | "failing";
// "unknown" means the terminal's machine stopped answering without the agent saying it left.
export type Liveness = "live" | "unknown" | "finished";
export type Role = "chief" | "architect" | "worker" | "card";
// The terminal working on something, by its Herdr address such as `jjdev/t1q1`.
export type Terminal = { address: string; role: Role; liveness: Liveness; topic?: string | null };
// `open` is false once the PR is merged or closed. A PR to another repository waits on its maintainers.
export type Pr = { number: number; url: string; repo: string; open: boolean };
// `untimed` marks a stage whose start nobody observed: `from` is then only the closest known time.
export type Seg = { stage: Stage; from: number; to: number; failed: boolean; untimed?: boolean };
export type HistoryEvent = { t: string; s?: string; y?: string; c?: string; m?: boolean; n?: number; u?: string; a?: string; r?: string; x?: string };

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
};

// Something the architect wrote, and when.
export type Note = { text: string; at: number };
// The architect's own words about a goal. `parked` is set only while the goal is set aside.
export type ArchitectReport = { brief: Note | null; eta: Note | null; parked: Note | null };
// Where the result runs after the last merge: one step per environment whose deploy workflow is tagged.
// "waiting" means nothing has been deployed or started yet.
export type DeployStep = { env: "Dev" | "Prod"; state: "ok" | "failed" | "pending" | "waiting"; at: number | null };
// `completedAt` and `archivedAt` are the operator's own calls; every other phase is derived from the packages.
export type Goal = { id: string; title: string; area: string[]; repo: string; baseBranch: string | null; defaultBranch: string | null; createdAt: number; completedAt: number | null; archivedAt: number | null; pkgs: Pkg[]; owner: Terminal | null; report?: ArchitectReport; deploy?: DeployStep[] };

// A question for the operator. Its subject is a goal (optionally one of its packages) or a card.
export type Choice = { id: string; label: string; pros: string[]; cons: string[]; recommended?: boolean };
export type Ask = { id: string; question: string; from: number; by: Terminal; goalId: string | null; pkgId: string | null; cardId: string | null; choices: Choice[] };
// A product call a chief or architect flagged for review. `delivered` says whether feedback reached its terminal.
export type Decision = { id: string; goalId: string; text: string; rationale: string | null; by: Terminal; at: number; state: "recorded" | "acknowledged" | "feedback"; feedback: string | null; delivered: boolean | null; dismissed: boolean };
// Small work without a WorkRequest: a chief's child terminal with a branch or a PR. `since` is when it reached its state.
export type CardState = "working" | "review_ci" | "merged" | "done";
export type Card = { id: string; task: string; repo: string; area: string[]; branch: string; by: Terminal; pr: Pr | null; ci: Ci | null; review: Review | null; state: CardState; since: number; dismissed: boolean };
export type Board = { goals: Goal[]; cards: Card[]; asks: Ask[]; decisions: Decision[] };

export type Phase = "intake" | "planned" | "active" | "done" | "unresolved" | "archived";
export type PkgView = { pkg: Pkg; stage: Stage; since: number; untimed: boolean; failed: boolean };
export type GoalView = { goal: Goal; live: PkgView[]; queued: Pkg[]; done: Pkg[]; asks: Ask[]; ask: Ask | null; phase: Phase; lastMoveAt: number };

type Slice = {
  id: string;
  work_package_id?: string | null;
  title?: string | null;
  sequence?: number;
  inserted_at?: string | null;
  dispatched_at?: string | null;
  product_tree_node_id?: string | null;
  review?: { args?: { mode?: string | null } | null } | null;
  delivery?: { outcome?: string | null; recorded_at?: string | null; pr_merged_at?: string | null } | null;
  operational_state?: { key?: string | null } | null;
  board_state?: BoardState | null;
  pr_signal?: { number?: number | null; url?: string | null; repository?: string | null; created_at?: string | null; head_changed_at?: string | null; checks?: { status?: string | null; changed_at?: string | null } | null } | null;
  review_signal?: { status?: string | null; mode?: string | null; round?: number | null; started_at?: string | null; round_started_at?: string | null } | null;
};
type Observed = { status?: string | null; at?: string | null };
type Deployments = Record<string, { dev?: Observed | null; prod?: Observed | null } | null>;
type BoardState = { stage?: string | null; entered_at?: string | null; delivered?: boolean | null };
type Written = { text?: string | null; written_at?: string | null };
type OperatorReport = {
  brief?: Written | null;
  eta?: Written | null;
  parking?: { reason?: string | null; parked_at?: string | null; resumed_at?: string | null } | null;
  human_escalation?: { question?: string | null; raised_at?: string | null; resolved_at?: string | null } | null;
};
type Detail = {
  work_request: { id: string; title?: string | null; repo?: string | null; repo_display?: string | null; base_branch?: string | null; inserted_at?: string | null; completed_at?: string | null; archived_at?: string | null; operator_report?: OperatorReport | null; area_path?: string[] | null; default_branch?: string | null; deployments?: Deployments | null };
  work_packages?: Slice[];
  product_tree?: { nodes?: Array<{ id: string; title?: string | null; position?: number; parent_id?: string | null }> } | null;
};
// What the operator can change. A backend that lacks a setting leaves it out.
export type Settings = {
  work_request_archive_after_days?: number;
  work_request_never_started_archive_after_days?: number;
  solo_session_delete_after_days?: number;
  open_dashboard_on_boot?: boolean;
  capture_failed_mcp_calls?: boolean;
};
export type Hydrated = { generated_at?: string; settings?: Settings | null; work_request_details?: Detail[] };
type Timed = { event: HistoryEvent; at: number };

const OUTCOMES: Record<string, Outcome> = { pr_merged: "merged", finished: "finished", completed_no_pr: "completed", superseded: "superseded", abandoned: "abandoned", skipped: "skipped" };
// Today's backend stages, read as v2 progress.
const STAGES: Record<string, Stage> = { queued: "planned", build: "implementing", checks: "review_ci", review: "review_ci", merge: "ready", done: "ended" };
const REVIEW_MODES: Record<string, ReviewMode> = { fast: "fast", base: "normal", normal: "normal", deep: "deep", none: "none" };
// First match wins. Statuses are whatever agents wrote, so these are deliberately loose.
const STATUS_RULES: Array<[RegExp, Stage]> = [
  [/^(merged|github_pr_merged)$/, "ended"],
  [/merge_ready|ready_for_merge|review_complete|^reviewed$|review_owner_accepted|acceptance|ready_for_close/, "ready"],
  [/review|validat|ci_waiting/, "review_ci"],
];
// Outcomes whose package counts as delivered for its goal. Skipped packages are left out of the count.
const RESOLVES: Record<Outcome, boolean> = { merged: true, finished: true, completed: true, superseded: true, abandoned: false, skipped: false };

export function buildBoard(hydrated: Hydrated, history: Record<string, HistoryEvent[]>): { board: Board; now: number } {
  const now = Date.parse(hydrated.generated_at ?? "") || Date.now();
  const details = hydrated.work_request_details ?? [];
  const goals = details.map((detail) => buildGoal(detail, history, now));
  return { board: { goals, cards: [], asks: details.flatMap((detail) => asksOf(detail.work_request, now)), decisions: [] }, now };
}

function buildGoal(detail: Detail, history: Record<string, HistoryEvent[]>, now: number): Goal {
  const request = detail.work_request;
  const title = request.title || request.id;
  const repo = request.repo_display || request.repo || "";
  const area = areaOf(request.area_path, repo);
  const paths = groupPaths(detail.product_tree?.nodes ?? []);

  return {
    id: request.id,
    title,
    area,
    repo,
    baseBranch: request.base_branch ?? null,
    defaultBranch: request.default_branch ?? null,
    deploy: deployOf(request.deployments),
    createdAt: ms(request.inserted_at) ?? now,
    completedAt: ms(request.completed_at),
    archivedAt: ms(request.archived_at),
    pkgs: (detail.work_packages ?? []).map((slice) => ({ ...buildPkg(slice, history[slice.work_package_id || slice.id] ?? [], now), group: paths.get(slice.product_tree_node_id ?? "") ?? null, goalTitle: title, goalRepo: repo, area })),
    owner: null,
    report: reportOf(request.operator_report, now),
  };
}

// Group nodes as "Parent / Child" paths, the shape packages carry their group in.
function groupPaths(nodes: Array<{ id: string; title?: string | null; parent_id?: string | null }>) {
  const byId = new Map(nodes.map((node) => [node.id, node]));
  const pathOf = (id: string, seen: Set<string>): string => {
    const node = byId.get(id);
    if (!node || seen.has(id)) return "";
    const parent = node.parent_id ? pathOf(node.parent_id, new Set([...seen, id])) : "";
    return parent ? `${parent} / ${node.title || "Untitled"}` : node.title || "Untitled";
  };
  return new Map(nodes.map((node) => [node.id, pathOf(node.id, new Set())]));
}

// Only an explicit escalation by the architect asks for the operator.
function asksOf(request: Detail["work_request"], now: number): Ask[] {
  const escalation = request.operator_report?.human_escalation;
  if (!escalation?.question || escalation.resolved_at) return [];
  return [{ id: `${request.id}:escalation`, question: escalation.question, from: ms(escalation.raised_at) ?? now, by: { address: "architect", role: "architect", liveness: "unknown" }, goalId: request.id, pkgId: null, cardId: null, choices: [] }];
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
  return {
    id: slice.work_package_id || slice.id,
    title: slice.title || slice.id,
    seq: slice.sequence ?? 0,
    group: null,
    goalTitle: "",
    goalRepo: "",
    area: [],
    createdAt: ms(slice.inserted_at) ?? now,
    segs: [],
    endAt: null,
    outcome: null,
    ...signalFacts(slice),
    owner: null,
  };
}

function signalFacts(slice: Slice): Pick<Pkg, "pr" | "ci" | "review"> {
  const pr = slice.pr_signal ?? {};
  return {
    pr: pr.number && pr.url ? { number: pr.number, url: pr.url, repo: pr.repository ?? "", open: !slice.delivery?.pr_merged_at } : null,
    ci: ciOf(pr.checks?.status),
    review: reviewOf(slice),
  };
}

function ciOf(checks: string | null | undefined): Ci | null {
  if (!checks) return null;
  if (checks === "failing") return "failing";
  return checks === "passing" || checks === "success" ? "passing" : "pending";
}

function reviewOf(slice: Slice): Review | null {
  const signal = slice.review_signal ?? {};
  const mode = REVIEW_MODES[signal.mode ?? slice.review?.args?.mode ?? ""];
  if (!mode) return null;
  const status = signal.status ?? "";
  const state = /done|complete|passed/.test(status) ? "done" : /finding|inspection/.test(status) ? "findings" : status ? "running" : null;
  return { mode, state, round: signal.round ?? 1 };
}

function outcomeOf(slice: Slice): Outcome | null {
  return OUTCOMES[slice.delivery?.outcome ?? ""] ?? (slice.operational_state?.key === "skipped" ? "skipped" : null);
}

function endOf(slice: Slice, events: HistoryEvent[], now: number) {
  return ms(slice.delivery?.pr_merged_at) ?? ms(slice.delivery?.recorded_at) ?? ms(events.at(-1)?.t) ?? now;
}

// Work starts when the package is dispatched.
function startOf(slice: Slice, timed: Timed[], endAt: number | null) {
  const dispatched = ms(slice.dispatched_at);
  const starts = [dispatched !== null && (endAt === null || dispatched <= endAt) ? dispatched : null, timed[0]?.at ?? null].filter((at) => at !== null);
  return starts.length > 0 ? Math.min(...starts) : null;
}

function buildPkg(slice: Slice, events: HistoryEvent[], now: number): Pkg {
  if (!slice.board_state) return historyPkg(slice, events, now);
  const present = boardPkg(slice, slice.board_state, now);
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

// The backend's own reading of a package: its stage, when it got there, and how it ended.
function boardPkg(slice: Slice, board: BoardState, now: number): Pkg {
  const pkg = blankPkg(slice, now);
  const stage = STAGES[board.stage ?? ""] ?? "planned";
  const observed = stageTime(slice, board);
  const since = observed ?? ms(slice.dispatched_at) ?? pkg.createdAt;
  pkg.outcome = outcomeOf(slice) ?? (board.delivered || stage === "ended" ? (pkg.pr ? "merged" : "completed") : null);
  if (pkg.outcome) return { ...pkg, endAt: since };
  if (stage === "planned") return pkg;

  pkg.segs = [{ stage, from: since, to: now, failed: pkg.ci === "failing", untimed: observed === null }];
  return pkg;
}

// When the package reached its stage: the backend's evidence first, then the closest thing it observed about that stage.
function stageTime(slice: Slice, board: BoardState) {
  const pr = slice.pr_signal ?? {};
  const checks = pr.checks ?? {};
  const review = slice.review_signal ?? {};
  const delivery = slice.delivery ?? {};
  const observed: Partial<Record<string, Array<string | null | undefined>>> = {
    build: [slice.dispatched_at],
    checks: [checks.changed_at, pr.head_changed_at],
    review: [review.round_started_at, review.started_at],
    merge: [checks.changed_at, pr.head_changed_at],
    done: [delivery.pr_merged_at, delivery.recorded_at],
  };
  const stage = delivery.outcome ? "done" : (board.stage ?? "queued");
  return [board.entered_at, ...(observed[stage] ?? [])].map(ms).find((at) => at !== null) ?? null;
}

// Packages captured before the backend reported stages: the stage is read from their recorded history.
function historyPkg(slice: Slice, events: HistoryEvent[], now: number): Pkg {
  const pkg = blankPkg(slice, now);
  pkg.outcome = outcomeOf(slice);
  pkg.endAt = pkg.outcome ? endOf(slice, events, now) : null;
  const until = pkg.endAt ?? Infinity;
  const timed = events.map((event) => ({ event, at: Date.parse(event.t) })).filter(({ at }) => at <= until);
  const startAt = startOf(slice, timed, pkg.endAt);
  if (startAt === null) return pkg;

  pkg.segs = segsOf(pkg, timed, startAt, pkg.endAt ?? now);
  return pkg;
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
  return board.goals.filter((goal) => goal.createdAt <= at).map((goal) => goalViewAt(goal, board.asks, at));
}

function goalViewAt(goal: Goal, allAsks: Ask[], at: number): GoalView {
  const pkgs = goal.pkgs.filter((pkg) => pkg.createdAt <= at);
  const views = pkgs.map((pkg) => pkgViewAt(pkg, at));
  const live = views.filter((view) => view.stage !== "planned" && view.stage !== "ended");
  const queued = views.filter((view) => view.stage === "planned").map((view) => view.pkg);
  const done = views.filter((view) => view.stage === "ended").map((view) => view.pkg);
  const asks = allAsks.filter((ask) => ask.goalId === goal.id && ask.from <= at);

  return { goal, live, queued, done, asks, ask: asks[0] ?? null, phase: phaseOf(goal, at, live.length, queued.length, done), lastMoveAt: Math.max(goal.createdAt, ...views.map((view) => view.since)) };
}

// The derivation is exhaustive and the first match wins. Open asks never change the phase.
function phaseOf(goal: Goal, at: number, live: number, queued: number, ended: Pkg[]): Phase {
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
