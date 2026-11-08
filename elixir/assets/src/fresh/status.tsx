import { useEffect } from "react";

import { asset } from "./api";
import iconNeeded from "./board-icon-needed.png";
import iconQuiet from "./board-icon.png";
import type { GoalView } from "./model";
import { spotlight } from "./motion";

// The first question, answered in one corner: am I needed? The dot sits at the edge and the tab icon repeats it.
// While someone waits, it takes you to the list of questions.
export function Status({ needed, views }: { needed: number; views: GoalView[] }) {
  const words = needed > 0 ? `You are needed in ${needed}` : "You are not needed";
  return (
    <span className="flex shrink-0 items-center gap-3 text-sm">
      <span className="hidden text-xs text-faint min-[1440px]:inline">{overview(views)}</span>
      {needed > 0 ? (
        <button className="rounded px-1.5 py-0.5 font-semibold text-you hover:bg-you/10" type="button" onClick={() => spotlight("#needs-you")}>
          {words}
        </button>
      ) : (
        <span className="text-dim">{words}</span>
      )}
      <span className={`size-2 rounded-full ${needed > 0 ? "animate-pulse bg-you" : "bg-merge"}`} />
    </span>
  );
}

// Planned goals count too, so a board with work waiting never reads as empty.
function overview(views: GoalView[]) {
  const moving = views.reduce((sum, view) => sum + view.live.length, 0);
  const goals = views.filter((view) => view.phase === "active").length;
  const waiting = views.filter((view) => view.phase === "planned" || view.phase === "intake").length;
  const now = moving > 0 ? `${moving} moving across ${goals} ${goals === 1 ? "goal" : "goals"}` : "Nothing moving";
  if (waiting > 0) return `${now} · ${waiting} not started`;
  return moving > 0 || views.some((view) => view.phase !== "done" && view.phase !== "archived") ? now : "No open goals";
}

// Readable from a background tab: the count in the title, and a small orange dot on the icon while needed.
export function useTabSignal(needed: number) {
  useEffect(() => {
    document.title = needed > 0 ? `(${needed}) sympp` : "sympp";
    const icon = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (icon) icon.href = asset(needed > 0 ? iconNeeded : iconQuiet);
  }, [needed]);
}
