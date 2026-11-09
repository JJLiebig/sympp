import { useId, useState } from "react";

import { readOnly } from "./api";
import { span, type Ask, type Board, type Choice } from "./model";
import { REDIRECT, useAct, type Answer } from "./operator";
import { Owner } from "./owner";

// What the ask is about: its goal, the package within it, or the card it came from.
function subjectOf(ask: Ask, board: Board) {
  const goal = board.goals.find((entry) => entry.id === ask.goalId);
  if (goal) return { area: goal.area, title: goal.title, detail: goal.pkgs.find((pkg) => pkg.id === ask.pkgId)?.title ?? null, goalId: goal.id };
  const card = board.cards.find((entry) => entry.id === ask.cardId);
  return { area: card?.area ?? [], title: card?.task ?? "", detail: card ? card.branch : null, goalId: null };
}

// Every question waiting on the operator, oldest first, each with its answer form.
// `onGoal` lifts the area filter before it goes to the ask's goal, which may be filtered out.
export function NeedsYou({ asks, at, board, onGoal }: { asks: Ask[]; at: number; board: Board; onGoal: (goalId: string) => void }) {
  if (asks.length === 0) return null;

  return (
    <section className="mb-8" id="needs-you">
      <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-you">Needs you · {asks.length}</h2>
      <ul className="divide-y divide-line border-y border-line">
        {[...asks].sort((left, right) => left.from - right.from).map((ask) => (
          <AskItem key={ask.id} ask={ask} at={at} board={board} onGoal={onGoal} />
        ))}
      </ul>
    </section>
  );
}

function AskItem({ ask, at, board, onGoal }: { ask: Ask; at: number; board: Board; onGoal: (goalId: string) => void }) {
  const subject = subjectOf(ask, board);

  return (
    <li className="grid grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-2 py-3 pr-2" data-ask={ask.id}>
      <p className="flex min-w-0 items-baseline gap-3 text-xs">
        <span className="shrink-0 uppercase tracking-[0.12em] text-faint">{subject.area[0]}</span>
        {subject.goalId ? (
          <button className="min-w-0 truncate text-dim hover:text-ink" type="button" onClick={() => onGoal(subject.goalId!)}>
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
      <div className="col-span-2 max-w-[75ch]">
        <p className="text-[15px] leading-snug text-ink">{ask.question}</p>
        {ask.details ? <p className="mt-0.5 text-sm text-dim">{ask.details}</p> : null}
      </div>
      {readOnly ? null : <AnswerForm ask={ask} />}
    </li>
  );
}

// A free answer, or one of the asker's choices with an optional note. The asker may also offer to take
// a free answer instead of its choices; the note is then the answer. A failed send keeps what was entered.
function AnswerForm({ ask }: { ask: Ask }) {
  const act = useAct();
  const id = useId();
  const [choice, setChoice] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const chosen = ask.choices.length > 0;
  const redirecting = choice === REDIRECT;
  // With a choice the text is a note, unless the choice is to answer in free text.
  const noting = chosen && !redirecting;
  const { answer, ready } = draft(chosen, choice, text.trim());

  const submit = async () => {
    setBusy(true);
    setFailure(null);
    try {
      await act({ kind: "answer", askId: ask.id, answer });
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
          {ask.redirect ? <ChoiceOption choice={{ id: REDIRECT, label: ask.redirect, description: null, pros: [], cons: [] }} group={id} picked={redirecting} onPick={() => setChoice(REDIRECT)} /> : null}
        </fieldset>
      ) : null}
      <div className="flex items-start gap-2">
        <label className="sr-only" htmlFor={`${id}-text`}>{noting ? "Note" : "Answer"}</label>
        <textarea
          aria-invalid={failure ? true : undefined}
          className={`min-h-9 flex-1 resize-y rounded border bg-panel px-3 py-2 text-sm text-ink placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-you/60 ${failure ? "border-fail" : "border-line"}`}
          disabled={busy}
          id={`${id}-text`}
          placeholder={noting ? "Add a note" : "Your answer"}
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

// What the form would send, and whether it is complete: a choice, a free-text choice with its text, or free text.
function draft(chosen: boolean, choice: string | null, text: string): { answer: Answer; ready: boolean } {
  if (!chosen) return { answer: { text }, ready: text !== "" };
  return { answer: { choice: choice ?? "", note: text }, ready: choice !== null && (choice !== REDIRECT || text !== "") };
}

function ChoiceOption({ choice, group, onPick, picked }: { choice: Choice; group: string; onPick: () => void; picked: boolean }) {
  const detailed = choice.description || choice.pros.length > 0 || choice.cons.length > 0;
  return (
    <label className={`block cursor-pointer rounded border px-3 py-2 text-sm ${picked ? "border-you/70 bg-you/[0.06]" : "border-line hover:border-dim"}`}>
      <span className="flex items-center gap-2">
        <input checked={picked} className="accent-[var(--color-you)]" name={group} type="radio" onChange={onPick} />
        <span className="font-medium text-ink">{choice.label}</span>
      </span>
      {detailed ? (
        <span className="mt-1.5 grid gap-0.5 pl-5 text-xs">
          {choice.description ? <span className="text-dim">{choice.description}</span> : null}
          {choice.pros.map((pro) => (
            <span key={pro} className="text-dim"><span className="mr-1.5 font-mono text-merge">+</span>{pro}</span>
          ))}
          {choice.cons.map((con) => (
            <span key={con} className="text-dim"><span className="mr-1.5 font-mono text-fail">−</span>{con}</span>
          ))}
        </span>
      ) : null}
    </label>
  );
}
