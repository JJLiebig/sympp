import { areaLabel } from "./areas";
import { lanesOf, UnresolvedLine } from "./board";
import { AreaTag, GoalHead } from "./goal-head";
import type { GoalView } from "./model";
import { Presence } from "./motion";
import { GoalPackages, reportFor, useGoalLevel, wantsAttention } from "./report";
import { Reveal } from "./reveal";

type BlockOf = { label: string; tagged?: boolean; tone: string; views: GoalView[] };

// Direction 1: the old dropdown, alive. Goals that want attention come first; the rest are filed by area.
export function Outline({ at, views }: { at: number; views: GoalView[] }) {
  const lanes = lanesOf(views, at);
  const urgent = lanes.main.filter((view) => wantsAttention(reportFor(view).verdict));
  const steady = lanes.main.filter((view) => !urgent.includes(view));
  const areas = [...new Set(steady.map((view) => areaLabel(view.goal.area)))];
  const blocks: BlockOf[] = [
    ...(urgent.length > 0 ? [{ label: "Needs attention", tagged: true, tone: "text-ink", views: urgent }] : []),
    ...areas.map((area) => ({ label: area, tone: "text-faint", views: steady.filter((view) => areaLabel(view.goal.area) === area) })),
  ];

  return (
    <div className="mx-auto max-w-[1280px] space-y-8">
      <Presence holdsOf={(block) => block.views.map((view) => view.goal.id)} items={blocks} keyOf={(block) => block.label}>
        {({ item, key, ref }) => <Block key={key} ref={ref} at={at} block={item} />}
      </Presence>
    </div>
  );
}

function Block({ at, block, ref }: { at: number; block: BlockOf; ref: (node: HTMLElement | null) => void }) {
  return (
    <section ref={ref}>
      <h2 className={`mb-1 text-[11px] font-semibold uppercase tracking-[0.14em] ${block.tone}`}>{block.label}</h2>
      <div className="divide-y divide-line border-y border-line">
        <Presence items={block.views} keyOf={(view) => view.goal.id}>
          {({ item, key, ref: row }) => <GoalRow key={key} ref={row} at={at} tagged={block.tagged} view={item} />}
        </Presence>
      </div>
    </section>
  );
}

function GoalRow({ at, ref, tagged, view }: { at: number; ref: (node: HTMLElement | null) => void; tagged?: boolean; view: GoalView }) {
  const report = reportFor(view);
  const { level, showAll, toggle } = useGoalLevel(report.verdict);

  return (
    <div ref={ref} className="py-2.5 pr-2" data-goal={view.goal.id}>
      <GoalHead area={tagged ? <AreaTag view={view} /> : null} at={at} open={level !== "closed"} report={report} toggle={toggle} view={view} />
      <UnresolvedLine className="ml-7 mt-2" view={view} />
      <Reveal className="pl-5 pt-2" show={level !== "closed"}>
        <GoalPackages at={at} level={level === "full" ? "full" : "now"} view={view} onFull={showAll} />
      </Reveal>
    </div>
  );
}
