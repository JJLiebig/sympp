import { MoreHorizontal } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { readOnly } from "./api";
import type { Goal, GoalView, Phase } from "./model";
import { useAct, type GoalStep, type OperatorAction } from "./operator";

type Action = { key: GoalStep; label: string; hint: string; confirm: string };

const STALE_MS = 30 * 24 * 3600e3;

// None of these stops a running worker or merges a PR, so a goal with work in flight says so.
function actionsFor(phase: Phase, moving: number): Action[] {
  const running = moving > 0 ? ` ${moving} ${moving === 1 ? "package is" : "packages are"} still moving and will keep running.` : "";
  const complete: Action = { key: "complete", label: "Complete", hint: `Close this goal as done, whatever its packages say.${running}`, confirm: "Complete?" };
  const archive: Action = { key: "archive", label: "Archive", hint: `Take it off the board. It can be restored.${running}`, confirm: "Archive?" };
  const restore: Action = { key: "restore", label: "Restore", hint: "Put it back on the board.", confirm: "Restore?" };
  const remove: Action = { key: "delete", label: "Delete", hint: `Remove it for good, with its history, its packages and their worktrees.${running}`, confirm: "Delete for good?" };
  // Only a done or unresolved goal can be archived; anything still open is completed first.
  if (phase === "archived") return [restore, remove];
  if (phase === "done") return [archive, remove];
  return phase === "unresolved" ? [complete, archive, remove] : [complete, remove];
}

// A button for one operator action. With `confirm` it takes a second click. A refusal shows next to it.
export function ActButton({ action, className = "", confirm, label, look = "rounded px-1.5 py-0.5 text-xs font-medium", tone = "text-dim" }: { action: OperatorAction; className?: string; confirm?: string; label: string; look?: string; tone?: string }) {
  const act = useAct();
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  if (readOnly) return null;

  const run = async () => {
    if (confirm && !armed) return setArmed(true);
    setBusy(true);
    setFailure(null);
    try {
      await act(action);
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
    } finally {
      setBusy(false);
      setArmed(false);
    }
  };

  return (
    <span className={`flex shrink-0 items-center gap-2 ${className}`}>
      <button className={`${look} hover:bg-line hover:text-ink disabled:opacity-50 ${armed ? "bg-line text-ink" : tone}`} disabled={busy} type="button" onBlur={() => setArmed(false)} onClick={() => void run()}>
        {armed ? confirm : label}
      </button>
      {failure ? <span className="text-xs text-fail">{failure}</span> : null}
    </span>
  );
}

// Completing, archiving, restoring or deleting a goal. Each takes a second click.
export function GoalActions({ className, goal, moving = 0, phase }: { className?: string; goal: Goal; moving?: number; phase: Phase }) {
  const act = useAct();
  const [open, setOpen] = useState(false);
  const [armed, setArmed] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const root = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return undefined;
    const close = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener("pointerdown", close);
    return () => window.removeEventListener("pointerdown", close);
  }, [open]);

  if (readOnly) return <span className={`inline-block size-6 shrink-0 ${className ?? ""}`} />;

  const toggle = () => {
    setOpen(!open);
    setArmed(null);
    setFailure(null);
  };
  const pick = async (action: Action) => {
    if (armed !== action.key) return setArmed(action.key);
    setBusy(true);
    try {
      await act({ kind: "goal", goalId: goal.id, step: action.key });
      setOpen(false);
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
    } finally {
      setBusy(false);
      setArmed(null);
    }
  };

  return (
    <span ref={root} className={`relative inline-block shrink-0 ${className ?? ""}`}>
      <button aria-expanded={open} aria-label={`Actions for ${goal.title}`} className={`flex size-6 items-center justify-center rounded hover:bg-line hover:text-ink ${open ? "bg-line text-ink" : "text-faint"}`} title={actionsFor(phase, moving).map((action) => action.label).join(", ")} type="button" onClick={toggle}>
        <MoreHorizontal className="size-4" />
      </button>
      {open ? (
        <span className="absolute right-0 top-full z-30 mt-1 block w-72 rounded border border-line bg-bg p-1 text-left text-sm font-normal shadow-xl">
          {actionsFor(phase, moving).map((action) => (
            <button key={action.key} className={`block w-full rounded px-2.5 py-1.5 text-left hover:bg-line disabled:opacity-50 ${action.key === "delete" ? "text-fail" : "text-ink"}`} disabled={busy} type="button" onClick={() => void pick(action)}>
              <span className="block font-medium">{armed === action.key ? `${action.confirm} Click again` : action.label}</span>
              <span className="block text-xs text-dim">{action.hint}</span>
            </button>
          ))}
          {failure ? <span className="block px-2.5 py-1.5 text-xs text-fail">{failure}</span> : null}
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
  if (readOnly || choices.length === 0) return null;

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
