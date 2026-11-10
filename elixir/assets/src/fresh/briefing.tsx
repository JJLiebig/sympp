import { areaLabel } from "./areas";
import { lanesOf, UnresolvedLine } from "./board";
import { GoalHead } from "./goal-head";
import type { GoalView } from "./model";
import { Presence } from "./motion";
import { GoalPackages, reportFor, useGoalLevel } from "./report";
import { Reveal } from "./reveal";

// Direction 2: every goal reports in, one card each, with its packages only if you ask.
export function Briefing({ at, views }: { at: number; views: GoalView[] }) {
  const lanes = lanesOf(views, at);

  return (
    <div className="mx-auto max-w-[1280px]">
      <div className="space-y-4">
        <Presence items={lanes.main} keyOf={(view) => view.goal.id}>
          {({ item, key, ref }) => <GoalReport key={key} ref={ref} at={at} view={item} />}
        </Presence>
      </div>
    </div>
  );
}

function GoalReport({ at, ref, view }: { at: number; ref: (node: HTMLElement | null) => void; view: GoalView }) {
  const report = reportFor(view);
  const { level, showAll, toggle } = useGoalLevel(report.verdict, view.goal.id);

  return (
    <article ref={ref} className="rounded-lg border border-line bg-panel p-5" data-goal={view.goal.id}>
      <span className="mb-1 block pl-7 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">{areaLabel(view.goal.area)}</span>
      <GoalHead big at={at} open={level !== "closed"} report={report} toggle={toggle} view={view} />
      <UnresolvedLine className="ml-7 mt-3" view={view} />
      <Reveal className="pl-5 pt-4" show={level !== "closed"}>
        <GoalPackages at={at} level={level === "full" ? "full" : "now"} view={view} onFull={showAll} />
      </Reveal>
    </article>
  );
}
