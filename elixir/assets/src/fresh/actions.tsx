import { MoreHorizontal } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState, type FocusEvent, type KeyboardEvent as KeyPress } from "react";

import { leaveGoal } from "./exits";
import type { Goal, GoalView, Phase, Pkg } from "./model";
import { calm, EASE } from "./motion";
import { GLYPH } from "./parts";
import { useAct, type GoalStep, type OperatorAction } from "./operator";
import { goalKey, keyOf, useOperation } from "./pending";
import { Reveal } from "./reveal";

export type Action = { key: GoalStep; label: string; danger?: boolean };

const STALE_MS = 30 * 24 * 3600e3;

const COMPLETE: Action = { key: "complete", label: "Complete" };
const ARCHIVE: Action = { key: "archive", label: "Archive" };
const RESTORE: Action = { key: "restore", label: "Restore" };
const DELETE: Action = { key: "delete", label: "Delete", danger: true };

// Only a done or unresolved goal can be archived; anything still open is completed first.
export function actionsFor(phase: Phase): Action[] {
  if (phase === "archived") return [RESTORE, DELETE];
  if (phase === "done") return [ARCHIVE, DELETE];
  return phase === "unresolved" ? [COMPLETE, ARCHIVE, DELETE] : [COMPLETE, DELETE];
}

// A goal step plays on the goal it belongs to; its refusal shows on the goal too.
function useGoalStep() {
  const act = useAct();
  return (goalId: string, step: GoalStep, from: Element | null) => leaveGoal(goalId, step, from?.closest<HTMLElement>("[data-goal]") ?? null, () => act({ kind: "goal", goalId, step }));
}

// A button for one operator action. With `confirm` it takes a second click. A refusal shows next to it; a goal's
// shows under the goal.
export function ActButton({ action, className = "", confirm, label, look = "rounded px-1.5 py-0.5 text-xs font-medium", tone = "text-dim" }: { action: OperatorAction; className?: string; confirm?: string; label: string; look?: string; tone?: string }) {
  const act = useAct();
  const step = useGoalStep();
  const button = useRef<HTMLButtonElement>(null);
  const [armed, setArmed] = useState(false);
  const { busy, refused } = useOperation(keyOf(action));

  const run = () => {
    if (confirm && !armed) return setArmed(true);
    setArmed(false);
    void (action.kind === "goal" ? step(action.goalId, action.step, button.current) : act(action));
  };

  return (
    <span className={`flex shrink-0 items-center gap-2 ${className}`}>
      <button ref={button} className={`${look} hover:bg-line hover:text-ink disabled:opacity-50 ${armed ? "bg-line text-ink" : tone}`} disabled={busy} type="button" onBlur={() => setArmed(false)} onClick={run}>
        {armed ? confirm : label}
      </button>
      {refused && action.kind !== "goal" ? <span className="text-xs text-fail">{refused.reason}</span> : null}
    </span>
  );
}

// Why the goal's last step did not go through. It opens under the goal and closes on the next attempt.
export function GoalRefusal({ className = "", goalId }: { className?: string; goalId: string }) {
  const { refused } = useOperation(goalKey(goalId));
  const refusal = refused?.action.kind === "goal" ? `Couldn't ${refused.action.step} it. ${refused.reason}` : null;
  return (
    <Reveal className={className} show={refusal !== null}>
      <p className="text-sm text-fail" role="alert">
        {refusal}
      </p>
    </Reveal>
  );
}

export type MenuItem<K extends string> = { key: K; label: string; danger?: boolean };

// A ⋯ button that opens a short menu of actions. Each takes a second click: the first arms it.
// Opening it puts focus on the first action, and the arrow keys move between them. Closing it from inside, with
// Escape or a pick, hands focus back to the ⋯ button so the keyboard keeps its place. Focus leaving it closes it unarmed.
// The ⋯ button and its items, sized for a pointer or, with `touch`, for a finger. Read when drawn: parts.tsx,
// which holds GLYPH, imports this module in turn.
function menuSize(touch: boolean) {
  if (touch) return { trigger: "flex size-11 shrink-0 items-center justify-center rounded-md active:bg-line", menu: "w-48", item: "min-h-11 px-3" };
  return { trigger: GLYPH, menu: "w-40", item: "px-2.5 py-1.5" };
}

export function ActionMenu<K extends string>({ className, items, label, onPick, touch = false }: { className?: string; items: Array<MenuItem<K>>; label: string; onPick: (key: K, root: HTMLElement | null) => void; touch?: boolean }) {
  const size = menuSize(touch);
  const [open, setOpen] = useState(false);
  const [armed, setArmed] = useState<K | null>(null);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return undefined;
    const close = (event: PointerEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent) {
        if (event.key !== "Escape") return;
        if (menu.current?.contains(document.activeElement)) trigger.current?.focus();
      } else if (root.current?.contains(event.target as Node)) return;
      setOpen(false);
    };
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", close);
    };
  }, [open]);

  useLayoutEffect(() => {
    if (!open) return;
    menu.current?.querySelector<HTMLElement>("[role=menuitem]")?.focus();
    if (!calm()) menu.current?.animate([{ opacity: 0, transform: "scale(0.96) translateY(-4px)" }, { opacity: 1, transform: "none" }], { duration: 150, easing: EASE });
  }, [open]);

  const toggle = () => {
    setOpen(!open);
    setArmed(null);
  };
  const move = (event: KeyPress<HTMLElement>) => {
    // Back out to the ⋯ button closes the menu like Escape; Tab onward closes it when focus leaves.
    if (event.key === "Tab" && event.shiftKey) {
      event.preventDefault();
      trigger.current?.focus();
      setOpen(false);
      setArmed(null);
      return;
    }
    const step = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
    if (!step || !menu.current) return;
    event.preventDefault();
    const all = [...menu.current.querySelectorAll<HTMLElement>("[role=menuitem]")];
    all[(all.indexOf(document.activeElement as HTMLElement) + step + all.length) % all.length]?.focus();
  };
  const leave = (event: FocusEvent) => {
    if (open && !root.current?.contains(event.relatedTarget as Node | null)) {
      setOpen(false);
      setArmed(null);
    }
  };
  const pick = (item: MenuItem<K>, button: HTMLButtonElement) => {
    if (armed !== item.key) {
      setArmed(item.key);
      if (!calm()) button.animate([{ transform: "scale(0.98)" }, { transform: "scale(1)" }], { duration: 160, easing: EASE });
      return;
    }
    trigger.current?.focus();
    setOpen(false);
    setArmed(null);
    onPick(item.key, root.current);
  };

  return (
    <span ref={root} className={`relative inline-block shrink-0 ${className ?? ""}`} onBlur={leave}>
      <button ref={trigger} aria-expanded={open} aria-haspopup="menu" aria-label={label} className={`${size.trigger} ${open ? "bg-line text-ink" : "text-faint"}`} title={items.map((item) => item.label).join(", ")} type="button" onClick={toggle}>
        <MoreHorizontal className="size-4" />
      </button>
      {open ? (
        <span ref={menu} className={`absolute right-0 top-full z-30 mt-1 flex ${size.menu} origin-top-right flex-col rounded-lg border border-line bg-[#15171d] p-1 text-left text-sm font-medium shadow-[0_12px_32px_rgba(0,0,0,0.5)]`} data-menu role="menu" onKeyDown={move}>
          {items.map((item) => {
            const on = armed === item.key;
            return (
              <button key={item.key} aria-label={on ? `${item.label}?` : item.label} className={`flex items-center rounded ${size.item} text-left transition-colors ${item.danger ? "text-fail" : "text-ink"} ${on ? (item.danger ? "bg-fail/12" : "bg-line") : "hover:bg-white/[0.06]"}`} role="menuitem" tabIndex={-1} type="button" onClick={(event) => pick(item, event.currentTarget)}>
                {item.label}
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

// Completing, archiving, restoring or deleting a goal.
export function GoalActions({ className, goal, phase }: { className?: string; goal: Goal; phase: Phase }) {
  const step = useGoalStep();
  return <ActionMenu className={className} items={actionsFor(phase)} label={`Actions for ${goal.title}`} onPick={(key, root) => void step(goal.id, key, root)} />;
}

const FINISH: Array<MenuItem<"finish">> = [{ key: "finish", label: "Finish" }];

// Finishing a package whose PR waits on others. Its row ends at once; a refusal brings it back and shows under it.
export function PkgActions({ pkg }: { pkg: Pkg }) {
  const act = useAct();
  const finish: OperatorAction = { kind: "finish", pkgId: pkg.id };
  const { refused } = useOperation(keyOf(finish));

  return (
    <>
      <ActionMenu className="justify-self-end" items={FINISH} label={`Actions for ${pkg.title}`} onPick={() => void act(finish)} />
      {refused ? (
        <p className="col-span-full text-xs text-fail" role="alert">
          {refused.reason}
        </p>
      ) : null}
    </>
  );
}

// Clears a shelf in one go: everything on it, or only what has sat there for a month. Each takes a second click.
// The goals leave at once and are archived one after another; a refusal brings them back and shows here.
export function ShelfCleanup({ at, views }: { at: number; views: GoalView[] }) {
  const act = useAct();
  const [armed, setArmed] = useState<string | null>(null);
  const { busy, refused } = useOperation(keyOf({ kind: "archive", goalIds: [] }));
  // A goal counts as old from its last package move or its completion, whichever came later.
  const stale = views.filter((view) => at - Math.max(view.lastMoveAt, view.goal.completedAt ?? 0) > STALE_MS);
  const choices = [
    { key: "stale", label: `older than 30 days (${stale.length})`, picked: stale.length < views.length ? stale : [] },
    { key: "all", label: `all (${views.length})`, picked: views },
  ].filter((choice) => choice.picked.length > 0);
  if (choices.length === 0) return null;

  const pick = (choice: (typeof choices)[number]) => {
    if (armed !== choice.key) return setArmed(choice.key);
    setArmed(null);
    void act({ kind: "archive", goalIds: choice.picked.map((view) => view.goal.id) });
  };

  return (
    <p className="flex items-center gap-1 text-xs text-faint">
      <span title="Takes them off the board. They can be restored.">Archive</span>
      {choices.map((choice) => (
        <button key={choice.key} className={`rounded px-1.5 py-0.5 hover:bg-line hover:text-ink disabled:opacity-50 ${armed === choice.key ? "bg-line text-ink" : ""}`} disabled={busy} type="button" onClick={() => pick(choice)}>
          {armed === choice.key ? `Archive ${choice.picked.length}? Click again` : choice.label}
        </button>
      ))}
      {refused ? <span className="text-fail">{refused.reason}</span> : null}
    </p>
  );
}
