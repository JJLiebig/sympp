// What is broken or stuck on the board, read from the same goal views every layout shows.
import { deployAt, waitsOnOthers, type Card, type GoalView, type Pkg } from "./model";

// Broken: checks fail or a deploy failed. Stuck: nothing will move until someone steps in.
export type Trouble =
  | { kind: "ci"; key: string; view: GoalView; pkg: Pkg }
  | { kind: "deploy"; key: string; view: GoalView; env: string }
  | { kind: "card_ci"; key: string; card: Card }
  | { kind: "unresolved"; key: string; view: GoalView }
  | { kind: "exited"; key: string; view: GoalView; pkg: Pkg }
  | { kind: "silent"; key: string; view: GoalView; pkg: Pkg | null }
  | { kind: "waits"; key: string; view: GoalView; pkg: Pkg; since: number };

const BROKEN = new Set<Trouble["kind"]>(["ci", "deploy", "card_ci"]);

export function isBroken(trouble: Trouble) {
  return BROKEN.has(trouble.kind);
}

// Keys match the exits that can play on them: an unresolved goal leaves by its goal id, a finished package by its id.
export function troublesOf(views: GoalView[], cards: Card[], at: number): Trouble[] {
  const found: Trouble[] = [];
  for (const view of views) {
    if (view.phase === "archived") continue;
    for (const step of deployAt(view.goal, at)) if (step.state === "failed") found.push({ kind: "deploy", key: `deploy:${view.goal.id}:${step.env}`, view, env: step.env });
    if (view.phase === "unresolved") found.push({ kind: "unresolved", key: view.goal.id, view });
    if (view.goal.owner?.liveness === "unknown") found.push({ kind: "silent", key: `silent:${view.goal.id}`, view, pkg: null });
    for (const live of view.live) {
      const pkg = live.pkg;
      if (live.failed) found.push({ kind: "ci", key: `ci:${pkg.id}`, view, pkg });
      if (pkg.exited && live.stage === "implementing") found.push({ kind: "exited", key: `exited:${pkg.id}`, view, pkg });
      else if (pkg.owner?.liveness === "unknown") found.push({ kind: "silent", key: `silent:${pkg.id}`, view, pkg });
      if (waitsOnOthers(pkg)) found.push({ kind: "waits", key: pkg.id, view, pkg, since: live.since });
    }
  }
  for (const card of cards) if (card.ci === "failing" && (card.state === "working" || card.state === "review_ci")) found.push({ kind: "card_ci", key: `card:${card.id}`, card });
  return found;
}

// One short word per kind, for the goal cards.
export const TROUBLE_WORD: Record<Trouble["kind"], { text: string; tone: string }> = {
  ci: { text: "CI failing", tone: "text-fail" },
  deploy: { text: "Deploy failed", tone: "text-fail" },
  card_ci: { text: "CI failing", tone: "text-fail" },
  unresolved: { text: "Unresolved", tone: "text-checks" },
  exited: { text: "Worker exited", tone: "text-checks" },
  silent: { text: "Not answering", tone: "text-checks" },
  waits: { text: "Waiting upstream", tone: "text-checks" },
};
