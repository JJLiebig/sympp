import { ChevronRight } from "lucide-react";

import { GoalActions } from "./actions";
import { areaLabel } from "./areas";
import { GoalOwner, lanesOf, UnresolvedLine } from "./board";
import type { GoalView } from "./model";
import { Deploy } from "./parts";
import { BriefAge, DotStrip, GoalPackages, GoalTitle, NeedsYouFlag, PhaseBadge, reportFor, useGoalLevel, wantsAttention } from "./report";
import { SinceChip } from "./since";

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
  const total = view.live.length + view.queued.length + view.done.length;
  const open = level !== "closed";
  const said = `${report.brief}${report.eta ? ` ETA: ${report.eta}.` : ""}`;

  return (
    <div data-goal={view.goal.id}>
      {/* Two lines, each with words on the left and the matching figure on the right edge. */}
      <div className="flex items-start">
        <button className="flex min-w-0 flex-1 items-start gap-3 py-2.5 pr-2 text-left hover:bg-panel" type="button" onClick={toggle}>
          <ChevronRight className={`mt-1 size-4 shrink-0 text-faint transition-transform ${open ? "rotate-90" : ""}`} />
          <span className="min-w-0 flex-1">
            <span className="flex items-baseline gap-3">
              <span className="truncate font-medium">
                <GoalTitle goal={view.goal} />
              </span>
              <PhaseBadge small view={view} />
              <NeedsYouFlag view={view} />
              <SinceChip goalId={view.goal.id} />
              {tagged ? <span className="shrink-0 text-[11px] uppercase tracking-[0.12em] text-faint">{areaLabel(view.goal.area)}</span> : null}
              <span className="ml-auto shrink-0 pl-6 font-mono text-xs text-dim">
                {view.live.length > 0 ? `${view.live.length} moving · ` : ""}
                {view.done.length}/{total} done
              </span>
            </span>
            {/* Closed, the brief is one clipped line; open, it reads in full. The strip keeps its column and wraps inside it. */}
            <span className="mt-1 flex items-start gap-6">
              {open ? (
                <span className="min-w-0 flex-1 text-sm text-dim">
                  {said}
                  <BriefAge at={at} report={report} />
                </span>
              ) : (
                <span className="flex min-w-0 flex-1 items-baseline">
                  <span className="truncate text-sm text-dim" title={said}>
                    {said}
                  </span>
                  <BriefAge at={at} report={report} />
                </span>
              )}
              <span className="flex min-h-5 w-[440px] max-w-[50%] shrink-0 flex-wrap items-center justify-end gap-y-1">
                <DotStrip view={view} />
                <Deploy at={at} goal={view.goal} />
              </span>
            </span>
          </span>
        </button>
        <GoalOwner className="mt-2.5 w-44 shrink-0" view={view} />
        <GoalActions className="mt-2" goal={view.goal} moving={view.live.length} phase={view.phase} />
      </div>
      <UnresolvedLine className="mb-3 ml-7 mr-2" view={view} />
      {open ? (
        <div className="pb-3 pl-5">
          <GoalPackages at={at} level={level} view={view} onFull={showAll} />
        </div>
      ) : null}
    </div>
  );
}
