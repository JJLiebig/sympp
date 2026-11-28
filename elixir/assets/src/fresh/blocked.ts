import type { Blocker, Goal, Pkg } from "./model";

// A PR is `owner/name#number`. A package target also carries the goal it sits in once the board is built.
export type BlockerTarget = { kind: "pr" | "work_request" | "work_package" | "ask"; id: string; goalId?: string };

// A package named as a blocker opens inside its own goal.
export function placeBlockers(goals: Goal[]) {
  const home = new Map(goals.flatMap((goal) => goal.pkgs.map((pkg) => [pkg.id, goal.id] as const)));
  for (const pkg of goals.flatMap((goal) => goal.pkgs)) {
    pkg.blockers = pkg.blockers?.map((blocker) => (blocker.target?.kind === "work_package" ? { ...blocker, target: { ...blocker.target, goalId: home.get(blocker.target.id) } } : blocker));
  }
}

// What a blocked package waits on: one short line per blocker that hasn't cleared, and the first of them that can be opened.
// A package is blocked when the factory says so, as Herdr reads it: plan order alone shows as Planned, not Blocked.
export type BlockedOn = { lines: string[]; target: BlockerTarget | null };
export function blockedOn(pkg: Pkg): BlockedOn | null {
  if (!pkg.blocked || pkg.outcome) return null;
  const open = (pkg.blockers ?? []).filter((blocker) => blocker.state !== "cleared");
  return { lines: open.map(blockerLine), target: open.find((blocker) => blocker.target)?.target ?? null };
}

const HOLD_TEXT = 80;
function blockerLine(blocker: Blocker) {
  const target = blocker.target;
  const summary = blocker.summary?.trim() ?? "";
  const clipped = summary.length > HOLD_TEXT ? `${summary.slice(0, HOLD_TEXT - 1).trimEnd()}…` : summary;
  const what = blocker.hold || !target ? (clipped ? `hold: ${clipped}` : "hold")
    : target.kind === "pr" ? `PR ${target.id.split("/").pop()}`
    : target.kind === "work_package" ? `${target.id} (package)`
    : target.kind === "work_request" ? `${target.id} (WorkRequest)`
    : `ask ${target.id}`;
  return blocker.state === "impossible" ? `impossible: ${what}, replan` : what;
}
