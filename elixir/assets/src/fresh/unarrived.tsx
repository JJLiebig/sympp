import { X } from "lucide-react";
import { useRef, useState } from "react";

import { subjectOf } from "./asks";
import { dismiss, type Unarrived } from "./delivery";
import type { Board, GoalView } from "./model";
import { GLYPH, LINK } from "./parts";

// Why an answer did not reach the terminal that asked.
const WHY: Record<string, string> = {
  delivery_interrupted: "The factory stopped while typing it",
  terminal_finished: "Its terminal has finished",
  terminal_unreachable: "Its terminal is not on the factory's machine",
  send_failed: "Typing it into its terminal failed",
  no_asking_terminal: "No terminal is recorded for this question",
};

// An answer the factory saved but could not type into the terminal that asked. It stays, with the answer to copy
// into that terminal by hand, until the operator dismisses it. `touch` sizes the controls for a finger.
export function UnarrivedAnswer({ board, className, entry, onGoal, ref, touch = false, views }: { board: Board; className: string; entry: Unarrived; onGoal?: (goalId: string) => void; ref?: (node: HTMLElement | null) => void; touch?: boolean; views: GoalView[] }) {
  const { ask, reason } = entry;
  const subject = subjectOf(ask, board, views);
  // The answer as the factory saved it, where the board has it; a card's question leaves the board once answered.
  const answer = board.asks.find((shown) => shown.id === ask.id)?.answer ?? entry.answer;
  const goal = subject.goalId;
  const control = touch ? "h-11 px-4" : "h-7 px-2.5";

  return (
    <li ref={ref} className={className} data-unarrived={ask.id}>
      <p className="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
        {goal && onGoal ? (
          <button className={`min-w-0 max-w-full truncate text-left font-medium ${LINK}`} title="Go to the goal" type="button" onClick={() => onGoal(goal)}>
            {subject.title}
          </button>
        ) : (
          <span className="min-w-0 max-w-full truncate font-medium">{subject.title}</span>
        )}
        {/* On a phone these answers sit under their own heading. */}
        {touch ? null : <span className="shrink-0 rounded-full border border-checks/50 px-1.5 text-[11px] font-semibold text-checks">Undelivered</span>}
      </p>
      <p className="mt-1 truncate text-sm text-dim" title={ask.question}>{ask.question}</p>
      <div className="mt-2 flex max-w-[46rem] items-start gap-2 rounded border border-line bg-panel py-1.5 pl-3 pr-1.5 text-sm">
        <p className="min-w-0 flex-1 whitespace-pre-line py-1 text-ink wrap-break-word">{answer}</p>
        <CopyAnswer className={control} text={`Answer: ${answer}`} />
        <button aria-label="Dismiss undelivered answer" className={touch ? "flex size-11 shrink-0 items-center justify-center text-faint" : `${GLYPH} mt-0.5 text-faint`} title="Dismiss" type="button" onClick={() => dismiss(ask.id)}>
          <X className="size-3.5" />
        </button>
      </div>
      <p className="mt-1.5 text-xs text-checks">{WHY[reason ?? ""] ?? "It did not reach the terminal that asked"}. Paste it there yourself.</p>
    </li>
  );
}

// Copies the answer the way the factory would have typed it. Where the page may not use the clipboard, such as a
// plain-HTTP address, the hidden copy is selected and copied the older way.
function CopyAnswer({ className, text }: { className: string; text: string }) {
  const [copied, setCopied] = useState(false);
  const field = useRef<HTMLTextAreaElement>(null);

  const copy = async () => {
    const button = document.activeElement as HTMLElement | null;
    const done = (await navigator.clipboard?.writeText(text).then(() => true, () => false)) || fallbackCopy(field.current);
    button?.focus();
    if (!done) return;
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  };

  return (
    <>
      <textarea ref={field} aria-hidden className="sr-only" readOnly tabIndex={-1} value={text} />
      <button className={`${className} shrink-0 rounded border border-line text-xs font-medium text-ink hover:bg-line`} type="button" onClick={() => void copy()}>
        {copied ? "Copied" : "Copy"}
      </button>
    </>
  );
}

function fallbackCopy(field: HTMLTextAreaElement | null) {
  if (!field) return false;
  field.focus({ preventScroll: true });
  field.select();
  // The only copy available outside a secure context.
  const done = document.execCommand("copy");
  window.getSelection()?.removeAllRanges();
  return done;
}
