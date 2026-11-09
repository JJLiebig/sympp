// Pure scope model for the Topic, Space and task views. Topic and Space are one view; a space only
// narrows the tasks to its repository. Health comes from one place, each package's own evidence, so a
// task and its drill-in can never disagree. No GPUI or Herdr imports.

import { shortRepo, span, LIVE_STAGES } from "./model.js";
import { NOWHERE, spaceRepo, spaceById } from "./levels.js";

const keyOf = (value) => shortRepo(value ?? "").toLowerCase();

// Package progress carries no inferred human attention.
export function packageEvidence(pkg, now, needsYou = false) {
  const live = LIVE_STAGES.includes(pkg.stage);
  return { pkg, needsYou, active: live || (pkg.stage !== "ended" && needsYou) };
}

// The PR's checks as one live signal, apart from the step line: "waiting" before they start, then
// "running", "passed" or "failed"; "unknown" when the PR's checks can't be read. Checks the PR
// reports always show. `has_ci` comes from the local checkout's workflows, so it only decides whether
// a repository keeps an empty slot before then. Works for packages and cards alike.
const CHECKS = { pending: "running", passing: "passed", failing: "failed", unavailable: "unknown" };
const REPORTED = new Set(["running", "passed", "failed"]);
export function ciOf(item) {
  if (item.stage === "ended" || item.state === "merged" || item.state === "done") return null;
  const state = CHECKS[item.pr.checks] ?? "waiting";
  return REPORTED.has(state) || item.ci === true ? state : null;
}

// A task's checks at a glance: any failing, else any running, else passed once any passed. A task
// with CI keeps its slot from the start, so nothing shifts when its first PR opens.
export function taskCi(packages) {
  const states = packages.map(ciOf).filter(Boolean);
  if (!states.length) return null;
  return ["failed", "running", "passed", "unknown"].find((s) => states.includes(s)) ?? "waiting";
}

// The review's mode and state in a word or two: "fast · done", "normal · round 2", "deep · findings".
// No review recorded says nothing.
export function reviewText(review) {
  if (!review?.mode && !review?.state) return null;
  const round = review.round > 1 ? `round ${review.round}` : null;
  const state = review.state === "running" ? round ?? "running" : review.state === "findings" ? "findings" : review.state;
  return [review.mode, state].filter(Boolean).join(" · ");
}

// A live package's way from build to merge, as the web board draws it: Build until a PR opens;
// Review/CI is Review once a review runs and Checks before it; Ready is Merge.
export const LIFECYCLE = ["Build", "PR", "Checks", "Review", "Merge"];
export const REVIEW_SLOT = 3;
export function lifecycleSlot(pkg) {
  if (pkg.stage === "ready") return 4;
  if (pkg.stage === "review_ci") return pkg.review.mode && pkg.review.mode !== "none" && pkg.review.state ? REVIEW_SLOT : 2;
  return pkg.pr.number ? 1 : 0;
}

// Normal is the default review mode, so only the others are named.
const MODE_WORD = { deep: "deep ", fast: "fast " };

// The status column: how long the package has been in its stage, or under review its round and how
// long that round has run ("deep r6 · 26m"), or once the round has ended, how ("r2 · findings").
export function lifecycleStatus(pkg, now) {
  if (lifecycleSlot(pkg) !== REVIEW_SLOT) return pkg.untimed || pkg.since === null ? "" : span(now - pkg.since);
  const from = pkg.review.roundStartedAt ?? pkg.review.startedAt ?? (pkg.untimed ? null : pkg.since);
  const round = `${MODE_WORD[pkg.review.mode] ?? ""}r${Math.max(1, pkg.review.round)}`;
  if (pkg.review.state !== "running") return `${round} · ${pkg.review.state}`;
  return from === null ? round : `${round} · ${span(now - from)}`;
}

// A package dispatched whose worker terminal hasn't shown up yet.
export const unmanned = (pkg) => pkg.stage === "launching";

// The task's open asks, each answerable here through its own route.
export function asksOf(job) {
  return job.asks.map((ask) => ({ key: ask.key, text: ask.text, pkgId: ask.pkgId, by: ask.by, question: ask }));
}

// The web board's strip: one box per package, run by phase (the first segment of each group path)
// in the order the phases first appear, ungrouped work last. Dropped packages leave the strip.
export function stripOf(job) {
  const counted = job.packages.filter((pkg) => pkg.outcome !== "dropped");
  const order = [...(job.phases ?? []), null];
  const runs = order.map((phase) => ({ phase, pkgs: counted.filter((pkg) => (pkg.phase ?? null) === phase) })).filter((run) => run.pkgs.length);
  for (const run of runs) run.pkgs.sort((a, b) => a.seq - b.seq);
  return runs;
}

// Package entries under their group paths: a phase per first segment, each nested group inside its
// parent, in the order their packages are planned; ungrouped packages last, in a node named null.
export function groupTree(entries) {
  const root = { name: null, depth: -1, items: [], children: [] };
  for (const entry of [...entries].sort((a, b) => a.pkg.seq - b.pkg.seq)) {
    let node = root;
    entry.pkg.group.forEach((name, depth) => {
      let next = node.children.find((c) => c.name === name);
      if (!next) node.children.push(next = { name, depth, items: [], children: [] });
      node = next;
    });
    node.items.push(entry);
  }
  return [...root.children, ...(root.items.length ? [{ name: null, depth: 0, items: root.items, children: [] }] : [])];
}

// A task shows recorded asks, decisions to review, progress and its place in the scope.
export function taskOf(job, now) {
  const asks = asksOf(job);
  const evidence = job.packages.filter((pkg) => pkg.outcome !== "dropped").map((pkg) => packageEvidence(pkg, now, asks.some((ask) => ask.pkgId === pkg.id)));
  const archived = job.lane === "archived";
  const later = !asks.length && (archived || job.lane === "backlog" || job.lane === "landed" || job.state === "settled");
  return { job, evidence, asks, decisions: job.decisions, strip: stripOf(job), total: evidence.length, ci: taskCi(evidence.map((e) => e.pkg)),
    later, archived, band: asks.length ? 0 : 2 };
}

// Whether a job or card, by its repositories, touches the scope.
function touching(path, desk, place) {
  if (path.space) {
    const found = spaceById(desk, path.space);
    const key = found ? spaceRepo(found.space) : null;
    return (item) => Boolean(key) && item.repos.some((repo) => keyOf(repo) === key);
  }
  if (path.topic === NOWHERE) return (item) => place.home(item) === NOWHERE;
  return (item) => place.touches(item, path.topic);
}

// The tasks a Topic or Space shows: every task touching it, once, in a stable order. What needs
// the person comes first, then the rest, each by when it was opened, so a task never moves just
// because it advanced. Work settled for over a day and dormant work leave for the dashboard;
// archived work keeps a shelf so it can be restored.
export function scopeTasks(path, desk, jobs, place, now) {
  return jobs.filter(touching(path, desk, place)).filter((job) => job.lane !== "settled" && job.lane !== "dormant")
    .map((job) => taskOf(job, now))
    .sort((a, b) => a.band - b.band || a.job.createdAt - b.job.createdAt || String(a.job.id).localeCompare(String(b.job.id)));
}

// The small-work cards a Topic or Space shows: working and in review first, then merged and done,
// each newest first.
const CARD_ORDER = { working: 0, review_ci: 0, merged: 1, done: 1 };
export function scopeCards(path, desk, cards, place) {
  return (cards ?? []).filter(touching(path, desk, place))
    .sort((a, b) => CARD_ORDER[a.state] - CARD_ORDER[b.state] || (b.since ?? 0) - (a.since ?? 0));
}

// The drill-in's parts: the packages at work or waiting on the person each get a row, in planned
// order; landed and queued packages fold into one mark each.
export function packageParts(task) {
  const bySeq = (a, b) => a.pkg.seq - b.pkg.seq;
  return {
    active: task.evidence.filter((e) => e.active).sort(bySeq),
    landed: task.evidence.filter((e) => e.pkg.stage === "ended").sort(bySeq),
    queued: task.evidence.filter((e) => !e.active && e.pkg.stage === "planned").sort(bySeq),
  };
}

// The scope's name for its bar.
export function scopeTitle(path, desk) {
  if (path.space) {
    const found = spaceById(desk, path.space);
    return found ? found.space.name || shortRepo(found.space.folder) || "Space" : "Space";
  }
  return desk.find((topic) => topic.id === path.topic)?.name ?? "Topic";
}
