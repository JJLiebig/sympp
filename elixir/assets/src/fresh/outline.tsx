import { areaLabel } from "./areas";
import { lanesOf, UnresolvedLine } from "./board";
import { AreaTag, GoalHead } from "./goal-head";
import type { GoalView } from "./model";
import { GoalPackages, reportFor, useGoalLevel, wantsAttention } from "./report";

// Direction 1: the old dropdown, alive. Goals that want attention come first; the rest are filed by area.
export function Outline({ at, views }: { at: number; views: GoalView[] }) {
  const lanes = lanesOf(views, at);
  const urgent = lanes.main.filter((view) => wantsAttention(reportFor(view).verdict));
  const steady = lanes.main.filter((view) => !urgent.includes(view));
  const areas = [...new Set(steady.map((view) => areaLabel(view.goal.area)))];

  return (
    <div className="mx-auto max-w-[1280px] space-y-8">
      {urgent.length > 0 ? <Block at={at} label="Needs attention" tagged tone="text-ink" views={urgent} /> : null}
      {areas.map((area) => (
        <Block key={area} at={at} label={area} tone="text-faint" views={steady.filter((view) => areaLabel(view.goal.area) === area)} />
      ))}
    </div>
  );
}

function Block({ at, label, tagged, tone, views }: { at: number; label: string; tagged?: boolean; tone: string; views: GoalView[] }) {
  return (
    <section>
      <h2 className={`mb-1 text-[11px] font-semibold uppercase tracking-[0.14em] ${tone}`}>{label}</h2>
      <div className="divide-y divide-line border-y border-line">
        {views.map((view) => (
          <GoalRow key={view.goal.id} at={at} tagged={tagged} view={view} />
        ))}
      </div>
    </section>
  );
}

function GoalRow({ at, tagged, view }: { at: number; tagged?: boolean; view: GoalView }) {
  const report = reportFor(view);
  const { level, showAll, toggle } = useGoalLevel(report.verdict);

  return (
    <div className="py-2.5 pr-2" data-goal={view.goal.id}>
      <GoalHead area={tagged ? <AreaTag view={view} /> : null} at={at} open={level !== "closed"} report={report} toggle={toggle} view={view} />
      <UnresolvedLine className="ml-7 mt-2" view={view} />
      {level !== "closed" ? (
        <div className="pt-2 pl-5">
          <GoalPackages at={at} level={level} view={view} onFull={showAll} />
        </div>
      ) : null}
    </div>
  );
}
