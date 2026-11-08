import { Check } from "lucide-react";

import { ActButton, GoalActions } from "./actions";
import { areaLabel } from "./areas";
import { deployAt, span, unresolvedPkgs, type GoalView } from "./model";
import { Owner } from "./owner";
import { Deploy, OUTCOME, Shelf } from "./parts";
import { GoalTitle, reportFor, type Verdict } from "./report";

const DAY = 24 * 3600e3;
const DORMANT_AFTER = 14 * DAY;
const RANK: Record<Verdict, number> = { needs_you: 0, unresolved: 1, active: 2, planned: 3, intake: 4, parked: 5, done: 6, archived: 7 };

// Where a goal belongs on the page. Only "main" asks for attention; the rest are kept out of the way.
export type Lanes = { main: GoalView[]; landed: GoalView[]; parked: GoalView[]; dormant: GoalView[]; backlog: GoalView[]; settled: GoalView[]; archived: GoalView[] };

function laneOf(view: GoalView, at: number): keyof Lanes {
  if (view.phase === "archived") return "archived";
  if (view.phase === "done") return settledLane(view, at);
  // An open question always keeps a goal in sight.
  if (view.ask || view.phase === "active" || view.phase === "unresolved") return "main";
  // The architect set the goal aside on purpose; it comes back when work resumes.
  if (view.goal.report?.parked) return "parked";
  if (view.done.length === 0) return "backlog";
  return at - view.lastMoveAt < DORMANT_AFTER ? "main" : "dormant";
}

// A done goal stays in sight for a day after its last step, and for as long as its repository tracks
// deploys and none has succeeded yet. A failed deploy puts it back in the main lane.
function settledLane(view: GoalView, at: number): keyof Lanes {
  const steps = deployAt(view.goal, at);
  if (steps.some((step) => step.state === "failed")) return "main";
  const lastStep = Math.max(view.lastMoveAt, view.goal.completedAt ?? 0, ...steps.map((step) => step.at ?? 0));
  const undeployed = steps.length > 0 && !steps.some((step) => step.state === "ok");
  return at - lastStep < DAY || undeployed ? "landed" : "settled";
}

// The main lane is ordered by who needs attention first, not by where the work is filed.
export function lanesOf(views: GoalView[], at: number): Lanes {
  const lanes: Lanes = { main: [], landed: [], parked: [], dormant: [], backlog: [], settled: [], archived: [] };
  for (const view of views) lanes[laneOf(view, at)].push(view);
  const rank = new Map(lanes.main.map((view) => [view.goal.id, RANK[reportFor(view).verdict]]));
  lanes.main.sort((left, right) => rank.get(left.goal.id)! - rank.get(right.goal.id)!);
  return lanes;
}

export function Rest({ at, lanes }: { at: number; lanes: Lanes }) {
  return (
    <>
      <Landed at={at} views={lanes.landed} />
      <Shelf age="parked" at={at} hint="set aside by the architect" label="Parked" views={lanes.parked} />
      <Shelf cleanup age="idle" at={at} hint="started, then nothing for two weeks or more" label="Dormant" views={lanes.dormant} />
      <Shelf cleanup age="waiting" at={at} hint="no package has started" label="Not started" views={lanes.backlog} />
      <Shelf cleanup age="done" at={at} hint="done more than a day ago" label="Settled" views={lanes.settled} />
      <Shelf age="archived" at={at} label="Archived" views={lanes.archived} />
    </>
  );
}

// Done goals report once more, with where the result is running, then leave on their own.
function Landed({ at, views }: { at: number; views: GoalView[] }) {
  if (views.length === 0) return null;

  return (
    <section className="mt-8">
      <h2 className="mb-1 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">Landed · last 24 hours</h2>
      <ul className="divide-y divide-line border-y border-line">
        {views.map((view) => (
          <li key={view.goal.id} className="flex items-center gap-3 py-2 pr-2 text-sm" data-goal={view.goal.id}>
            <Check className="size-4 shrink-0 text-merge" />
            <span className="max-w-[40%] shrink-0 truncate font-medium">
              <GoalTitle goal={view.goal} />
            </span>
            <span className="shrink-0 text-[11px] uppercase tracking-[0.12em] text-faint" title={view.goal.repo}>{areaLabel(view.goal.area)}</span>
            <span className="min-w-0 flex-1 truncate text-dim">{reportFor(view).brief}</span>
            <Deploy at={at} goal={view.goal} />
            <span className="w-24 shrink-0 text-right font-mono text-xs text-faint">{span(at - view.lastMoveAt)} ago</span>
            <GoalActions goal={view.goal} moving={view.live.length} phase={view.phase} />
          </li>
        ))}
      </ul>
    </section>
  );
}

// The architect or chief working on a goal.
export function GoalOwner({ className, view }: { className?: string; view: GoalView }) {
  return <Owner className={className} owner={view.goal.owner} subject={{ goalId: view.goal.id }} />;
}

// Every package has ended but not all of them landed: say which, and offer the operator's two ways out.
export function UnresolvedLine({ className = "", view }: { className?: string; view: GoalView }) {
  if (view.phase !== "unresolved") return null;
  const stuck = unresolvedPkgs(view);

  return (
    <p className={`flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm ${className}`}>
      <span className="min-w-0 flex-1 text-dim">
        {stuck.map((pkg, index) => (
          <span key={pkg.id}>
            {index > 0 ? " · " : ""}
            <span className="text-ink">{pkg.title}</span> <span className={pkg.outcome ? OUTCOME[pkg.outcome].tone : ""}>{pkg.outcome ? OUTCOME[pkg.outcome].label.toLowerCase() : ""}</span>
          </span>
        ))}
      </span>
      <ActButton action={{ kind: "goal", goalId: view.goal.id, step: "complete" }} confirm="Complete?" label="Complete" tone="text-ink" />
      <ActButton action={{ kind: "goal", goalId: view.goal.id, step: "archive" }} confirm="Archive?" label="Archive" />
    </p>
  );
}
