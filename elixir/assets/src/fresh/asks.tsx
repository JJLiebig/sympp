import { LoaderCircle } from "lucide-react";
import { useId, useLayoutEffect, useRef, useState } from "react";

import { answerAsk } from "./exits";
import { useKept } from "./kept";
import { span, type Ask, type Board, type Choice, type GoalView } from "./model";
import { Presence, useOpenWhenBrought } from "./motion";
import { REDIRECT, useAct, type Answer } from "./operator";
import { Fold, LINK } from "./parts";
import { PhaseBadge, reportFor } from "./report";
import { Reveal } from "./reveal";

// What the ask is about: its goal, with the package it names, or the card it came from.
export type Subject = { title: string; goalId: string | null; view: GoalView | null; repo: string; summary: string; about: string | null };

export function subjectOf(ask: Ask, board: Board, views: GoalView[]): Subject {
  const view = views.find((entry) => entry.goal.id === ask.goalId) ?? null;
  const goal = view?.goal ?? board.goals.find((entry) => entry.id === ask.goalId);
  if (goal) {
    const about = goal.pkgs.find((pkg) => pkg.id === ask.pkgId)?.title ?? null;
    return { title: goal.title, goalId: goal.id, view, repo: repoName(goal.repo), summary: view ? reportFor(view).brief : "", about };
  }
  const card = board.cards.find((entry) => entry.id === ask.cardId);
  return { title: card?.task ?? "", goalId: null, view: null, repo: repoName(card?.repo ?? ""), summary: "", about: null };
}

const repoName = (repo: string) => repo.split("/").pop() ?? "";

// Every question waiting on the operator, oldest first, each with its answer form.
// `onGoal` lifts the area filter before it goes to the ask's goal, which may be filtered out.
export function NeedsYou({ asks, at, board, onGoal, views }: { asks: Ask[]; at: number; board: Board; onGoal: (goalId: string) => void; views: GoalView[] }) {
  const sorted = [...asks].sort((left, right) => left.from - right.from);

  return (
    <Reveal className="mb-8" holds={asks.map((ask) => ask.id)} show={asks.length > 0}>
      <section id="needs-you">
        <h2 className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-you">Needs you · {asks.length}</h2>
        <ul className="divide-y divide-line border-y border-line">
          <Presence items={sorted} keyOf={(ask) => ask.id}>
            {({ item, key, ref }) => <AskItem key={key} ref={ref} ask={item} at={at} subject={subjectOf(item, board, views)} onGoal={onGoal} />}
          </Presence>
        </ul>
      </section>
    </Reveal>
  );
}

// A question lines up with the goals below: the chevron in the same gutter, the text under the title.
// Open, it says what it is about, then asks; folded, it keeps its title line and the question's first line.
// What was entered, and a send still under way or refused, survive folding.
function AskItem({ ask, at, onGoal, ref, subject }: { ask: Ask; at: number; onGoal: (goalId: string) => void; ref: (node: HTMLElement | null) => void; subject: Subject }) {
  const [open, setOpen] = useState(true);
  const [entered, update] = useKept(answerKey(ask.id), BLANK_ENTRY);
  const enter = (change: Partial<Entry>) => update((was) => ({ ...was, ...change }));
  useOpenWhenBrought(`ask:${ask.id}`, () => setOpen(true));

  return (
    <li ref={ref} className="py-4 pr-2" data-ask={ask.id}>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
        <div className="flex min-w-[min(100%,18rem)] flex-1 items-start gap-3">
          <Fold className="-mx-1" label="Question" open={open} onToggle={() => setOpen(!open)} />
          <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-3 gap-y-0.5">
            {subject.goalId ? (
              <button className={`min-w-0 max-w-full truncate text-left font-medium ${LINK}`} title="Go to the goal" type="button" onClick={() => onGoal(subject.goalId!)}>
                {subject.title}
              </button>
            ) : (
              <span className="min-w-0 max-w-full truncate font-medium">{subject.title}</span>
            )}
            {subject.view ? <PhaseBadge small view={subject.view} /> : null}
            {subject.repo ? <span className="min-w-0 truncate text-xs text-faint">· {subject.repo}</span> : null}
          </span>
        </div>
        <span className="ml-auto shrink-0 font-mono text-[11px] text-faint">{span(at - ask.from)} ago</span>
      </div>
      <Reveal className="pl-7" show={open}>
        {subject.summary ? (
          <p className="mt-1 truncate text-sm text-dim" title={subject.summary}>
            {subject.summary}
          </p>
        ) : null}
        {subject.about ? <p className="mt-1 text-sm text-dim">About: {subject.about}</p> : null}
        <Question text={ask.details ? `${ask.question}\n${ask.details}` : ask.question} />
        <AnswerForm ask={ask} entered={entered} onEnter={enter} />
      </Reveal>
      <Reveal className="pl-7" show={!open}>
        <p className={`mt-1 truncate text-[15px] leading-snug text-ink ${MEASURE}`}>{ask.question}</p>
      </Reveal>
    </li>
  );
}

// The question and its details read as one text. A long one shows four lines until "more" opens it.
export function Question({ text, touch = false }: { text: string; touch?: boolean }) {
  const [full, setFull] = useState(false);
  const [long, setLong] = useState(false);
  const shown = useRef<HTMLParagraphElement>(null);

  // Whether the clamp hides anything; checked again whenever the width changes the wrapping.
  useLayoutEffect(() => {
    const node = shown.current;
    if (!node) return undefined;
    const observer = new ResizeObserver(() => setLong(node.scrollHeight > node.clientHeight + 1));
    observer.observe(node);
    return () => observer.disconnect();
  }, [text]);

  return (
    <div className={`mt-2 ${MEASURE}`}>
      <p ref={shown} className={`whitespace-pre-line text-[15px] leading-snug text-ink wrap-break-word ${full ? "" : "line-clamp-4"}`}>
        {text}
      </p>
      {long || full ? (
        <button className={`text-xs text-dim ${touch ? "-mb-3 flex h-11 items-center pr-6" : "mt-0.5"} ${LINK}`} type="button" onClick={() => setFull(!full)}>
          {full ? "less" : "more"}
        </button>
      ) : null}
    </div>
  );
}

// The question and its answer share one measure, so the form lines up under the words it answers.
const MEASURE = "max-w-[46rem]";

// What has been entered: the picked choice, if any, and the text; and whether it is being sent or was refused.
// Shared by the desktop and phone forms, so a draft survives the board changing layout.
export const BLANK_ENTRY: Entry = { choice: null, text: "", busy: false, failure: null };
export const answerKey = (askId: string) => `ask:${askId}`;
export type Entry = { choice: string | null; text: string; busy: boolean; failure: string | null };

// A free answer, or one of the asker's choices with an optional note, in one frame: the choices, then the note
// and Send. The asker may also offer to take a free answer instead of its choices; the note is then the answer.
// Sending plays the checkmark on the question; a refusal plays it back, and keeps what was entered.
const FORM_SIZE = { pointer: { text: "min-h-8 text-sm", send: "h-8 px-3.5" }, touch: { text: "min-h-11 text-base", send: "h-11 px-5" } };

// `touch` sizes the controls for a finger.
export function AnswerForm({ ask, entered, onEnter, touch }: { ask: Ask; entered: Entry; onEnter: (change: Partial<Entry>) => void; touch?: boolean }) {
  const act = useAct();
  const id = useId();
  const form = useRef<HTMLFormElement>(null);
  const { busy, choice, failure, text } = entered;
  const chosen = ask.choices.length > 0;
  const redirecting = choice === REDIRECT;
  // With a choice the text is a note, unless the choice is to answer in free text.
  const noting = chosen && !redirecting;
  const { answer, ready } = draft(chosen, choice, text.trim());
  const choices = ask.redirect ? [...ask.choices, { id: REDIRECT, label: ask.redirect, description: null, pros: [], cons: [] }] : ask.choices;
  const size = FORM_SIZE[touch ? "touch" : "pointer"];

  const submit = async () => {
    if (!ready || busy) return;
    onEnter({ busy: true, failure: null });
    const refusal = await answerAsk(ask.id, form.current?.closest<HTMLElement>("[data-ask]") ?? null, () => act({ kind: "answer", askId: ask.id, answer }));
    if (refusal === null) return;
    onEnter({ busy: false, failure: refusal });
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
              <ChoiceOption key={entry.id} touch={touch} choice={entry} group={id} picked={choice === entry.id} plain={entry.id === REDIRECT} onPick={() => onEnter({ choice: entry.id })} />
            ))}
          </fieldset>
        ) : null}
        <div className="flex items-end gap-2 p-1.5 pl-3.5">
          <label className="sr-only" htmlFor={`${id}-text`}>{noting ? "Note" : "Answer"}</label>
          <textarea
            aria-invalid={failure ? true : undefined}
            className={`max-h-48 flex-1 ${size.text} resize-none bg-transparent py-1.5 leading-5 text-ink outline-none field-sizing-content placeholder:text-faint disabled:text-dim`}
            disabled={busy}
            id={`${id}-text`}
            placeholder={placeholderFor(noting, redirecting)}
            rows={1}
            value={text}
            onChange={(event) => onEnter({ text: event.target.value })}
            onKeyDown={(event) => {
              if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) void submit();
            }}
          />
          <button
            className={`flex shrink-0 items-center gap-1.5 rounded-md ${size.send} text-sm font-semibold transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-you enabled:bg-you enabled:text-bg enabled:hover:bg-you/90 disabled:bg-line disabled:text-faint`}
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
function ChoiceOption({ choice, group, onPick, picked, plain, touch }: { choice: Choice; group: string; onPick: () => void; picked: boolean; plain?: boolean; touch?: boolean }) {
  const detailed = choice.description || choice.pros.length > 0 || choice.cons.length > 0;
  return (
    <label className={`relative flex cursor-pointer gap-3 px-3.5 ${touch ? "min-h-12 py-3" : "py-2.5"} text-sm transition-colors has-[:disabled]:cursor-default has-[:focus-visible]:outline-2 has-[:focus-visible]:-outline-offset-2 has-[:focus-visible]:outline-you/70 ${picked ? "bg-you/[0.1]" : "hover:bg-white/[0.03]"}`}>
      <input checked={picked} className="absolute inset-0 size-full cursor-pointer appearance-none opacity-0 disabled:cursor-default" name={group} type="radio" onChange={onPick} />
      <span aria-hidden className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-full border transition-colors ${picked ? "border-you" : "border-faint"}`}>
        <span className={`size-2 rounded-full bg-you transition-transform duration-150 motion-reduce:transition-none ${picked ? "scale-100" : "scale-0"}`} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-baseline gap-x-2">
          <span className={`font-medium leading-5 ${picked || !plain ? "text-ink" : "text-dim"}`}>{choice.label}</span>
          {choice.recommended ? <span className="text-xs text-dim">Recommended</span> : null}
        </span>
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
