import { ChevronRight, Hourglass } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { GoalRefusal } from "./actions";
import { AnswerForm, answerKey, BLANK_ENTRY, Question, subjectOf, type Entry } from "./asks";
import { FeedbackForm, REASON } from "./decisions";
import { finishPkg, leaveGoal } from "./exits";
import { useKept } from "./kept";
import { span, unresolvedPkgs, type Ask, type Board, type Decision, type GoalView, type Liveness, type Role, type Terminal } from "./model";
import { useAct, type GoalStep } from "./operator";
import { DOT } from "./owner";
import { CiCell, OrgIcon, OUTCOME, Pip, reviewLabel } from "./parts";
import { Reveal } from "./reveal";
import type { Trouble } from "./trouble";

// Text and controls keep this inset from the screen's edges; cards run edge to edge behind them (`.phone` in fresh.css).
export const INSET = "pl-[var(--inset-l)] pr-[var(--inset-r)]";
// A card: full width, one hairline above and below, with a small gap to the next.
export const CARD = "border-y border-line bg-panel";

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
// `run` resolves with why the action was refused, which shows under the button, or with nothing.
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
      <button className={`h-11 rounded-md px-5 text-sm font-medium transition-[color,background-color,border-color,transform] active:scale-[0.98] disabled:opacity-50 motion-reduce:active:scale-100 ${armed ? ARMED[look] : LOOK[look]}`} disabled={busy} type="button" onClick={(event) => void press(event.currentTarget)}>
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
    <h2 className={`mb-2 mt-7 scroll-mt-[calc(env(safe-area-inset-top)+4rem)] text-[11px] font-semibold uppercase tracking-[0.14em] first:mt-4 ${INSET} ${tone}`} id={id}>
      {children}
      {count !== undefined ? ` · ${count}` : null}
    </h2>
  );
}

const ROLE: Record<Role, string> = { chief: "chief", architect: "architect", worker: "worker", card: "agent" };
const LIVENESS: Record<Liveness, string> = { live: "", unknown: "not answering", finished: "finished" };

// A terminal by what it is, never by its address: "Architect", "Worker", "Herdr chief". Empty when nobody said.
export function kindOf(terminal: Terminal | null) {
  if (!terminal?.role) return "";
  const kind = terminal.topic ? `${terminal.topic} ${ROLE[terminal.role]}` : ROLE[terminal.role];
  return kind[0].toUpperCase() + kind.slice(1);
}

// Who works on something, with the same dot as desktop: filled while live, a ring while not answering, a dash once finished.
export function Who({ terminal }: { terminal: Terminal | null }) {
  const kind = kindOf(terminal);
  if (!kind || !terminal) return null;
  const liveness = terminal.liveness;
  return (
    <span className={`flex items-center gap-2 text-xs ${liveness === "unknown" ? "text-checks" : "text-dim"}`}>
      {liveness ? <span aria-hidden className={DOT[liveness]} /> : null}
      {kind}
      {liveness && LIVENESS[liveness] ? ` · ${LIVENESS[liveness]}` : ""}
    </span>
  );
}


const drafted = (entry: Entry) => entry.text !== "" || entry.choice !== null;

// One question. Its answer form opens on Answer, or is already open while it holds a draft.
// Without `bare` it starts with the goal it is about, which opens that goal.
export function AskCard({ ask, at, bare = false, board, onOpen, ref, views }: { ask: Ask; at: number; bare?: boolean; board: Board; onOpen: (goalId: string) => void; ref?: (node: HTMLElement | null) => void; views: GoalView[] }) {
  const subject = subjectOf(ask, board, views);
  const [entered, update] = useKept(answerKey(ask.id), BLANK_ENTRY);
  const [open, setOpen] = useState(() => drafted(entered) || entered.busy || entered.failure !== null);
  const enter = (change: Partial<Entry>) => update((was) => ({ ...was, ...change }));
  const goal = subject.goalId;

  return (
    <li ref={ref} className={`${CARD} pb-4`} data-ask={ask.id}>
      {bare ? null : <Subject at={ask.from} now={at} org={subject.view?.goal.org ?? null} title={subject.title} onOpen={goal ? () => onOpen(goal) : undefined} />}
      <div className={`${INSET} ${bare ? "pt-3.5" : ""}`}>
        {subject.about ? <p className="text-sm text-dim">About: {subject.about}</p> : null}
        <Question touch text={ask.details ? `${ask.question}\n${ask.details}` : ask.question} />
        <Reveal show={!open}>
          <Tap className="items-start pt-3" label="Answer" run={() => setOpen(true)} />
        </Reveal>
        <Reveal show={open}>
          <AnswerForm touch ask={ask} entered={entered} onEnter={enter} />
        </Reveal>
      </div>
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
  const line = `flex min-h-11 w-full items-center gap-2 text-left text-sm font-medium text-dim ${INSET}`;
  return onOpen ? (
    <button aria-label={title} className={`${line} active:bg-white/[0.04]`} type="button" onClick={onOpen}>
      {body}
    </button>
  ) : (
    <p className={line}>{body}</p>
  );
}

// A product call to react to, or feedback on one that reached nobody.
export function DecisionCard({ at, bare = false, board, decision, onOpen }: { at: number; bare?: boolean; board: Board; decision: Decision; onOpen: (goalId: string) => void }) {
  const goal = board.goals.find((entry) => entry.id === decision.goalId);
  const said = [kindOf(decision.by), bare ? `${span(at - decision.at)} ago` : ""].filter(Boolean).join(" · ");

  return (
    <li className={`${CARD} pb-4 ${bare ? "pt-4" : ""}`}>
      {bare || !goal ? null : <Subject at={decision.at} now={at} org={goal.org} title={goal.title} onOpen={() => onOpen(goal.id)} />}
      <div className={INSET}>
        <p className={`text-[15px] leading-snug ${decision.state === "feedback" ? "text-dim" : "text-ink"}`}>{decision.text}</p>
        {decision.rationale ? <p className="mt-1 text-sm text-dim">{decision.rationale}</p> : null}
        {said ? <p className="mt-2 font-mono text-[11px] text-faint">{said}</p> : null}
        <Reaction decision={decision} />
      </div>
    </li>
  );
}

const NO_FEEDBACK = { writing: false, text: "" };

// Ack or feedback on a recorded call; for feedback that reached nobody, what it said and a way to clear it.
function Reaction({ decision }: { decision: Decision }) {
  const act = useAct();
  const [draft, update] = useKept(`feedback:${decision.id}`, NO_FEEDBACK);
  if (decision.state === "feedback") {
    const typing = decision.undelivered === "delivering";
    return (
      <div className="mt-3 rounded border border-line bg-bg/40 px-3 py-2 text-sm">
        <p className="text-[11px] font-semibold text-checks">{typing ? "Sending" : `Undelivered · ${decision.undelivered ? REASON[decision.undelivered] : ""}`}</p>
        <p className="mt-1 text-ink">“{decision.feedback}”</p>
        {typing ? null : <Tap className="mt-2 items-start" label="Dismiss" run={() => act({ kind: "dismiss_feedback", decisionId: decision.id }).then(() => null)} />}
      </div>
    );
  }
  if (draft.writing) {
    return (
      <div className="mt-3 grid">
        <FeedbackForm touch unnamed decision={decision} text={draft.text} onCancel={() => update(() => NO_FEEDBACK)} onText={(text) => update(() => ({ writing: true, text }))} />
      </div>
    );
  }
  return (
    <div className="mt-3 flex gap-2">
      <Tap className="flex-1" label="Ack" run={() => act({ kind: "ack", decisionId: decision.id }).then(() => null)} />
      <Tap className="flex-1" label="Feedback" look="quiet" run={() => update(() => ({ writing: true, text: "" }))} />
    </div>
  );
}

// Something broken or stuck, with what it is about and, where the operator can do something, the action.
export function TroubleCard({ at, onOpen, ref, trouble }: { at: number; onOpen: (goalId: string) => void; ref?: (node: HTMLElement | null) => void; trouble: Trouble }) {
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
  const line = `flex w-full items-start gap-3 pb-3 pt-3.5 text-left ${INSET}`;

  return (
    <li ref={ref} className={CARD} data-goal={trouble.kind === "unresolved" ? trouble.view.goal.id : undefined}>
      {goalId ? (
        <button className={`${line} active:bg-white/[0.03]`} type="button" onClick={() => onOpen(goalId)}>
          {body}
        </button>
      ) : (
        <div className={line}>{body}</div>
      )}
      <TroubleAction trouble={trouble} />
    </li>
  );
}

// What the operator can do about it from here: settle an unresolved goal, release a silent owner, finish a package waiting upstream.
function TroubleAction({ trouble }: { trouble: Trouble }) {
  const act = useAct();
  const step = useGoalStep();
  if (trouble.kind === "unresolved") {
    const goalId = trouble.view.goal.id;
    return (
      <div className={`pb-3.5 ${INSET}`}>
        <div className="flex gap-2">
          <Tap className="flex-1" confirm="Complete?" label="Complete" look="primary" run={async (button) => void (await step(goalId, "complete", button.closest<HTMLElement>("[data-goal]")))} />
          <Tap className="flex-1" confirm="Archive?" label="Archive" run={async (button) => void (await step(goalId, "archive", button.closest<HTMLElement>("[data-goal]")))} />
        </div>
        <GoalRefusal className="pt-2" goalId={goalId} />
      </div>
    );
  }
  if (trouble.kind === "silent" && trouble.pkg === null) {
    return (
      <div className={`flex pb-3.5 ${INSET}`}>
        <Tap className="flex-1" confirm="Release?" label="Release" run={() => act({ kind: "release", goalId: trouble.view.goal.id }).then(() => null)} />
      </div>
    );
  }
  if (trouble.kind === "waits") {
    const pkgId = trouble.pkg.id;
    return (
      <div className={`flex pb-3.5 ${INSET}`}>
        <Tap className="flex-1" confirm="Finish?" label="Finish" run={(button) => finishPkg(pkgId, button.closest("li"), () => act({ kind: "finish", pkgId }))} />
      </div>
    );
  }
  return null;
}

type Said = { mark: ReactNode; headline: string; under: string; reason: ReactNode; tone: string };
type Describe = { [K in Trouble["kind"]]: (trouble: Extract<Trouble, { kind: K }>, at: number) => Said };

const DESCRIBE: Describe = {
  ci: ({ pkg, view }) => {
    const review = pkg.review?.state === "findings" ? reviewLabel(pkg.review) : null;
    return { mark: <Pip failed stage="review_ci" />, headline: pkg.title, under: view.goal.title, tone: "text-fail", reason: <><CiCell ci="failing" />{review ? <span className={review.tone}>review {review.text}</span> : null}</> };
  },
  deploy: ({ env, view }) => ({ mark: <Pip failed stage="ended" />, headline: `${env} deploy failed`, under: view.goal.title, tone: "text-fail", reason: "The last merge did not deploy" }),
  card_ci: ({ card }) => ({ mark: <Pip failed stage="review_ci" />, headline: card.task, under: card.repo.split("/").pop() ?? "", tone: "text-fail", reason: <CiCell ci="failing" /> }),
  unresolved: ({ view }) => ({
    mark: <Pip stage="ended" />,
    headline: view.goal.title,
    under: "",
    tone: "text-dim",
    reason: unresolvedPkgs(view).map((pkg) => (
      <span key={pkg.id}>
        <span className="text-ink">{pkg.title}</span> <span className={pkg.outcome ? OUTCOME[pkg.outcome].tone : ""}>{pkg.outcome ? OUTCOME[pkg.outcome].label.toLowerCase() : ""}</span>
      </span>
    )),
  }),
  exited: ({ pkg, view }) => ({ mark: <Pip stage="implementing" />, headline: pkg.title, under: view.goal.title, tone: "text-checks", reason: "The worker finished without opening a PR" }),
  silent: ({ pkg, view }) => ({
    mark: <span className="mt-px size-2 rounded-full border border-checks" />,
    headline: pkg?.title ?? view.goal.title,
    under: pkg ? view.goal.title : "",
    tone: "text-checks",
    reason: `${kindOf(pkg ? pkg.owner : view.goal.owner) || "Its terminal"} stopped answering`,
  }),
  waits: ({ pkg, since, view }, at) => ({
    mark: <Hourglass aria-hidden className="size-3 text-checks" />,
    headline: pkg.title,
    under: view.goal.title,
    tone: "text-checks",
    reason: (
      <>
        <span>Waiting for {pkg.pr!.repo.split("/").pop()}#{pkg.pr!.number} to merge</span>
        <span className="whitespace-nowrap">· {span(at - since)}</span>
      </>
    ),
  }),
};

function describe(trouble: Trouble, at: number): Said {
  return (DESCRIBE[trouble.kind] as (entry: Trouble, at: number) => Said)(trouble, at);
}
