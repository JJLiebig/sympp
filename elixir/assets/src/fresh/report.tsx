import { Check, Circle, type LucideIcon } from "lucide-react";
import { createContext, useContext, useState, type KeyboardEvent, type MouseEvent } from "react";

import { ActButton } from "./actions";
import { span, waitsOnOthers, type Goal, type Phase as GoalPhase, type GoalView, type Pkg, type PkgView, type Stage } from "./model";
import { GLOW, NUDGE, smoothly, spotlight, useFlash } from "./motion";
import { Owner } from "./owner";
import { CiCell, OUTCOME, Pip, PKG_GRID, PrLink, ReviewCell, StageLabel, StageSteps, StageTime } from "./parts";
import { sampleReport } from "./samples";

// What a goal says when asked "is this coming along?". The architect owns the words and the ETA;
// the ledger only supplies the verdict's facts. The verdict orders the board; the badge shows the phase.
export type Verdict = "needs_you" | "parked" | GoalPhase;
// `briefAt` is when the architect wrote the brief; null where the wording is not the architect's.
export type Report = { verdict: Verdict; brief: string; briefAt: number | null; eta: string | null; sample: boolean };
// A phase is the first part of the packages' group paths. `pkgs` covers everything beneath it; `subs` are the deeper paths, in order.
export type Phase = { id: string; title: string; pkgs: Pkg[]; subs: Array<{ id: string; title: string; pkgs: Pkg[] }> };
export type PhaseStatus = "done" | "active" | "waiting" | "upcoming";
export type PhaseState = { phase: Phase; live: PkgView[]; queued: Pkg[]; done: Pkg[]; status: PhaseStatus };
export type Density = "closed" | "attention" | "active" | "open";
// How much of one goal is on screen: its headline, what is moving now, or done, now and up next.
export type Level = "closed" | "now" | "full";
export type PhaseControl = { all: boolean; isOpen: (state: PhaseState) => boolean; open: (state: PhaseState) => void; setAll: (all: boolean) => void; toggle: (state: PhaseState) => void };

const FOLD_AFTER = 2;
const ROW = `${PKG_GRID} rounded px-2 py-1 odd:bg-white/[0.035]`;

export const PHASE: Record<GoalPhase | "parked", { label: string; text: string; dot: string }> = {
  intake: { label: "Intake", text: "text-faint", dot: "border border-faint" },
  planned: { label: "Planned", text: "text-dim", dot: "border border-dim" },
  active: { label: "Active", text: "text-build", dot: "bg-build" },
  unresolved: { label: "Unresolved", text: "text-checks", dot: "bg-checks" },
  done: { label: "Done", text: "text-merge", dot: "bg-merge" },
  archived: { label: "Archived", text: "text-faint", dot: "bg-faint" },
  parked: { label: "Parked", text: "text-faint", dot: "bg-faint" },
};

// "active" shows what is moving in every goal; "attention" opens only the goals that deviate from plan.
export const DensityContext = createContext<Density>("active");

// The verdicts that deviate from plan and should be seen first.
export function wantsAttention(verdict: Verdict) {
  return verdict === "needs_you" || verdict === "unresolved";
}

function defaultLevel(density: Density, verdict: Verdict): Level {
  if (density === "open") return "full";
  if (density === "active") return "now";
  return density === "attention" && wantsAttention(verdict) ? "full" : "closed";
}

// A goal follows the chosen density until it is opened or closed by hand.
export function useGoalLevel(verdict: Verdict) {
  const density = useContext(DensityContext);
  const [override, setOverride] = useState<{ density: Density; level: Level } | null>(null);
  const level = override?.density === density ? override.level : defaultLevel(density, verdict);
  const reopened: Level = density === "active" ? "now" : "full";

  return {
    level,
    showAll: () => smoothly(() => setOverride({ density, level: "full" })),
    toggle: () => smoothly(() => setOverride({ density, level: level === "closed" ? reopened : "closed" })),
  };
}

// Which phases of one goal are opened. A phase with work in progress is open unless closed by hand.
export function usePhaseControl(): PhaseControl {
  const [overrides, setOverrides] = useState<Record<string, boolean>>({});
  const [all, setAllState] = useState(false);
  const isOpen = (state: PhaseState) => overrides[state.phase.id] ?? (all || state.status === "active");

  return {
    all,
    isOpen,
    open: (state) => smoothly(() => setOverrides({ ...overrides, [state.phase.id]: true })),
    setAll: (next) =>
      smoothly(() => {
        setOverrides({});
        setAllState(next);
      }),
    toggle: (state) => smoothly(() => setOverrides({ ...overrides, [state.phase.id]: !isOpen(state) })),
  };
}

export function reportFor(view: GoalView): Report {
  const verdict = verdictFor(view);
  const written = view.goal.report;
  if (written?.brief) return { verdict, brief: written.brief.text, briefAt: written.brief.at, eta: written.eta?.text ?? null, sample: false };

  const sample = sampleReport(view.goal.title, verdict === "active");
  return { verdict, brief: sample?.brief ?? draftBrief(view), briefAt: null, eta: written?.eta?.text ?? sample?.eta ?? null, sample: Boolean(sample) };
}

// How old the architect's brief is, so a stale one is not read as news.
export function BriefAge({ at, report }: { at: number; report: Report }) {
  if (report.briefAt === null) return null;
  return <span className="ml-2 whitespace-nowrap font-mono text-[11px] text-faint" title="When the architect wrote this">{span(at - report.briefAt)} ago</span>;
}

function verdictFor(view: GoalView): Verdict {
  if (view.ask) return "needs_you";
  if (view.goal.report?.parked && view.phase !== "done" && view.phase !== "archived") return "parked";
  return view.phase;
}

// Fallback wording from ledger counts, used where no architect brief exists.
function draftBrief(view: GoalView) {
  if (view.goal.report?.parked) return `Parked: ${view.goal.report.parked.text}`;
  const total = view.live.length + view.queued.length + view.done.length;
  if (view.phase === "intake") return "Not sliced yet.";
  if (view.phase === "done" || view.phase === "archived") return `All ${total} packages have ended.`;
  if (view.phase === "unresolved") return "Every package has ended, but not all of them landed.";
  if (view.live.length === 0) return `Between packages: ${view.done.length} of ${total} have ended, ${view.queued.length} up next.`;
  return `${view.live.length} of ${total} packages are moving. ${view.done.length} have ended.`;
}

const SPLIT = /\s*\/\s*/;

// Phases exist only where the architect grouped the work: "Backend / Billing" nests Billing under Backend.
export function phasesOf(goal: Goal): Phase[] {
  if (!goal.pkgs.some((pkg) => pkg.group)) return [];
  const tops = new Map<string, Pkg[]>();
  const loose: Pkg[] = [];
  for (const pkg of [...goal.pkgs].sort((left, right) => left.seq - right.seq)) {
    const top = pkg.group?.split(SPLIT)[0];
    if (top) tops.set(top, [...(tops.get(top) ?? []), pkg]);
    else loose.push(pkg);
  }
  const below = (pkg: Pkg) => (pkg.group ?? "").split(SPLIT).slice(1).join(" › ");
  const phases = [...tops].map(([title, pkgs]) => {
    const paths = [...new Set(pkgs.map(below).filter(Boolean))];
    return { id: title, title, pkgs, subs: paths.map((path) => ({ id: `${title}/${path}`, title: path, pkgs: pkgs.filter((pkg) => below(pkg) === path) })) };
  });
  return [...phases, ...(loose.length > 0 ? [{ id: "loose", title: "Other", subs: [], pkgs: loose }] : [])];
}

export function phaseStates(view: GoalView): PhaseState[] {
  return phasesOf(view.goal).map((phase) => phaseState(phase, view));
}

function phaseState(phase: Phase, view: GoalView): PhaseState {
  const ids = new Set(phase.pkgs.map((pkg) => pkg.id));
  const bySeq = (left: Pkg, right: Pkg) => left.seq - right.seq;
  const live = view.live.filter((entry) => ids.has(entry.pkg.id));
  const queued = view.queued.filter((pkg) => ids.has(pkg.id)).sort(bySeq);
  const done = view.done.filter((pkg) => ids.has(pkg.id)).sort(bySeq);
  const total = live.length + queued.length + done.length;
  const status = total === 0 ? "upcoming" : done.length === total ? "done" : live.length > 0 ? "active" : "waiting";
  return { phase, live, queued, done, status };
}

// A goal without groups still reads as finished work, work in progress and work to come.
function looseStates(view: GoalView): PhaseState[] {
  const part = (id: string, title: string, status: PhaseStatus, live: PkgView[], queued: Pkg[], done: Pkg[]): PhaseState => ({ phase: { id, title, pkgs: [], subs: [] }, live, queued, done, status });
  return [
    ...(view.done.length > 0 ? [part("done", "Ended packages", "done", [], [], view.done)] : []),
    ...(view.live.length > 0 ? [part("now", "", "active", view.live, [], [])] : []),
    ...(view.queued.length > 0 ? [part("next", "Planned packages", "waiting", [], view.queued, [])] : []),
  ];
}

// One dot per package in its planned order, with a gap between the architect's groups.
export function DotStrip({ view }: { view: GoalView }) {
  const phases = phaseStates(view);
  const whole: PhaseState = { phase: { id: "all", title: "", pkgs: [], subs: [] }, live: view.live, queued: view.queued, done: view.done, status: "active" };
  const runs = (phases.length > 0 ? phases : [whole]).filter((state) => state.live.length + state.queued.length + state.done.length > 0);

  return (
    <span className="flex flex-wrap items-center gap-y-1">
      {runs.map((state, index) => (
        <span key={state.phase.id} className={`flex items-center gap-0.5 ${index > 0 ? "ml-1.5 border-l border-faint pl-1.5" : ""}`} title={state.phase.title || undefined}>
          {orderedDots(state).map((dot) => (
            <span key={dot.id} title={dot.title}>
              <Pip stage={dot.stage} failed={dot.failed} />
            </span>
          ))}
        </span>
      ))}
    </span>
  );
}

function orderedDots(state: PhaseState) {
  const dots: Array<{ id: string; title: string; seq: number; stage: Stage; failed: boolean }> = [
    ...state.done.map((pkg) => ({ id: pkg.id, title: pkg.title, seq: pkg.seq, stage: "ended" as Stage, failed: false })),
    ...state.live.map((live) => ({ id: live.pkg.id, title: live.pkg.title, seq: live.pkg.seq, stage: live.stage, failed: live.failed })),
    ...state.queued.map((pkg) => ({ id: pkg.id, title: pkg.title, seq: pkg.seq, stage: "planned" as Stage, failed: false })),
  ];
  return dots.sort((left, right) => left.seq - right.seq);
}

const SECTIONS: Array<{ label: string; tone: string; keep: "first" | "last"; statuses: PhaseStatus[] }> = [
  { label: "Done", tone: "text-merge/80", keep: "last", statuses: ["done"] },
  { label: "Now", tone: "text-ink", keep: "first", statuses: ["active"] },
  { label: "Up next", tone: "text-dim", keep: "first", statuses: ["waiting", "upcoming"] },
];

// A goal's work in three parts that never mix: what is done, what is moving now, and what is up next.
// At the "now" level only the middle part shows, with the rest summed up on one line.
// Done and up-next phases are one line each until opened; long lists fold behind "more".
export function GoalPackages({ at, control, level, onFull, view }: { at: number; control?: PhaseControl; level: "now" | "full"; onFull: () => void; view: GoalView }) {
  const own = usePhaseControl();
  const phases = phaseStates(view);
  const states = phases.length > 0 ? phases : looseStates(view);
  const use = control ?? own;
  const sections = level === "full" ? SECTIONS : SECTIONS.filter((section) => section.label === "Now");
  const rest = [view.done.length > 0 ? `${view.done.length} ended` : "", view.queued.length > 0 ? `${view.queued.length} up next` : ""].filter(Boolean);
  const link = "px-2 font-mono text-xs text-dim underline-offset-4 hover:text-ink hover:underline";

  return (
    <div className="space-y-3">
      {sections.map((section) => (
        <Section key={section.label} at={at} control={use} section={section} states={states.filter((state) => section.statuses.includes(state.status))} />
      ))}
      {level === "full" ? (
        <button className={link} type="button" onClick={() => use.setAll(!use.all)}>
          {use.all ? "Show only what is moving" : `See all ${view.live.length + view.done.length + view.queued.length} packages`}
        </button>
      ) : null}
      {level === "now" && rest.length > 0 ? (
        <button className={link} type="button" onClick={onFull}>
          {rest.join(" · ")} · show
        </button>
      ) : null}
    </div>
  );
}

function Section({ at, control, section, states }: { at: number; control: PhaseControl; section: (typeof SECTIONS)[number]; states: PhaseState[] }) {
  const [unfolded, setUnfolded] = useState(false);
  if (states.length === 0) return null;

  const fold = section.label !== "Now" && !control.all && !unfolded && states.length > FOLD_AFTER;
  const kept = section.keep === "last" ? states.slice(-FOLD_AFTER) : states.slice(0, FOLD_AFTER);
  // A phase opened by hand stays visible even where the list is folded.
  const shown = fold ? states.filter((state) => kept.includes(state) || control.isOpen(state)) : states;
  const more = fold && shown.length < states.length ? (
    <button className="flex items-center gap-2 px-2 py-0.5 font-mono text-xs text-faint hover:text-ink" type="button" onClick={() => smoothly(() => setUnfolded(true))}>
      <span className="tracking-widest">···</span>
      {states.length - shown.length} more {section.keep === "last" ? "finished earlier" : "after that"}
    </button>
  ) : null;

  return (
    <div>
      <p className={`px-2 pb-0.5 text-[10px] font-semibold uppercase tracking-[0.16em] ${section.tone}`}>{section.label}</p>
      {section.keep === "last" ? more : null}
      {shown.map((state) => (
        <div key={state.phase.id}>
          {state.phase.title ? <PhaseRow control={control} state={state} /> : null}
          {control.isOpen(state) ? <PhasePackages at={at} state={state} all={control.all || state.status !== "active"} /> : null}
        </div>
      ))}
      {section.keep === "first" ? more : null}
    </div>
  );
}

const STATUS_META: Record<PhaseStatus, { icon: LucideIcon; tone: string; title: string; count: (state: PhaseState) => string }> = {
  done: { icon: Check, tone: "text-merge", title: "text-dim", count: (state) => `${state.done.length} ended` },
  active: { icon: Circle, tone: "fill-current text-build", title: "text-ink", count: (state) => `${state.done.length}/${state.live.length + state.queued.length + state.done.length}` },
  waiting: { icon: Circle, tone: "text-faint", title: "text-dim", count: (state) => `0/${state.queued.length}` },
  upcoming: { icon: Circle, tone: "text-faint", title: "text-dim", count: () => "not sliced yet" },
};

// One phase on one line: status on the left, name, and how much of it is done on the right.
export function PhaseRow({ control, state }: { control: PhaseControl; state: PhaseState }) {
  const meta = STATUS_META[state.status];
  const empty = state.status === "upcoming";

  return (
    <button className={`flex w-full items-center gap-3 rounded px-2 py-1 text-left text-sm ${empty ? "cursor-default" : "hover:bg-white/[0.05]"}`} disabled={empty} type="button" onClick={() => control.toggle(state)}>
      <meta.icon className={`size-2.5 shrink-0 ${meta.tone}`} />
      <span className={`min-w-0 flex-1 truncate font-medium ${meta.title}`}>{state.phase.title}</span>
      <span className="shrink-0 font-mono text-xs text-faint">{meta.count(state)}</span>
    </button>
  );
}

// A phase's packages. Deeper group paths appear as captions inside it; while only moving work is shown,
// a nested group is listed only if something in it is moving.
export function PhasePackages({ all, at, state }: { all: boolean; at: number; state: PhaseState }) {
  const subs = state.phase.subs.map((sub) => ({ ...sub, ids: new Set(sub.pkgs.map((pkg) => pkg.id)) }));
  const nested = new Set(subs.flatMap((sub) => [...sub.ids]));
  const shown = subs.filter((sub) => all || state.live.some((live) => sub.ids.has(live.pkg.id)));

  return (
    <div className="pl-5">
      <Lines all={all} at={at} keep={(id) => !nested.has(id)} state={state} />
      {shown.map((sub) => (
        <div key={sub.id}>
          <p className="flex items-baseline gap-3 px-2 pb-0.5 pt-1.5 text-xs text-dim">
            <span className="min-w-0 flex-1 truncate">{sub.title}</span>
            <span className="shrink-0 font-mono text-faint">{`${state.done.filter((pkg) => sub.ids.has(pkg.id)).length}/${sub.ids.size}`}</span>
          </p>
          <div className="pl-3">
            <Lines all={all} at={at} keep={(id) => sub.ids.has(id)} state={state} />
          </div>
        </div>
      ))}
    </div>
  );
}

function Lines({ all, at, keep, state }: { all: boolean; at: number; keep: (id: string) => boolean; state: PhaseState }) {
  return (
    <>
      {state.live.filter((live) => keep(live.pkg.id)).map((live) => (
        <PkgLine key={live.pkg.id} at={at} view={live} />
      ))}
      {all ? state.queued.filter((pkg) => keep(pkg.id)).map((pkg) => <RestLine key={pkg.id} pkg={pkg} />) : null}
      {all ? state.done.filter((pkg) => keep(pkg.id)).map((pkg) => <RestLine key={pkg.id} pkg={pkg} />) : null}
    </>
  );
}

const PRIMARY_BRANCH = /^(main|master)$/;

// Against the repository's default branch where the backend knows it, otherwise against the usual names.
function offPrimary(goal: Goal, base: string) {
  return goal.defaultBranch ? base !== goal.defaultBranch : !PRIMARY_BRANCH.test(base);
}

export function GoalTitle({ goal }: { goal: Goal }) {
  return (
    <>
      {goal.title}
      {goal.baseBranch && offPrimary(goal, goal.baseBranch) ? <span className="ml-2 align-middle font-mono text-[11px] font-normal text-faint" title="This goal lands on a branch other than the repository's main one">→ {goal.baseBranch}</span> : null}
    </>
  );
}

// The goal's phase, or Parked while the architect has set it aside. It nudges when it changes.
export function PhaseBadge({ small, view }: { small?: boolean; view: GoalView }) {
  const key = reportFor(view).verdict === "parked" ? "parked" : view.phase;
  const meta = PHASE[key];
  const ref = useFlash<HTMLSpanElement>(key, NUDGE, 600);
  return (
    <span ref={ref} className={`flex shrink-0 origin-left items-center gap-1.5 font-semibold ${small ? "text-xs" : "text-sm"} ${meta.text}`}>
      <span className={`rounded-full ${small ? "size-1.5" : "size-2"} ${meta.dot}`} />
      {meta.label}
    </span>
  );
}

// Shown while someone waits on the operator for this goal. It takes you to the question.
export function NeedsYouFlag({ view }: { view: GoalView }) {
  const ask = view.ask;
  if (!ask) return null;
  const jump = (event: MouseEvent | KeyboardEvent) => {
    event.stopPropagation();
    spotlight(`[data-ask="${CSS.escape(ask.id)}"]`);
  };

  return (
    <span className="flex shrink-0 items-center gap-1.5 rounded px-1.5 py-0.5 text-xs font-semibold text-you hover:bg-you/10" role="link" tabIndex={0} onClick={jump} onKeyDown={(event) => (event.key === "Enter" ? jump(event) : undefined)}>
      <span className="size-1.5 animate-pulse rounded-full bg-you" />
      Needs you{view.asks.length > 1 ? ` · ${view.asks.length}` : ""}
    </span>
  );
}

// Status on the left, then the PR's gates, where it is, the PR, who works on it, and Finish where the PR waits on others.
export function PkgLine({ at, view }: { at: number; view: PkgView }) {
  const ref = useFlash<HTMLDivElement>(`${view.stage}${view.failed ? ":failed" : ""}`, GLOW, 1400);
  const pkg = view.pkg;
  return (
    <div ref={ref} className={ROW}>
      <Pip stage={view.stage} failed={view.failed} />
      <span className="truncate text-sm">{pkg.title}</span>
      <CiCell ci={pkg.ci} stale={pkg.stale.includes("github")} />
      <ReviewCell review={pkg.review} />
      <StageSteps view={view} />
      <StageLabel view={view} />
      <StageTime at={at} view={view} />
      <PrLink pr={pkg.pr} repo={pkg.goalRepo} />
      <Owner owner={pkg.owner} />
      {waitsOnOthers(pkg) ? <ActButton action={{ kind: "finish", pkgId: pkg.id }} confirm="Finish?" label="Finish" tone="text-ink" /> : <span />}
    </div>
  );
}

function RestLine({ pkg }: { pkg: Pkg }) {
  const outcome = pkg.outcome ? OUTCOME[pkg.outcome] : null;
  return (
    <div className={ROW}>
      <Pip stage={outcome ? "ended" : "planned"} />
      <span className={`truncate text-sm ${outcome ? "text-faint line-through decoration-faint/60" : "text-dim"}`}>{pkg.title}</span>
      <span />
      <span />
      {/* The outcome starts where the stage would: the steps column where it shows, the stage column otherwise. */}
      <span className={`col-span-2 truncate font-mono text-[11px] min-[1280px]:col-span-3 ${outcome?.tone ?? "text-faint"}`}>{outcome?.label ?? "Planned"}</span>
      <PrLink pr={pkg.pr} repo={pkg.goalRepo} />
      <span />
      <span />
    </div>
  );
}
