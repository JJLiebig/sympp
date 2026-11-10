import { MoreHorizontal } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";

import { leaveGoal, useRefusal } from "./exits";
import type { Goal, GoalView, Phase } from "./model";
import { calm, EASE } from "./motion";
import { useAct, type GoalStep, type OperatorAction } from "./operator";
import { Reveal } from "./reveal";

type Action = { key: GoalStep; label: string };

const STALE_MS = 30 * 24 * 3600e3;

const COMPLETE: Action = { key: "complete", label: "Complete" };
const ARCHIVE: Action = { key: "archive", label: "Archive" };
const RESTORE: Action = { key: "restore", label: "Restore" };
const DELETE: Action = { key: "delete", label: "Delete" };

// Only a done or unresolved goal can be archived; anything still open is completed first.
function actionsFor(phase: Phase): Action[] {
  if (phase === "archived") return [RESTORE, DELETE];
  if (phase === "done") return [ARCHIVE, DELETE];
  return phase === "unresolved" ? [COMPLETE, ARCHIVE, DELETE] : [COMPLETE, DELETE];
}

// A goal step plays on the goal it belongs to; its refusal shows on the goal too.
function useGoalStep() {
  const act = useAct();
  return (goalId: string, step: GoalStep, from: Element | null) => leaveGoal(goalId, step, from?.closest<HTMLElement>("[data-goal]") ?? null, () => act({ kind: "goal", goalId, step }));
}

// A button for one operator action. With `confirm` it takes a second click. A refusal shows next to it.
export function ActButton({ action, className = "", confirm, label, look = "rounded px-1.5 py-0.5 text-xs font-medium", tone = "text-dim" }: { action: OperatorAction; className?: string; confirm?: string; label: string; look?: string; tone?: string }) {
  const act = useAct();
  const step = useGoalStep();
  const button = useRef<HTMLButtonElement>(null);
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  const run = async () => {
    if (confirm && !armed) return setArmed(true);
    setBusy(true);
    setFailure(null);
    try {
      if (action.kind === "goal") await step(action.goalId, action.step, button.current);
      else await act(action);
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
    } finally {
      setBusy(false);
      setArmed(false);
    }
  };

  return (
    <span className={`flex shrink-0 items-center gap-2 ${className}`}>
      <button ref={button} className={`${look} hover:bg-line hover:text-ink disabled:opacity-50 ${armed ? "bg-line text-ink" : tone}`} disabled={busy} type="button" onBlur={() => setArmed(false)} onClick={() => void run()}>
        {armed ? confirm : label}
      </button>
      {failure ? <span className="text-xs text-fail">{failure}</span> : null}
    </span>
  );
}

// Why the goal's last step did not go through. It opens under the goal and closes on the next attempt.
export function GoalRefusal({ className = "", goalId }: { className?: string; goalId: string }) {
  const refusal = useRefusal(goalId);
  return (
    <Reveal className={className} show={refusal !== null}>
      <p className="text-sm text-fail" role="alert">
        {refusal}
      </p>
    </Reveal>
  );
}

// Completing, archiving, restoring or deleting a goal. Each takes a second click: the first arms it.
export function GoalActions({ className, goal, phase }: { className?: string; goal: Goal; phase: Phase }) {
  const step = useGoalStep();
  const [open, setOpen] = useState(false);
  const [armed, setArmed] = useState<GoalStep | null>(null);
  const root = useRef<HTMLSpanElement>(null);
  const menu = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return undefined;
    const close = (event: PointerEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent ? event.key === "Escape" : !root.current?.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", close);
    };
  }, [open]);

  useLayoutEffect(() => {
    if (open && !calm()) menu.current?.animate([{ opacity: 0, transform: "scale(0.96) translateY(-4px)" }, { opacity: 1, transform: "none" }], { duration: 150, easing: EASE });
  }, [open]);

  const toggle = () => {
    setOpen(!open);
    setArmed(null);
  };
  const pick = (action: Action, item: HTMLButtonElement) => {
    if (armed !== action.key) {
      setArmed(action.key);
      if (!calm()) item.animate([{ transform: "scale(0.98)" }, { transform: "scale(1)" }], { duration: 160, easing: EASE });
      return;
    }
    setOpen(false);
    setArmed(null);
    void step(goal.id, action.key, root.current);
  };

  return (
    <span ref={root} className={`relative inline-block shrink-0 ${className ?? ""}`}>
      <button aria-expanded={open} aria-haspopup="menu" aria-label={`Actions for ${goal.title}`} className={`flex size-6 items-center justify-center rounded hover:bg-line hover:text-ink ${open ? "bg-line text-ink" : "text-faint"}`} title={actionsFor(phase).map((action) => action.label).join(", ")} type="button" onClick={toggle}>
        <MoreHorizontal className="size-4" />
      </button>
      {open ? (
        <span ref={menu} className="absolute right-0 top-full z-30 mt-1 flex w-40 origin-top-right flex-col rounded-lg border border-line bg-[#15171d] p-1 text-left text-sm font-medium shadow-[0_12px_32px_rgba(0,0,0,0.5)]" data-menu role="menu">
          {actionsFor(phase).map((action) => {
            const on = armed === action.key;
            const danger = action.key === "delete";
            return (
              <button key={action.key} aria-label={on ? `${action.label}?` : action.label} className={`flex items-center rounded px-2.5 py-1.5 text-left transition-colors ${danger ? "text-fail" : "text-ink"} ${on ? (danger ? "bg-fail/12" : "bg-line") : "hover:bg-white/[0.06]"}`} role="menuitem" type="button" onClick={(event) => pick(action, event.currentTarget)}>
                {action.label}
                <span aria-hidden className={`inline-block transition-[max-width,opacity,transform] duration-200 ease-[cubic-bezier(0.2,0,0,1)] motion-reduce:transition-none ${on ? "max-w-[1ch] translate-x-0 opacity-100" : "max-w-0 -translate-x-1 opacity-0"}`}>
                  ?
                </span>
              </button>
            );
          })}
        </span>
      ) : null}
    </span>
  );
}

// Clears a shelf in one go: everything on it, or only what has sat there for a month. Each takes a second click.
export function ShelfCleanup({ at, views }: { at: number; views: GoalView[] }) {
  const act = useAct();
  const [armed, setArmed] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  // A goal counts as old from its last package move or its completion, whichever came later.
  const stale = views.filter((view) => at - Math.max(view.lastMoveAt, view.goal.completedAt ?? 0) > STALE_MS);
  const choices = [
    { key: "stale", label: `older than 30 days (${stale.length})`, picked: stale.length < views.length ? stale : [] },
    { key: "all", label: `all (${views.length})`, picked: views },
  ].filter((choice) => choice.picked.length > 0);
  if (choices.length === 0) return null;

  const pick = async (choice: (typeof choices)[number]) => {
    if (armed !== choice.key) return setArmed(choice.key);
    setBusy(true);
    setFailure(null);
    try {
      for (const view of choice.picked) await act({ kind: "goal", goalId: view.goal.id, step: "archive" });
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
    } finally {
      setBusy(false);
      setArmed(null);
    }
  };

  return (
    <p className="flex items-center gap-1 text-xs text-faint">
      <span title="Takes them off the board. They can be restored.">Archive</span>
      {choices.map((choice) => (
        <button key={choice.key} className={`rounded px-1.5 py-0.5 hover:bg-line hover:text-ink disabled:opacity-50 ${armed === choice.key ? "bg-line text-ink" : ""}`} disabled={busy} type="button" onClick={() => void pick(choice)}>
          {armed === choice.key ? `Archive ${choice.picked.length}? Click again` : choice.label}
        </button>
      ))}
      {failure ? <span className="text-fail">{failure}</span> : null}
    </p>
  );
}
