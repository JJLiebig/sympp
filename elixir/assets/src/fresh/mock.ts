// The demo board: invented work shaped like the owner's real repositories and chief topics, with every
// v2 state on it at least once. Operator actions change it in memory only.
import type { Ask, Board, Card, CardState, Choice, Ci, Decision, Goal, Liveness, Outcome, Pkg, Review, ReviewMode, Role, Seg, Stage, Terminal } from "./model";
import type { OperatorAction, Subject } from "./operator";

const MIN = 60e3;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

const AREAS: Record<string, string[]> = {
  "JJLiebig/sympp": ["Herdr", "sympp"],
  "JJLiebig/herdr-core": ["Herdr", "herdr-core"],
  "nextidemedia/vod-kraken": ["Nextide-Kraken", "vod-kraken"],
  "nextidemedia/nextide-web": ["Nextide-Misc", "nextide-web"],
};

const term = (address: string, role: Role, liveness: Liveness = "live", topic: string | null = null): Terminal => ({ address, role, liveness, topic });
const prOf = (repo: string, number: number, open = true) => ({ number, url: `https://github.com/${repo}/pull/${number}`, repo, open });
const review = (mode: ReviewMode, state: Review["state"] = null, round = 1): Review => ({ mode, state, round });

// One package. Times are minutes before now: `started` when it was dispatched, `since` when it reached its stage.
type Plan = { title: string; group?: string; stage?: Stage; started?: number; since?: number; outcome?: Outcome; ended?: number; pr?: [repo: string, number: number]; ci?: Ci; review?: Review; owner?: Terminal };

// An ended package worked for three hours before it ended; a moving one implemented until it reached its stage.
function segsOf(plan: Plan, endAt: number | null, now: number): Seg[] {
  if (endAt !== null) return plan.outcome === "skipped" ? [] : [{ stage: "implementing", from: endAt - 3 * HOUR, to: endAt, failed: false }];
  const stage = plan.stage ?? "planned";
  if (stage === "planned") return [];
  const started = now - (plan.started ?? 0) * MIN;
  if (stage === "launching" || stage === "implementing") return [{ stage, from: started, to: now, failed: false }];
  const since = now - (plan.since ?? 0) * MIN;
  return [{ stage: "implementing", from: started, to: since, failed: false }, { stage, from: since, to: now, failed: plan.ci === "failing" }];
}

function pkg(goal: { id: string; title: string; repo: string }, seq: number, plan: Plan, now: number): Pkg {
  const endAt = plan.outcome ? now - (plan.ended ?? 0) * MIN : null;
  return {
    id: `${goal.id}-${seq}`,
    title: plan.title,
    seq,
    group: plan.group ?? null,
    goalTitle: goal.title,
    goalRepo: goal.repo,
    area: AREAS[goal.repo],
    createdAt: now - 3 * DAY,
    segs: segsOf(plan, endAt, now),
    endAt,
    outcome: plan.outcome ?? null,
    pr: plan.pr ? prOf(plan.pr[0], plan.pr[1], !plan.outcome || plan.outcome === "finished") : null,
    ci: plan.ci ?? null,
    review: plan.review ?? null,
    owner: plan.owner ?? null,
  };
}

type GoalOptions = { owner: Terminal | null; age?: number; completed?: number; archived?: number; brief?: [text: string, ago: number, eta?: string]; parked?: [text: string, ago: number] };

function goal(id: string, title: string, repo: string, plans: Plan[], options: GoalOptions, now: number): Goal {
  const head = { id, title, repo };
  const note = (text: string, ago: number) => ({ text, at: now - ago * MIN });
  const report = options.brief || options.parked ? { brief: options.brief ? note(options.brief[0], options.brief[1]) : null, eta: options.brief?.[2] ? note(options.brief[2], options.brief[1]) : null, parked: options.parked ? note(...options.parked) : null } : undefined;

  return {
    id,
    title,
    area: AREAS[repo],
    repo,
    baseBranch: "main",
    defaultBranch: "main",
    createdAt: now - (options.age ?? 3 * DAY / MIN) * MIN,
    completedAt: options.completed === undefined ? null : now - options.completed * MIN,
    archivedAt: options.archived === undefined ? null : now - options.archived * MIN,
    pkgs: plans.map((plan, index) => pkg(head, index + 1, plan, now)),
    owner: options.owner,
    report,
  };
}

// Chiefs, by topic. Their child terminals become cards.
const HERDR = term("jjdev/t0hd", "chief", "live", "Herdr");
const KRAKEN = term("jjdesktop/t0kr", "chief", "live", "Nextide-Kraken");
const MISC_GONE = term("jjlaptop/t0nm", "chief", "finished", "Nextide-Misc");
const MISC = term("jjdesktop/t0nx", "chief", "live", "Nextide-Misc");

function goals(now: number): Goal[] {
  const sympp = "JJLiebig/sympp";
  const herdr = "JJLiebig/herdr-core";
  const kraken = "nextidemedia/vod-kraken";
  const web = "nextidemedia/nextide-web";

  return [
    goal("wr-owner", "sympp v2: worked-on-by ownership", sympp, [
      { title: "sympp_worked_on table and atomic acquisition", group: "Backend / Ledger", outcome: "merged", ended: 310, pr: [sympp, 848] },
      { title: "Takeover when the owner has finished", group: "Backend / Ledger", stage: "ready", started: 260, since: 18, pr: [sympp, 851], ci: "passing", review: review("fast", "done"), owner: term("jjdev/t3fa", "worker") },
      { title: "Bridge heartbeat and clean detach", group: "Backend / Bridge", stage: "review_ci", started: 190, since: 52, pr: [sympp, 853], ci: "pending", review: review("normal", "running", 2), owner: term("jjdev/t3fb", "worker") },
      { title: "Forward Herdr labels in _meta", group: "Backend / Bridge", stage: "implementing", started: 41, owner: term("jjdev/t3fc", "worker") },
      { title: "Release route for unknown owners", group: "Board", stage: "launching", started: 3 },
      { title: "Owner chip on WorkRequest rows", group: "Board" },
    ], { owner: term("jjdev/t1q1", "architect"), brief: ["Ledger acquisition is merged and takeover is green. The bridge heartbeat is on its second normal review round; labels are being wired now.", 22, "Backend done tonight; board slice tomorrow"] }, now),

    goal("wr-alerts", "Kraken: alert routing for missed sponsor segments", kraken, [
      { title: "Missed-segment detector", group: "Backend / Detection", outcome: "merged", ended: 1400, pr: [kraken, 311] },
      { title: "Backfill the last 30 days", group: "Backend / Detection", outcome: "merged", ended: 980, pr: [kraken, 314] },
      { title: "Slack delivery with dedupe", group: "Backend / Delivery", stage: "review_ci", started: 300, since: 95, pr: [kraken, 318], ci: "failing", review: review("deep", "findings", 3), owner: term("jjdesktop/t5k2", "worker") },
      { title: "Daily email digest", group: "Backend / Delivery", stage: "implementing", started: 140, owner: term("jjlaptop/t1x9", "worker", "unknown") },
      { title: "Alert list on the stream page", group: "Dashboard / Stream page" },
      { title: "Mute rules per creator", group: "Dashboard / Settings" },
    ], { owner: term("jjdesktop/t2dq", "architect"), brief: ["Detection is done. Slack delivery is stuck on its third deep review round with a failing check, and the digest worker's laptop stopped answering.", 35] }, now),

    goal("wr-focus", "herdr-core: focus a terminal from panel actions", herdr, [
      { title: "hc send --no-submit", outcome: "merged", ended: 700, pr: [herdr, 204] },
      { title: "Panel focus API", stage: "ready", started: 900, since: 240, pr: ["herdrdev/herdr-app", 212], ci: "passing", review: review("none"), owner: term("jjdev/t6ab", "worker", "finished") },
      { title: "Focus action in the sympp mod", stage: "implementing", started: 75, owner: term("jjdev/t6ac", "worker") },
    ], { owner: term("jjlaptop/t2m4", "architect", "unknown") }, now),

    goal("wr-backoff", "Upstream: tracker poll backoff for Symphony", sympp, [
      { title: "Port backoff into sympp", outcome: "merged", ended: 2000, pr: [sympp, 802] },
      { title: "Back off on Linear rate limits", stage: "ready", started: 3000, since: 1500, pr: ["openai/symphony", 97], ci: "passing", review: review("fast", "done"), owner: term("jjdesktop/t7aa", "worker", "finished") },
    ], { owner: term("jjdesktop/t7a0", "architect", "finished") }, now),

    goal("wr-recap", "Nextide web: sponsored-stream recap export", web, [
      { title: "Recap PDF layout", outcome: "merged", ended: 600, pr: [web, 1290] },
      { title: "XLSX export", outcome: "abandoned", ended: 420 },
      { title: "Share link for recaps", outcome: "skipped", ended: 400 },
    ], { owner: term("jjdesktop/t8rc", "architect", "finished") }, now),

    goal("wr-language", "Kraken: creator language detection v2", kraken, [], { owner: KRAKEN, age: 50 }, now),
    goal("wr-failed-calls", "sympp: durable failed-call counts", sympp, [{ title: "sympp_failed_calls table" }, { title: "Summarize failed calls from the table" }], { owner: term("jjdev/t1q1", "architect"), age: 2 * DAY / MIN }, now),

    goal("wr-restore", "herdr-core: restore sessions after a reboot", herdr, [
      { title: "Persist pane layout on exit", outcome: "merged", ended: 400, pr: [herdr, 190] },
      { title: "Restore layout on start", outcome: "merged", ended: 260, pr: [herdr, 193] },
      { title: "Crash-safe session file write", outcome: "finished", ended: 200, pr: ["herdrdev/herdr-app", 198] },
      { title: "Check restore on Windows", outcome: "completed", ended: 190 },
      { title: "Reattach agents (first take)", outcome: "superseded", ended: 300 },
      { title: "Reattach agents", outcome: "merged", ended: 185, pr: [herdr, 196] },
    ], { owner: term("jjdev/t9rs", "architect", "finished"), brief: ["Sessions come back after a reboot. The session-file fix waits upstream; it was finished here.", 180] }, now),

    goal("wr-qr", "Nextide web: QR codes for campaign links", web, [
      { title: "QR generator endpoint", outcome: "merged", ended: 5 * 24 * 60, pr: [web, 1244] },
      { title: "Download button on campaign links", outcome: "merged", ended: 5 * 24 * 60 - 30, pr: [web, 1246] },
    ], { owner: term("jjdesktop/t3qr", "architect", "finished") }, now),

    goal("wr-roster", "Nextide web: roster import from CSV", web, [
      { title: "CSV parser and column mapping", outcome: "merged", ended: 3 * 24 * 60, pr: [web, 1260] },
      { title: "Import preview" },
    ], { owner: term("jjdesktop/t4ro", "architect", "finished"), parked: ["Waiting for the agency's final column list.", 2 * 24 * 60] }, now),

    goal("wr-vod", "Kraken: VOD playback retry", kraken, [{ title: "Retry signed playback URLs", outcome: "merged", ended: 9 * 24 * 60, pr: [kraken, 280] }], { owner: null, archived: 6 * 24 * 60 }, now),
  ];
}

type CardPlan = { task: string; repo: string; branch: string; by: Terminal; state: CardState; since: number; pr?: number; ci?: Ci; review?: Review };

function card(plan: CardPlan, now: number): Card {
  const address = plan.by.address;
  return { id: `card-${address.replace("/", "-")}`, task: plan.task, repo: plan.repo, area: AREAS[plan.repo], branch: plan.branch, by: plan.by, pr: plan.pr ? prOf(plan.repo, plan.pr, plan.state === "review_ci") : null, ci: plan.ci ?? null, review: plan.review ?? null, state: plan.state, since: now - plan.since * MIN, dismissed: false };
}

function cards(now: number): Card[] {
  const plans: CardPlan[] = [
    { task: "Fix panel flicker on resize", repo: "JJLiebig/herdr-core", branch: "fix/panel-flicker", by: term("jjdev/t4aa", "card", "live", HERDR.topic), state: "working", since: 34 },
    { task: "Dark theme tokens for the panel", repo: "JJLiebig/herdr-core", branch: "feat/panel-tokens", by: term("jjdev/t4ab", "card", "live", HERDR.topic), state: "review_ci", since: 12, pr: 207, ci: "passing", review: review("fast", "running") },
    { task: "Rotate bridge logs", repo: "JJLiebig/sympp", branch: "fix/bridge-log-rotation", by: term("jjdev/t4ac", "card", "finished", HERDR.topic), state: "merged", since: 190, pr: 846, ci: "passing", review: review("fast", "done") },
    { task: "Parse Twitch VOD ids from share links", repo: "nextidemedia/nextide-web", branch: "fix/twitch-vod-ids", by: term("jjdesktop/t6vv", "card", "live", MISC.topic), state: "working", since: 58 },
    { task: "Campaign CSV export column order", repo: "nextidemedia/nextide-web", branch: "fix/csv-columns", by: term("jjdesktop/t6vw", "card", "finished", MISC.topic), state: "merged", since: 20 * 60, pr: 1298, ci: "passing", review: review("none") },
    { task: "Creator search typo tolerance", repo: "nextidemedia/nextide-web", branch: "spike/search-typos", by: term("jjlaptop/t6vx", "card", "finished", MISC_GONE.topic), state: "done", since: 5 * 60 },
    { task: "OCR confidence threshold for overlays", repo: "nextidemedia/vod-kraken", branch: "feat/ocr-threshold", by: term("jjlaptop/t2pp", "card", "unknown", KRAKEN.topic), state: "review_ci", since: 80, pr: 322, ci: "failing", review: review("deep", "findings", 2) },
    { task: "Empty state for the stream dashboard", repo: "nextidemedia/vod-kraken", branch: "feat/dashboard-empty", by: term("jjdesktop/t2pq", "card", "finished", KRAKEN.topic), state: "merged", since: 2 * 24 * 60, pr: 319, ci: "passing", review: review("fast", "done") },
  ];
  return plans.map((plan) => card(plan, now));
}

const choice = (id: string, label: string, pros: string[], cons: string[], recommended?: boolean): Choice => ({ id, label, pros, cons, recommended });

function asks(now: number): Ask[] {
  return [
    {
      id: "ask-release",
      question: "When you release an owner whose machine stopped answering, should its workers be released too?",
      from: now - 25 * MIN,
      by: term("jjdev/t1q1", "architect"),
      goalId: "wr-owner",
      pkgId: null,
      cardId: null,
      choices: [
        choice("owner-only", "Release only the owner", ["Nothing that is still running is touched", "Matches how Release reads on the board"], ["Workers keep a dead owner until each is released"], true),
        choice("owner-and-workers", "Release the owner and its workers", ["One click cleans up a crashed machine"], ["Can take packages away from workers that are fine but unseen"]),
      ],
    },
    { id: "ask-slack", question: "The Slack alerts bot has no workspace credential on the factory. Can you add it to the Kraken secrets store?", from: now - 70 * MIN, by: term("jjdesktop/t2dq", "architect"), goalId: "wr-alerts", pkgId: "wr-alerts-3", cardId: null, choices: [] },
    { id: "ask-vod", question: "OK to drop the old /videos/v… share links? They stopped resolving on Twitch in 2024.", from: now - 9 * MIN, by: term("jjdesktop/t6vv", "card", "live", MISC.topic), goalId: null, pkgId: null, cardId: "card-jjdesktop-t6vv", choices: [] },
  ];
}

function decisions(now: number): Decision[] {
  const decision = (id: string, goalId: string, text: string, rationale: string, by: Terminal, ago: number): Decision => ({ id, goalId, text, rationale, by, at: now - ago * MIN, state: "recorded", feedback: null, delivered: null });
  return [
    decision("dec-alerts-scope", "wr-alerts", "Alerts fire only for streams with a signed sponsor contract.", "Prospect streams have no segment schedule to compare against, so every one would alert.", KRAKEN, 140),
    decision("dec-cards", "wr-owner", "A card appears once a chief's child terminal has a branch or a PR.", "Reviewers and explorers never open branches, so they stay off the board without a special case.", HERDR, 55),
    decision("dec-recap-pdf", "wr-recap", "Recaps ship as PDF only; the XLSX export is dropped.", "Finance reads the PDF; nobody opened the XLSX in the pilot.", MISC_GONE, 430),
    { ...decision("dec-recap-share", "wr-recap", "Share links for recaps are skipped this round.", "Agencies download and forward the PDF.", MISC_GONE, 410), state: "feedback", feedback: "Keep share links on the list for Q1; two agencies asked.", delivered: false },
  ];
}

// `quiet` is the board when nobody needs the operator.
export function demoBoard(now: number, quiet = false): Board {
  return { goals: goals(now), cards: cards(now), asks: quiet ? [] : asks(now), decisions: quiet ? [] : decisions(now) };
}

function released(owner: Terminal | null): Terminal | null {
  return owner && { ...owner, liveness: "finished" };
}

function release(board: Board, subject: Subject): Board {
  if ("cardId" in subject) return { ...board, cards: board.cards.map((entry) => (entry.id === subject.cardId ? { ...entry, by: released(entry.by)! } : entry)) };
  const goals = board.goals.map((entry) => {
    if ("goalId" in subject) return entry.id === subject.goalId ? { ...entry, owner: released(entry.owner) } : entry;
    return { ...entry, pkgs: entry.pkgs.map((item) => (item.id === subject.pkgId ? { ...item, owner: released(item.owner) } : item)) };
  });
  return { ...board, goals };
}

export function applyDemo(board: Board, action: OperatorAction, now: number): Board {
  const goalsWith = (update: (goal: Goal) => Goal) => ({ ...board, goals: board.goals.map(update) });
  const pkgsWith = (id: string, update: (pkg: Pkg) => Pkg) => goalsWith((entry) => ({ ...entry, pkgs: entry.pkgs.map((item) => (item.id === id ? update(item) : item)) }));
  const decisionWith = (id: string, update: (decision: Decision) => Decision) => ({ ...board, decisions: board.decisions.map((entry) => (entry.id === id ? update(entry) : entry)) });

  switch (action.kind) {
    case "answer":
      return { ...board, asks: board.asks.filter((ask) => ask.id !== action.askId) };
    case "ack":
      return decisionWith(action.decisionId, (entry) => ({ ...entry, state: "acknowledged" }));
    case "feedback":
      return decisionWith(action.decisionId, (entry) => ({ ...entry, state: "feedback", feedback: action.text, delivered: entry.by.liveness !== "finished" }));
    case "finish":
      return { ...pkgsWith(action.pkgId, (item) => ({ ...item, outcome: "finished", endAt: now })), asks: board.asks.filter((ask) => ask.pkgId !== action.pkgId) };
    case "dismiss":
      return { ...board, cards: board.cards.map((entry) => (action.cardIds.includes(entry.id) ? { ...entry, dismissed: true } : entry)) };
    case "release":
      return release(board, action.subject);
    case "goal": {
      if (action.step === "delete") return { ...board, goals: board.goals.filter((entry) => entry.id !== action.goalId), asks: board.asks.filter((ask) => ask.goalId !== action.goalId), decisions: board.decisions.filter((entry) => entry.goalId !== action.goalId) };
      const patch: Partial<Goal> = action.step === "complete" ? { completedAt: now } : action.step === "archive" ? { archivedAt: now } : { archivedAt: null };
      return goalsWith((entry) => (entry.id === action.goalId ? { ...entry, ...patch } : entry));
    }
  }
}
