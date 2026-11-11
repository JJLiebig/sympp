import { ChevronRight, Hourglass } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { GoalRefusal } from "./actions";
import { AnswerForm, Question, subjectOf, type Entry } from "./asks";
import { FeedbackForm, REASON } from "./decisions";
import { finishPkg, leaveGoal } from "./exits";
import { span, unresolvedPkgs, type Ask, type Board, type Decision, type GoalView } from "./model";
import { useAct, type GoalStep } from "./operator";
import { Owner } from "./owner";
import { CiCell, OrgIcon, OUTCOME, Pip, reviewLabel } from "./parts";
import type { Trouble } from "./trouble";

// Every control on the phone is at least 44px tall, the height of a fingertip.
const LOOK = {
  primary: "bg-ink font-semibold text-bg",
  plain: "border border-line text-ink",
  danger: "border border-fail/40 text-fail",
  quiet: "text-dim",
};
const ARMED = { primary: "bg-you font-semibold text-bg", plain: "border border-ink/60 bg-line text-ink", danger: "border border-fail bg-fail/15 text-fail", quiet: "bg-line text-ink" };
const ARM_MS = 4000;

// A button for one action. With `confirm` the first tap arms it and a second tap within a few seconds runs it.
// `run` resolves with why the action was refused, which shows under the button, or null.
export function Tap({ className = "", confirm, label, look = "plain", run }: { className?: string; confirm?: string; label: string; look?: keyof typeof LOOK; run: (button: HTMLButtonElement) => Promise<string | null | void> | void }) {
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  useEffect(() => {
    if (!armed) return undefined;
    const timer = window.setTimeout(() => setArmed(false), ARM_MS);
    return () => window.clearTimeout(timer);
  }, [armed]);

  const press = async (button: HTMLButtonElement) => {
    if (confirm && !armed) return setArmed(true);
    setArmed(false);
    setBusy(true);
    setFailure(null);
    const refusal = await Promise.resolve(run(button)).catch((caught: unknown) => (caught instanceof Error ? caught.message : "The backend refused this."));
    setBusy(false);
    setFailure(refusal ?? null);
  };

  return (
    <span className={`flex min-w-0 flex-col gap-1 ${className}`}>
      <button className={`h-11 rounded-md px-4 text-sm font-medium transition-[color,background-color,border-color,transform] active:scale-[0.98] disabled:opacity-50 motion-reduce:active:scale-100 ${armed ? ARMED[look] : LOOK[look]}`} disabled={busy} type="button" onClick={(event) => void press(event.currentTarget)}>
        {armed ? confirm : label}
      </button>
      {failure ? (
        <span className="text-xs text-fail" role="alert">
          {failure}
        </span>
      ) : null}
    </span>
  );
}

// Completing, archiving, restoring or deleting a goal, played on `node`. Resolves true once the factory agreed;
// a refusal shows wherever the goal's GoalRefusal is.
export function useGoalStep() {
  const act = useAct();
  return (goalId: string, step: GoalStep, node: HTMLElement | null) => leaveGoal(goalId, step, node, () => act({ kind: "goal", goalId, step }));
}

export function Heading({ children, count, id, tone = "text-faint" }: { children: ReactNode; count?: number; id?: string; tone?: string }) {
  return (
    <h2 className={`mb-2 mt-7 scroll-mt-[calc(env(safe-area-inset-top)+4rem)] px-1 text-[11px] font-semibold uppercase tracking-[0.14em] first:mt-4 ${tone}`} id={id}>
      {children}
      {count !== undefined ? ` · ${count}` : null}
    </h2>
  );
}

const CARD = "rounded-lg border border-line bg-panel";

// What was entered in a question survives leaving the screen, as it survives folding on desktop.
const drafts = new Map<string, Entry>();
const BLANK: Entry = { choice: null, text: "", busy: false, failure: null };

// One question with its answer form. Without `bare` it starts with the goal it is about, which opens that goal.
export function AskCard({ ask, at, bare = false, board, onOpen, ref, views }: { ask: Ask; at: number; bare?: boolean; board: Board; onOpen: (goalId: string) => void; ref?: (node: HTMLElement | null) => void; views: GoalView[] }) {
  const subject = subjectOf(ask, board, views);
  const [entered, setEntered] = useState<Entry>(() => drafts.get(ask.id) ?? BLANK);
  const enter = (change: Partial<Entry>) =>
    setEntered((was) => {
      const next = { ...was, ...change };
      drafts.set(ask.id, { ...next, busy: false });
      return next;
    });

  return (
    <li ref={ref} className={`${CARD} px-4 pb-4 pt-1`} data-ask={ask.id}>
      {bare ? (
        <p className="pt-3 font-mono text-[11px] text-faint">{span(at - ask.from)} ago</p>
      ) : (
        <Subject at={ask.from} now={at} org={subject.view?.goal.org ?? null} title={subject.title} onOpen={subject.goalId ? () => onOpen(subject.goalId!) : undefined} />
      )}
      {subject.about ? <p className="mt-1 text-sm text-dim">About: {subject.about}</p> : null}
      <Question touch text={ask.details ? `${ask.question}\n${ask.details}` : ask.question} />
      <AnswerForm touch ask={ask} entered={entered} onEnter={enter} />
    </li>
  );
}

// The goal a card is about, on one tappable line, with how long ago it was raised.
function Subject({ at, now, onOpen, org, title }: { at: number; now: number; onOpen?: () => void; org: string | null; title: string }) {
  const body = (
    <>
      <span className="min-w-0 flex-1 truncate">
        <OrgIcon org={org} /> {title}
      </span>
      <span className="shrink-0 font-mono text-[11px] text-faint">{span(now - at)} ago</span>
      {onOpen ? <ChevronRight aria-hidden className="size-4 shrink-0 text-faint" /> : null}
    </>
  );
  const line = "-mx-1 flex min-h-11 w-[calc(100%+0.5rem)] items-center gap-2 rounded px-1 text-left text-sm font-medium text-dim";
  return onOpen ? (
    <button className={`${line} active:bg-white/[0.04]`} type="button" onClick={onOpen}>
      {body}
    </button>
  ) : (
    <p className={line}>{body}</p>
  );
}

// A product call to react to, or feedback on one that reached nobody.
export function DecisionCard({ at, bare = false, board, decision, onOpen }: { at: number; bare?: boolean; board: Board; decision: Decision; onOpen: (goalId: string) => void }) {
  const act = useAct();
  const [writing, setWriting] = useState(false);
  const goal = board.goals.find((entry) => entry.id === decision.goalId);
  const undelivered = decision.state === "feedback";
  const typing = decision.undelivered === "delivering";

  return (
    <li className={`${CARD} px-4 pb-4 ${bare ? "pt-4" : "pt-1"}`}>
      {bare ? null : <Subject at={decision.at} now={at} org={goal?.org ?? null} title={goal?.title ?? ""} onOpen={goal ? () => onOpen(goal.id) : undefined} />}
      <p className={`text-[15px] leading-snug ${undelivered ? "text-dim" : "text-ink"}`}>{decision.text}</p>
      {decision.rationale ? <p className="mt-1 text-sm text-dim">{decision.rationale}</p> : null}
      <p className="mt-2 flex items-center gap-2 text-faint">
        <Owner owner={decision.by} />
        {bare ? <span className="font-mono text-[11px]">· {span(at - decision.at)} ago</span> : null}
      </p>
      {undelivered ? (
        <div className="mt-3 rounded border border-line bg-bg/40 px-3 py-2 text-sm">
          <p className="text-[11px] font-semibold text-checks">{typing ? "Sending" : `Undelivered · ${decision.undelivered ? REASON[decision.undelivered] : ""}`}</p>
          <p className="mt-1 text-ink">“{decision.feedback}”</p>
          {typing ? null : <Tap className="mt-2" label="Dismiss" look="plain" run={() => act({ kind: "dismiss_feedback", decisionId: decision.id }).then(() => null)} />}
        </div>
      ) : writing ? (
        <div className="mt-3 grid">
          <FeedbackForm touch decision={decision} onCancel={() => setWriting(false)} />
        </div>
      ) : (
        <div className="mt-3 flex gap-2">
          <Tap className="flex-1" label="Ack" look="plain" run={() => act({ kind: "ack", decisionId: decision.id }).then(() => null)} />
          <Tap className="flex-1" label="Feedback" look="quiet" run={() => setWriting(true)} />
        </div>
      )}
    </li>
  );
}

// Something broken or stuck, with what it is about and, where the operator can do something, the action.
export function TroubleCard({ at, onOpen, ref, trouble }: { at: number; onOpen: (goalId: string) => void; ref?: (node: HTMLElement | null) => void; trouble: Trouble }) {
  const act = useAct();
  const step = useGoalStep();
  const said = describe(trouble, at);
  const goalId = "view" in trouble ? trouble.view.goal.id : null;
  const body = (
    <>
      <span className="mt-1.5 flex">{said.mark}</span>
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium leading-snug text-ink [overflow-wrap:anywhere]">{said.headline}</span>
        {said.under ? <span className="mt-0.5 block truncate text-xs text-faint">{said.under}</span> : null}
        <span className={`mt-1.5 flex flex-wrap items-center gap-x-2 text-xs ${said.tone}`}>{said.reason}</span>
      </span>
      {goalId ? <ChevronRight aria-hidden className="mt-0.5 size-4 shrink-0 text-faint" /> : null}
    </>
  );
  const line = "flex w-full items-start gap-3 px-4 pb-3 pt-3.5 text-left";

  return (
    <li ref={ref} className={CARD} data-goal={trouble.kind === "unresolved" ? trouble.view.goal.id : undefined}>
      {goalId ? (
        <button className={`${line} rounded-lg active:bg-white/[0.03]`} type="button" onClick={() => onOpen(goalId)}>
          {body}
        </button>
      ) : (
        <div className={line}>{body}</div>
      )}
      {trouble.kind === "unresolved" ? (
        <div className="flex gap-2 px-4 pb-3.5">
          {(["complete", "archive"] as const).map((key) => (
            <Tap key={key} className="flex-1" confirm={key === "complete" ? "Complete?" : "Archive?"} label={key === "complete" ? "Complete" : "Archive"} look={key === "complete" ? "primary" : "plain"} run={async (button) => void (await step(trouble.view.goal.id, key, button.closest<HTMLElement>("[data-goal]")))} />
          ))}
        </div>
      ) : null}
      {trouble.kind === "unresolved" ? <GoalRefusal className="px-4 pb-3.5" goalId={trouble.view.goal.id} /> : null}
      {trouble.kind === "silent" && trouble.pkg === null ? (
        <div className="flex px-4 pb-3.5">
          <Tap className="flex-1" confirm="Release?" label="Release" run={() => act({ kind: "release", goalId: trouble.view.goal.id }).then(() => null)} />
        </div>
      ) : null}
      {trouble.kind === "waits" ? (
        <div className="flex px-4 pb-3.5">
          <Tap className="flex-1" confirm="Finish?" label="Finish" run={(button) => finishPkg(trouble.pkg.id, button.closest("li"), () => act({ kind: "finish", pkgId: trouble.pkg.id }))} />
        </div>
      ) : null}
    </li>
  );
}

function describe(trouble: Trouble, at: number): { mark: ReactNode; headline: string; under: string; reason: ReactNode; tone: string } {
  switch (trouble.kind) {
    case "ci": {
      const review = trouble.pkg.review?.state === "findings" ? reviewLabel(trouble.pkg.review) : null;
      return { mark: <Pip failed stage="review_ci" />, headline: trouble.pkg.title, under: trouble.view.goal.title, tone: "text-fail", reason: <><CiCell ci="failing" />{review ? <span className={review.tone}>review {review.text}</span> : null}</> };
    }
    case "deploy":
      return { mark: <Pip failed stage="ended" />, headline: `${trouble.env} deploy failed`, under: trouble.view.goal.title, tone: "text-fail", reason: "The last merge did not deploy" };
    case "card_ci":
      return { mark: <Pip failed stage="review_ci" />, headline: trouble.card.task, under: trouble.card.repo.split("/").pop() ?? "", tone: "text-fail", reason: <CiCell ci="failing" /> };
    case "unresolved":
      return {
        mark: <Pip stage="ended" />,
        headline: trouble.view.goal.title,
        under: "",
        tone: "text-dim",
        reason: unresolvedPkgs(trouble.view).map((pkg) => (
          <span key={pkg.id}>
            <span className="text-ink">{pkg.title}</span> <span className={pkg.outcome ? OUTCOME[pkg.outcome].tone : ""}>{pkg.outcome ? OUTCOME[pkg.outcome].label.toLowerCase() : ""}</span>
          </span>
        )),
      };
    case "exited":
      return { mark: <Pip stage="implementing" />, headline: trouble.pkg.title, under: trouble.view.goal.title, tone: "text-checks", reason: "The worker finished without opening a PR" };
    case "silent": {
      const who = trouble.pkg ? trouble.pkg.owner : trouble.view.goal.owner;
      return { mark: <span className="mt-px size-2 rounded-full border border-checks" />, headline: trouble.pkg?.title ?? trouble.view.goal.title, under: trouble.pkg ? trouble.view.goal.title : "", tone: "text-checks", reason: `${who?.address ?? "Its terminal"} stopped answering` };
    }
    case "waits": {
      const pr = trouble.pkg.pr!;
      return {
        mark: <Hourglass aria-hidden className="size-3 text-checks" />,
        headline: trouble.pkg.title,
        under: trouble.view.goal.title,
        tone: "text-checks",
        reason: (
          <>
            <span>Waiting for {pr.repo.split("/").pop()}#{pr.number} to merge</span>
            <span className="whitespace-nowrap">· {span(at - trouble.since)}</span>
          </>
        ),
      };
    }
  }
}
