import { ChevronRight } from "lucide-react";
import type { ReactNode } from "react";

import { GoalActions, GoalRefusal } from "./actions";
import { areaLabel } from "./areas";
import { GoalOwner } from "./board";
import type { GoalView } from "./model";
import { Deploy } from "./parts";
import { Brief, DotStrip, GoalTitle, NeedsYouFlag, PhaseBadge, type Report } from "./report";
import { Reveal, Roll } from "./reveal";
import { SinceChip } from "./since";

// One goal's header in Outline and Briefing: the title and its flags on the left, the packages and the count
// on the right, and the brief under the title across the whole width. Narrow, the right side wraps below the title.
export function GoalHead({ at, area, big, open, report, toggle, view }: { at: number; area?: ReactNode; big?: boolean; open: boolean; report: Report; toggle: () => void; view: GoalView }) {
  const total = view.live.length + view.queued.length + view.done.length;

  return (
    <>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
        <button className="flex min-w-[min(100%,18rem)] flex-1 items-start gap-3 text-left" type="button" onClick={toggle}>
          <ChevronRight className={`mt-1 size-4 shrink-0 text-faint transition-transform ${open ? "rotate-90" : ""}`} />
          <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-3 gap-y-0.5">
            <span className={`min-w-0 max-w-full ${big ? "text-lg font-semibold leading-snug wrap-break-word" : "truncate font-medium"}`}>
              <GoalTitle goal={view.goal} />
            </span>
            <PhaseBadge small={!big} view={view} />
            <NeedsYouFlag view={view} />
            <SinceChip goalId={view.goal.id} />
            {area}
          </span>
        </button>
        <span className="ml-auto flex max-w-full flex-wrap items-center justify-end gap-x-3 gap-y-1">
          <span className="flex max-w-[440px] flex-wrap items-center justify-end gap-y-1">
            <DotStrip view={view} />
            <Deploy at={at} goal={view.goal} />
          </span>
          <span className="shrink-0 font-mono text-xs text-dim">
            {view.live.length > 0 ? (
              <>
                <Roll value={view.live.length} /> moving ·{" "}
              </>
            ) : null}
            <Roll value={view.done.length} />/<Roll value={total} /> done
          </span>
          <GoalOwner className="w-44 shrink-0" view={view} />
          <GoalActions goal={view.goal} phase={view.phase} />
        </span>
      </div>
      <GoalRefusal className="pl-7 pt-1" goalId={view.goal.id} />
      <Reveal show={Boolean(report.brief || report.eta)}>
        <Brief at={at} className={`mt-1 pl-7 ${big ? "text-[15px] leading-relaxed text-ink/90" : "text-sm text-dim"}`} report={report}>
          {report.sample ? <span className="ml-2 rounded border border-line px-1 font-mono text-[10px] uppercase text-faint">sample wording</span> : null}
        </Brief>
      </Reveal>
    </>
  );
}

export function AreaTag({ view }: { view: GoalView }) {
  return <span className="shrink-0 text-[11px] uppercase tracking-[0.12em] text-faint">{areaLabel(view.goal.area)}</span>;
}
