import { X } from "lucide-react";
import { useId, useState, type MouseEvent } from "react";

import { ActButton } from "./actions";
import { span, type Board, type Decision, type Undelivered as Reason } from "./model";
import { useAct } from "./operator";
import { Owner } from "./owner";
import { GLYPH } from "./parts";

const ROW = "grid grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-2 py-3 pr-2";

// Product calls chiefs and architects flagged for review, and feedback that could not reach its terminal.
// They follow the questions' layout, in neutral tones: these calls are made already and only want a reaction.
export function Decisions({ at, board, decisions, onGoal }: { at: number; board: Board; decisions: Decision[]; onGoal: (goalId: string) => void }) {
  const shown = decisions.filter((entry) => entry.state === "recorded" || (entry.state === "feedback" && entry.undelivered !== null));
  if (shown.length === 0) return null;
  const waiting = shown.filter((entry) => entry.state === "recorded").length;

  return (
    <section className="mb-8">
      <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-dim">Decisions to review{waiting > 0 ? ` · ${waiting}` : ""}</h2>
      <ul className="divide-y divide-line border-y border-line">
        {[...shown].sort((left, right) => right.at - left.at).map((entry) => (
          <DecisionItem key={entry.id} at={at} board={board} decision={entry} onGoal={onGoal} />
        ))}
      </ul>
    </section>
  );
}

// A click on the row itself, not on a control inside it or at the end of a text selection.
function rowClick(event: MouseEvent) {
  const target = event.target as HTMLElement;
  return !target.closest("button, a, input, textarea, label, form") && !window.getSelection()?.toString();
}

function DecisionItem({ at, board, decision, onGoal }: { at: number; board: Board; decision: Decision; onGoal: (goalId: string) => void }) {
  const act = useAct();
  const goal = board.goals.find((entry) => entry.id === decision.goalId);
  const [writing, setWriting] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const undelivered = decision.state === "feedback";
  // Feedback still being typed into its terminal can't be dismissed yet.
  const typing = decision.undelivered === "delivering";
  const dismiss = () => act({ kind: "dismiss_feedback", decisionId: decision.id }).catch((caught: unknown) => setFailure(caught instanceof Error ? caught.message : "The backend refused this."));
  // The whole row answers a click: a decision opens its feedback form, undelivered feedback is dismissed.
  const onRow = (event: MouseEvent) => {
    if (!rowClick(event)) return;
    if (undelivered) {
      if (!typing) void dismiss();
    }
    else setWriting(true);
  };
  const clickable = undelivered ? !typing : !writing;

  return (
    <li className={`${ROW} ${clickable ? "cursor-pointer hover:bg-white/[0.025]" : ""}`} onClick={onRow}>
      <Subject goal={goal} onGoal={onGoal} />
      <p className="flex items-center justify-end gap-3">
        <Owner owner={decision.by} />
        <span className="font-mono text-[11px] text-faint">{span(at - decision.at)} ago</span>
      </p>
      <div className="col-span-2 max-w-[75ch]">
        <p className={`text-[15px] leading-snug ${undelivered ? "text-dim" : "text-ink"}`}>{decision.text}</p>
        {decision.rationale ? <p className="mt-0.5 text-sm text-dim">{decision.rationale}</p> : null}
      </div>
      {undelivered ? <Undelivered decision={decision} failure={failure} onDismiss={() => void dismiss()} /> : null}
      {!undelivered && !writing ? <Reactions decision={decision} onFeedback={() => setWriting(true)} /> : null}
      {/* Feedback that could not be delivered comes back as the Undelivered notice, which replaces the form. */}
      {writing && !undelivered ? <FeedbackForm decision={decision} onCancel={() => setWriting(false)} /> : null}
    </li>
  );
}

// The goal's area, and the goal the decision belongs to.
function Subject({ goal, onGoal }: { goal: Board["goals"][number] | undefined; onGoal: (goalId: string) => void }) {
  return (
    <p className="flex min-w-0 items-baseline gap-3 text-xs">
      <span className="shrink-0 uppercase tracking-[0.12em] text-faint">{goal?.area[0]}</span>
      {goal ? (
        <button className="min-w-0 truncate text-dim hover:text-ink" type="button" onClick={() => onGoal(goal.id)}>
          {goal.title}
        </button>
      ) : null}
    </p>
  );
}

// Where a question has its answer form, a decision has its two reactions.
function Reactions({ decision, onFeedback }: { decision: Decision; onFeedback: () => void }) {
  return (
    <p className="col-span-2 flex items-center gap-2">
      <ActButton action={{ kind: "ack", decisionId: decision.id }} label="Ack" look="h-8 rounded border border-line px-3 text-sm font-medium" tone="text-ink" />
      <button className="h-8 rounded px-3 text-sm font-medium text-dim hover:bg-line hover:text-ink" type="button" onClick={onFeedback}>
        Feedback
      </button>
    </p>
  );
}

export const REASON: Record<Reason, string> = {
  delivering: "Being typed into its terminal",
  delivery_interrupted: "The factory stopped while typing it",
  terminal_finished: "Its terminal has finished",
  terminal_unreachable: "Its terminal is not on the factory's machine",
  send_failed: "Typing it into its terminal failed",
  no_recording_terminal: "No terminal recorded this decision",
};

// Feedback that reached nobody: the reason shows on hover. It stays readable on the decision after a dismiss.
function Undelivered({ decision, failure, onDismiss }: { decision: Decision; failure: string | null; onDismiss: () => void }) {
  const typing = decision.undelivered === "delivering";
  return (
    <div className="col-span-2 flex max-w-[880px] items-center gap-3 rounded border border-line bg-panel px-3 py-2 text-sm">
      <span className="shrink-0 rounded-full border border-checks/50 px-1.5 text-[11px] font-semibold text-checks" title={decision.undelivered ? REASON[decision.undelivered] : undefined}>{typing ? "Sending" : "Undelivered"}</span>
      <span className="min-w-0 flex-1 text-ink">“{decision.feedback}”</span>
      {failure ? <span className="shrink-0 text-xs text-fail">{failure}</span> : null}
      {typing ? null : (
        <button aria-label="Dismiss undelivered feedback" className={`${GLYPH} text-faint`} title="Dismiss" type="button" onClick={onDismiss}>
          <X className="size-3.5" />
        </button>
      )}
    </div>
  );
}

// Free text for the terminal that recorded the decision. A failed send keeps what was written.
// `touch` sizes the controls for a finger.
const FEEDBACK_SIZE = { pointer: { text: "min-h-9 text-sm", send: "h-9 px-3", cancel: "h-9 px-2" }, touch: { text: "min-h-11 text-base", send: "h-11 px-4", cancel: "h-11 px-3" } };

// `touch` sizes the controls for a finger; `unnamed` leaves out who the feedback goes to.
// With `text` and `onText` the caller keeps what was written.
export function FeedbackForm({ decision, onCancel, onText, text: kept, touch, unnamed }: { decision: Decision; unnamed?: boolean; onCancel: () => void; onText?: (text: string) => void; text?: string; touch?: boolean }) {
  const act = useAct();
  const id = useId();
  const [own, setOwn] = useState("");
  const text = kept ?? own;
  const setText = onText ?? setOwn;
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const size = FEEDBACK_SIZE[touch ? "touch" : "pointer"];
  const label = !unnamed && decision.by ? `Feedback for ${decision.by.address}` : "Feedback";

  const submit = async () => {
    setBusy(true);
    setFailure(null);
    try {
      await act({ kind: "feedback", decisionId: decision.id, text: text.trim() });
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
      setBusy(false);
    }
  };

  return (
    <form className="col-span-2 max-w-[880px] space-y-2" onSubmit={(event) => { event.preventDefault(); if (text.trim()) void submit(); }}>
      <div className="flex items-start gap-2">
        <label className="sr-only" htmlFor={id}>{label}</label>
        <textarea
          autoFocus
          aria-invalid={failure ? true : undefined}
          className={`${size.text} flex-1 resize-y rounded border bg-panel px-3 py-2 text-ink placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-ink/40 ${failure ? "border-fail" : "border-line"}`}
          disabled={busy}
          id={id}
          placeholder={label}
          rows={1}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") onCancel();
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && text.trim()) void submit();
          }}
        />
        <button className={`${size.send} shrink-0 rounded bg-ink text-sm font-semibold text-bg disabled:opacity-40`} disabled={busy || !text.trim()} type="submit">
          {busy ? "Sending…" : "Send"}
        </button>
        <button className={`${size.cancel} shrink-0 rounded text-sm text-dim hover:bg-line hover:text-ink`} disabled={busy} type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
      {failure ? <p className="text-xs text-fail" role="alert">{failure}</p> : null}
    </form>
  );
}
