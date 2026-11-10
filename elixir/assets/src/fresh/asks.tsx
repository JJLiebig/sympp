import { LoaderCircle } from "lucide-react";
import { useId, useRef, useState } from "react";

import { answerAsk } from "./exits";
import { span, type Ask, type Board, type Choice } from "./model";
import { Presence } from "./motion";
import { REDIRECT, useAct, type Answer } from "./operator";
import { Owner } from "./owner";
import { Reveal } from "./reveal";

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
  const sorted = [...asks].sort((left, right) => left.from - right.from);

  return (
    <Reveal className="mb-8" holds={asks.map((ask) => ask.id)} show={asks.length > 0}>
      <section id="needs-you">
        <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-you">Needs you · {asks.length}</h2>
        <ul className="divide-y divide-line border-y border-line">
          <Presence items={sorted} keyOf={(ask) => ask.id}>
            {({ item, key, ref }) => <AskItem key={key} ref={ref} ask={item} at={at} board={board} onGoal={onGoal} />}
          </Presence>
        </ul>
      </section>
    </Reveal>
  );
}

function AskItem({ ask, at, board, onGoal, ref }: { ask: Ask; at: number; board: Board; onGoal: (goalId: string) => void; ref: (node: HTMLElement | null) => void }) {
  const subject = subjectOf(ask, board);

  return (
    <li ref={ref} className="py-4 pr-2" data-ask={ask.id}>
      <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
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
        <p className="flex shrink-0 items-center gap-3">
          <Owner owner={ask.by} />
          <span className="font-mono text-[11px] text-faint">{span(at - ask.from)} ago</span>
        </p>
      </div>
      <div className={`mt-2 ${MEASURE}`}>
        <p className="text-[15px] leading-snug text-ink">{ask.question}</p>
        {ask.details ? <p className="mt-1 text-sm leading-snug text-dim">{ask.details}</p> : null}
      </div>
      <AnswerForm ask={ask} />
    </li>
  );
}

// The question and its answer share one measure, so the form lines up under the words it answers.
const MEASURE = "max-w-[46rem]";

// A free answer, or one of the asker's choices with an optional note, in one frame: the choices, then the note
// and Send. The asker may also offer to take a free answer instead of its choices; the note is then the answer.
// Sending plays the checkmark on the question; a refusal plays it back, and keeps what was entered.
function AnswerForm({ ask }: { ask: Ask }) {
  const act = useAct();
  const id = useId();
  const form = useRef<HTMLFormElement>(null);
  const [choice, setChoice] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const chosen = ask.choices.length > 0;
  const redirecting = choice === REDIRECT;
  // With a choice the text is a note, unless the choice is to answer in free text.
  const noting = chosen && !redirecting;
  const { answer, ready } = draft(chosen, choice, text.trim());
  const choices = ask.redirect ? [...ask.choices, { id: REDIRECT, label: ask.redirect, description: null, pros: [], cons: [] }] : ask.choices;

  const submit = async () => {
    if (!ready || busy) return;
    setBusy(true);
    setFailure(null);
    const refusal = await answerAsk(ask.id, form.current?.closest<HTMLElement>("[data-ask]") ?? null, () => act({ kind: "answer", askId: ask.id, answer }));
    if (refusal === null) return;
    setFailure(refusal);
    setBusy(false);
  };

  return (
    <form
      ref={form}
      className={`mt-3 ${MEASURE}`}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <div className={`overflow-hidden rounded-lg border bg-panel transition-colors ${failure ? "border-fail has-[textarea:focus]:ring-2 has-[textarea:focus]:ring-fail/35" : "border-line has-[textarea:focus]:border-you/70"}`}>
        {chosen ? (
          <fieldset className="divide-y divide-line border-b border-line" disabled={busy}>
            <legend className="sr-only">{ask.question}</legend>
            {choices.map((entry) => (
              <ChoiceOption key={entry.id} choice={entry} group={id} picked={choice === entry.id} plain={entry.id === REDIRECT} onPick={() => setChoice(entry.id)} />
            ))}
          </fieldset>
        ) : null}
        <div className="flex items-end gap-2 p-1.5 pl-3.5">
          <label className="sr-only" htmlFor={`${id}-text`}>{noting ? "Note" : "Answer"}</label>
          <textarea
            aria-invalid={failure ? true : undefined}
            className="max-h-48 min-h-8 flex-1 resize-none bg-transparent py-1.5 text-sm leading-5 text-ink outline-none field-sizing-content placeholder:text-faint disabled:text-dim"
            disabled={busy}
            id={`${id}-text`}
            placeholder={placeholderFor(noting, redirecting)}
            rows={1}
            value={text}
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) void submit();
            }}
          />
          <button
            className="flex h-8 shrink-0 items-center gap-1.5 rounded-md px-3.5 text-sm font-semibold transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-you enabled:bg-you enabled:text-bg enabled:hover:bg-you/90 disabled:bg-line disabled:text-faint"
            disabled={busy || !ready}
            type="submit"
          >
            {busy ? <LoaderCircle aria-hidden className="size-3.5 animate-spin motion-reduce:animate-none" /> : null}
            {busy ? "Sending" : "Send"}
          </button>
        </div>
      </div>
      {failure ? (
        <p className="mt-1.5 text-xs text-fail" role="alert">
          {failure}
        </p>
      ) : null}
    </form>
  );
}

function placeholderFor(noting: boolean, redirecting: boolean) {
  if (noting) return "Add a note (optional)";
  return redirecting ? "Say what to do instead" : "Your answer";
}

// What the form would send, and whether it is complete: a choice, a free-text choice with its text, or free text.
function draft(chosen: boolean, choice: string | null, text: string): { answer: Answer; ready: boolean } {
  if (!chosen) return { answer: { text }, ready: text !== "" };
  return { answer: { choice: choice ?? "", note: text }, ready: choice !== null && (choice !== REDIRECT || text !== "") };
}

// One choice as a row of the form: a radio, the label, and what speaks for and against it. Arrow keys move
// between the rows of one question, as with any radio group.
function ChoiceOption({ choice, group, onPick, picked, plain }: { choice: Choice; group: string; onPick: () => void; picked: boolean; plain?: boolean }) {
  const detailed = choice.description || choice.pros.length > 0 || choice.cons.length > 0;
  return (
    <label className={`relative flex cursor-pointer gap-3 px-3.5 py-2.5 text-sm transition-colors has-[:disabled]:cursor-default has-[:focus-visible]:outline-2 has-[:focus-visible]:-outline-offset-2 has-[:focus-visible]:outline-you/70 ${picked ? "bg-you/[0.1]" : "hover:bg-white/[0.03]"}`}>
      <input checked={picked} className="absolute inset-0 size-full cursor-pointer appearance-none opacity-0 disabled:cursor-default" name={group} type="radio" onChange={onPick} />
      <span aria-hidden className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-full border transition-colors ${picked ? "border-you" : "border-faint"}`}>
        <span className={`size-2 rounded-full bg-you transition-transform duration-150 motion-reduce:transition-none ${picked ? "scale-100" : "scale-0"}`} />
      </span>
      <span className="min-w-0 flex-1">
        <span className={`block font-medium leading-5 ${picked || !plain ? "text-ink" : "text-dim"}`}>{choice.label}</span>
        {detailed ? (
          <span className="mt-1 grid gap-0.5 text-xs leading-[1.125rem] text-dim">
            {choice.description ? <span>{choice.description}</span> : null}
            {choice.pros.map((pro) => (
              <span key={pro} className="flex gap-1.5">
                <span aria-label="For" className="w-2 shrink-0 font-mono text-merge">+</span>
                {pro}
              </span>
            ))}
            {choice.cons.map((con) => (
              <span key={con} className="flex gap-1.5">
                <span aria-label="Against" className="w-2 shrink-0 font-mono text-fail">−</span>
                {con}
              </span>
            ))}
          </span>
        ) : null}
      </span>
    </label>
  );
}
