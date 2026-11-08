import { useId, useState } from "react";

import { readOnly } from "./api";
import { span, type Ask, type Board, type Choice } from "./model";
import { focusGoal } from "./motion";
import { useAct } from "./operator";
import { Owner } from "./owner";

// What the ask is about: its goal, the package within it, or the card it came from.
function subjectOf(ask: Ask, board: Board) {
  const goal = board.goals.find((entry) => entry.id === ask.goalId);
  if (goal) return { area: goal.area, title: goal.title, detail: goal.pkgs.find((pkg) => pkg.id === ask.pkgId)?.title ?? null, goalId: goal.id };
  const card = board.cards.find((entry) => entry.id === ask.cardId);
  return { area: card?.area ?? [], title: card?.task ?? "", detail: card ? card.branch : null, goalId: null };
}

// Every question waiting on the operator, oldest first, each with its answer form.
export function NeedsYou({ asks, at, board }: { asks: Ask[]; at: number; board: Board }) {
  if (asks.length === 0) return null;

  return (
    <section className="mb-8" id="needs-you">
      <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-you">Needs you · {asks.length}</h2>
      <ul className="divide-y divide-line border-y border-line">
        {[...asks].sort((left, right) => left.from - right.from).map((ask) => (
          <AskItem key={ask.id} ask={ask} at={at} board={board} />
        ))}
      </ul>
    </section>
  );
}

function AskItem({ ask, at, board }: { ask: Ask; at: number; board: Board }) {
  const subject = subjectOf(ask, board);

  return (
    <li className="grid grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-2 py-3 pr-2" data-ask={ask.id}>
      <p className="flex min-w-0 items-baseline gap-3 text-xs">
        <span className="shrink-0 uppercase tracking-[0.12em] text-faint">{subject.area[0]}</span>
        {subject.goalId ? (
          <button className="min-w-0 truncate text-dim hover:text-ink" type="button" onClick={() => focusGoal(subject.goalId!)}>
            {subject.title}
          </button>
        ) : (
          <span className="min-w-0 truncate text-dim">{subject.title}</span>
        )}
        {subject.detail ? <span className="min-w-0 truncate font-mono text-[11px] text-faint">{subject.detail}</span> : null}
      </p>
      <p className="flex items-center justify-end gap-3">
        <Owner owner={ask.by} />
        <span className="font-mono text-[11px] text-faint">{span(at - ask.from)} ago</span>
      </p>
      <p className="col-span-2 max-w-[75ch] text-[15px] leading-snug text-ink">{ask.question}</p>
      {readOnly ? null : <AnswerForm ask={ask} />}
    </li>
  );
}

// A free answer, or one of the asker's choices with an optional note. A failed send keeps what was entered.
function AnswerForm({ ask }: { ask: Ask }) {
  const act = useAct();
  const id = useId();
  const [choice, setChoice] = useState<string | null>(ask.choices.find((entry) => entry.recommended)?.id ?? null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const chosen = ask.choices.length > 0;
  const ready = chosen ? choice !== null : text.trim() !== "";

  const submit = async () => {
    setBusy(true);
    setFailure(null);
    try {
      await act({ kind: "answer", askId: ask.id, answer: text.trim(), choice });
    } catch (caught) {
      setFailure(caught instanceof Error ? caught.message : "The backend refused this.");
      setBusy(false);
    }
  };

  return (
    <form className="col-span-2 max-w-[880px] space-y-2" onSubmit={(event) => { event.preventDefault(); if (ready) void submit(); }}>
      {chosen ? (
        <fieldset className="grid gap-2 sm:grid-cols-2" disabled={busy}>
          <legend className="sr-only">Choose an answer</legend>
          {ask.choices.map((entry) => (
            <ChoiceOption key={entry.id} choice={entry} group={id} picked={choice === entry.id} onPick={() => setChoice(entry.id)} />
          ))}
        </fieldset>
      ) : null}
      <div className="flex items-start gap-2">
        <label className="sr-only" htmlFor={`${id}-text`}>{chosen ? "Note" : "Answer"}</label>
        <textarea
          aria-invalid={failure ? true : undefined}
          className={`min-h-9 flex-1 resize-y rounded border bg-panel px-3 py-2 text-sm text-ink placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-you/60 ${failure ? "border-fail" : "border-line"}`}
          disabled={busy}
          id={`${id}-text`}
          placeholder={chosen ? "Add a note" : "Your answer"}
          rows={1}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && ready) void submit();
          }}
        />
        <button className="h-9 shrink-0 rounded bg-you px-3 text-sm font-semibold text-bg hover:bg-you/90 disabled:opacity-40" disabled={busy || !ready} type="submit">
          {busy ? "Sending…" : "Send"}
        </button>
      </div>
      {failure ? <p className="text-xs text-fail" role="alert">{failure}</p> : null}
    </form>
  );
}

function ChoiceOption({ choice, group, onPick, picked }: { choice: Choice; group: string; onPick: () => void; picked: boolean }) {
  return (
    <label className={`block cursor-pointer rounded border px-3 py-2 text-sm ${picked ? "border-you/70 bg-you/[0.06]" : "border-line hover:border-dim"}`}>
      <span className="flex items-center gap-2">
        <input checked={picked} className="accent-[var(--color-you)]" name={group} type="radio" onChange={onPick} />
        <span className="font-medium text-ink">{choice.label}</span>
        {choice.recommended ? <span className="ml-auto text-[11px] font-semibold text-you">Recommended</span> : null}
      </span>
      <span className="mt-1.5 grid gap-0.5 pl-5 text-xs">
        {choice.pros.map((pro) => (
          <span key={pro} className="text-dim"><span className="mr-1.5 font-mono text-merge">+</span>{pro}</span>
        ))}
        {choice.cons.map((con) => (
          <span key={con} className="text-dim"><span className="mr-1.5 font-mono text-fail">−</span>{con}</span>
        ))}
      </span>
    </label>
  );
}
