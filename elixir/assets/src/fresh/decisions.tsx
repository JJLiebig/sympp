import { useId, useState } from "react";

import { ActButton } from "./actions";
import { readOnly } from "./api";
import { span, type Board, type Decision } from "./model";
import { focusGoal } from "./motion";
import { useAct } from "./operator";
import { Owner } from "./owner";

// Product calls chiefs and architects flagged for review, and feedback that could not reach its terminal.
export function Decisions({ at, board, decisions }: { at: number; board: Board; decisions: Decision[] }) {
  const shown = decisions.filter((entry) => entry.state === "recorded" || (entry.state === "feedback" && entry.delivered === false));
  if (shown.length === 0) return null;
  const waiting = shown.filter((entry) => entry.state === "recorded").length;

  return (
    <section className="mb-8">
      <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">Decisions to review{waiting > 0 ? ` · ${waiting}` : ""}</h2>
      <ul className="divide-y divide-line border-y border-line">
        {[...shown].sort((left, right) => right.at - left.at).map((entry) => (
          <DecisionItem key={entry.id} at={at} board={board} decision={entry} />
        ))}
      </ul>
    </section>
  );
}

function DecisionItem({ at, board, decision }: { at: number; board: Board; decision: Decision }) {
  const goal = board.goals.find((entry) => entry.id === decision.goalId);
  const [writing, setWriting] = useState(false);

  return (
    <li className="grid grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-1 py-2.5 pr-2">
      <div className="min-w-0">
        <p className="flex min-w-0 items-baseline gap-3 text-xs">
          <span className="shrink-0 uppercase tracking-[0.12em] text-faint">{decision.by.topic ?? goal?.area[0]}</span>
          {goal ? (
            <button className="min-w-0 truncate text-dim hover:text-ink" type="button" onClick={() => focusGoal(goal.id)}>
              {goal.title}
            </button>
          ) : null}
        </p>
        <p className="mt-1 max-w-[75ch] text-sm font-medium text-ink">{decision.text}</p>
        {decision.rationale ? <p className="max-w-[75ch] text-sm text-dim">{decision.rationale}</p> : null}
        {decision.state === "feedback" ? (
          <p className="mt-1.5 flex max-w-[75ch] items-baseline gap-2 text-sm">
            <span className="shrink-0 rounded-full border border-checks/50 px-1.5 text-[11px] font-semibold text-checks">Undelivered</span>
            <span className="text-dim">“{decision.feedback}”</span>
          </p>
        ) : null}
      </div>
      <div className="flex flex-col items-end gap-1.5">
        <p className="flex items-center gap-3">
          <Owner owner={decision.by} />
          <span className="font-mono text-[11px] text-faint">{span(at - decision.at)} ago</span>
        </p>
        {decision.state === "recorded" && !writing && !readOnly ? (
          <p className="flex items-center gap-1">
            <ActButton action={{ kind: "ack", decisionId: decision.id }} label="Ack" tone="text-ink" />
            <button className="rounded px-1.5 py-0.5 text-xs font-medium text-dim hover:bg-line hover:text-ink" type="button" onClick={() => setWriting(true)}>
              Feedback
            </button>
          </p>
        ) : null}
      </div>
      {writing ? <FeedbackForm decision={decision} onCancel={() => setWriting(false)} /> : null}
    </li>
  );
}

// Free text for the terminal that recorded the decision. A failed send keeps what was written.
function FeedbackForm({ decision, onCancel }: { decision: Decision; onCancel: () => void }) {
  const act = useAct();
  const id = useId();
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

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
    <form className="col-span-2 mt-1.5 max-w-[880px] space-y-1.5" onSubmit={(event) => { event.preventDefault(); if (text.trim()) void submit(); }}>
      <div className="flex items-start gap-2">
        <label className="sr-only" htmlFor={id}>Feedback for {decision.by.address}</label>
        <textarea
          autoFocus
          aria-invalid={failure ? true : undefined}
          className={`min-h-9 flex-1 resize-y rounded border bg-panel px-3 py-2 text-sm text-ink placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-ink/40 ${failure ? "border-fail" : "border-line"}`}
          disabled={busy}
          id={id}
          placeholder={`Feedback for ${decision.by.address}`}
          rows={2}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") onCancel();
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && text.trim()) void submit();
          }}
        />
        <button className="h-9 shrink-0 rounded bg-ink px-3 text-sm font-semibold text-bg disabled:opacity-40" disabled={busy || !text.trim()} type="submit">
          {busy ? "Sending…" : "Send"}
        </button>
        <button className="h-9 shrink-0 rounded px-2 text-sm text-dim hover:bg-line hover:text-ink" disabled={busy} type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
      {failure ? <p className="text-xs text-fail" role="alert">{failure}</p> : null}
    </form>
  );
}
