import { areaLabel } from "./areas";
import { lanesOf, UnresolvedLine } from "./board";
import { GoalHead } from "./goal-head";
import type { GoalView } from "./model";
import { GoalPackages, reportFor, useGoalLevel } from "./report";

// Direction 2: every goal reports in, one card each, with its packages only if you ask.
export function Briefing({ at, views }: { at: number; views: GoalView[] }) {
  const lanes = lanesOf(views, at);

  return (
    <div className="mx-auto max-w-[1280px]">
      <div className="space-y-4">
        {lanes.main.map((view) => (
          <GoalReport key={view.goal.id} at={at} view={view} />
        ))}
      </div>
    </div>
  );
}

function GoalReport({ at, view }: { at: number; view: GoalView }) {
  const report = reportFor(view);
  const { level, showAll, toggle } = useGoalLevel(report.verdict);

  return (
    <article className="rounded-lg border border-line bg-panel p-5" data-goal={view.goal.id}>
      <span className="mb-1 block pl-7 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">{areaLabel(view.goal.area)}</span>
      <GoalHead big at={at} open={level !== "closed"} report={report} toggle={toggle} view={view} />
      <UnresolvedLine className="ml-7 mt-3" view={view} />
      {level !== "closed" ? (
        <div className="mt-4 pl-5">
          <GoalPackages at={at} level={level} view={view} onFull={showAll} />
        </div>
      ) : null}
    </article>
  );
}
