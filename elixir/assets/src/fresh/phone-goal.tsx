import { Check, ChevronDown, ChevronLeft, Circle } from "lucide-react";
import { useLayoutEffect, useRef, useState } from "react";

import { actionsFor, GoalRefusal } from "./actions";
import { areaLabel } from "./areas";
import { finishPkg } from "./exits";
import { deployAt, span, unresolvedPkgs, waitsOnOthers, type Ask, type Board, type Decision, type GoalView, type Pkg, type PkgView } from "./model";
import { calm, EASE, Presence } from "./motion";
import { useAct } from "./operator";
import { Owner } from "./owner";
import { CiCell, deployLabel, LIFECYCLE, OrgIcon, OUTCOME, Pip, PrLink, ReviewCell, slotOf, StageStatus } from "./parts";
import { AskCard, DecisionCard, Heading, Tap, useGoalStep } from "./phone-parts";
import { BriefAge, etaText, GoalTitle, looseStates, PhaseBadge, phaseStates, reportFor, type PhaseState } from "./report";
import { Reveal } from "./reveal";
import { SinceChip } from "./since";

// A PR name is a small link; its padding makes it a fingertip tall without moving the text.
const PR_TAP = "-mx-2.5 -my-3.5 px-2.5 py-3.5";

// One goal on its own screen: what it is and who works on it, what needs the operator, then its route of
// packages. The goal's actions sit at the bottom, under the thumb.
export function GoalScreen({ asks, at, board, decisions, onBack, onOpen, view, views }: { asks: Ask[]; at: number; board: Board; decisions: Decision[]; onBack: () => void; onOpen: (goalId: string) => void; view: GoalView; views: GoalView[] }) {
  const root = useRef<HTMLDivElement>(null);
  const head = useRef<HTMLElement>(null);
  const step = useGoalStep();
  const report = reportFor(view);
  const goal = view.goal;

  // The screen slides in from the side it came from; with reduced motion it only fades.
  useLayoutEffect(() => {
    const node = root.current;
    if (!node) return;
    if (calm()) node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150 });
    else node.animate([{ opacity: 0, transform: "translateX(24px)" }, { opacity: 1, transform: "none" }], { duration: 240, easing: EASE });
  }, []);

  return (
    <div ref={root} className="min-h-dvh pb-[calc(env(safe-area-inset-bottom)+5.5rem)]">
      <header className="sticky top-0 z-20 border-b border-line bg-bg/95 pt-[env(safe-area-inset-top)] backdrop-blur">
        <div className="flex h-13 items-center gap-1 pl-[max(0.25rem,env(safe-area-inset-left))] pr-4">
          <button aria-label="Back" className="flex size-11 shrink-0 items-center justify-center rounded-md text-dim active:bg-line" type="button" onClick={onBack}>
            <ChevronLeft className="size-5" />
          </button>
          <span className="min-w-0 flex-1 truncate text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">{areaLabel(goal.area)}</span>
          <PhaseBadge small view={view} />
        </div>
      </header>
      <main className="px-[max(1rem,env(safe-area-inset-left))]">
        <section ref={head} className="pb-2 pt-5" data-goal={goal.id}>
          <h1 className="text-xl font-semibold leading-snug [overflow-wrap:anywhere]">
            <OrgIcon org={goal.org} /> <GoalTitle goal={goal} />
          </h1>
          <p className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
            {view.ask ? <span className="text-xs font-semibold text-you">Needs you{view.asks.length > 1 ? ` · ${view.asks.length}` : ""}</span> : null}
            <SinceChip goalId={goal.id} />
            <Owner goalId={goal.id} owner={goal.owner} />
          </p>
          {report.brief || report.eta ? (
            <p className="mt-3 text-[15px] leading-relaxed text-ink/90 [overflow-wrap:anywhere]">
              {report.brief}
              {report.eta ? <span className="text-dim"> {etaText(report.eta)}</span> : null}
              <BriefAge at={at} report={report} />
            </p>
          ) : null}
        </section>
        {asks.length > 0 ? (
          <>
            <Heading count={asks.length} tone="text-you">Needs you</Heading>
            <ul className="space-y-3">
              <Presence items={asks} keyOf={(ask) => ask.id}>
                {({ item, key, ref }) => <AskCard key={key} ref={ref} bare ask={item} at={at} board={board} views={views} onOpen={onOpen} />}
              </Presence>
            </ul>
          </>
        ) : null}
        <Route at={at} view={view} />
        {decisions.length > 0 ? (
          <>
            <Heading count={decisions.length}>Decisions to review</Heading>
            <ul className="space-y-3">
              {decisions.map((decision) => (
                <DecisionCard key={decision.id} bare at={at} board={board} decision={decision} onOpen={onOpen} />
              ))}
            </ul>
          </>
        ) : null}
      </main>
      <footer className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-bg/95 px-4 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-3 backdrop-blur">
        <GoalRefusal className="pb-2" goalId={goal.id} />
        <div className="flex gap-2">
          {actionsFor(view.phase).map((action, index) => (
            <Tap
              key={action.key}
              className="flex-1"
              confirm={`${action.label}?`}
              label={action.label}
              look={action.danger ? "danger" : index === 0 ? "primary" : "plain"}
              run={async () => {
                // A goal that leaves the board goes back to the list after its exit; a restored one stays.
                if ((await step(goal.id, action.key, head.current)) && action.key !== "restore") onBack();
                return null;
              }}
            />
          ))}
        </div>
      </footer>
    </div>
  );
}

type Stop = { state: PhaseState; title: string };
const LOOSE_TITLE: Record<string, string> = { now: "Now", next: "Up next", done: "Ended" };
const LOOSE_ORDER = ["now", "next", "done"];

// The goal's route, top to bottom: the architect's phases in order, or else now, up next and ended.
// A stop with work moving is open; any other opens on a tap. Deploys close the route.
function Route({ at, view }: { at: number; view: GoalView }) {
  const phases = phaseStates(view);
  const stops: Stop[] =
    phases.length > 0
      ? phases.map((state) => ({ state, title: state.phase.title }))
      : looseStates(view)
          .sort((left, right) => LOOSE_ORDER.indexOf(left.phase.id) - LOOSE_ORDER.indexOf(right.phase.id))
          .map((state) => ({ state, title: LOOSE_TITLE[state.phase.id] }));
  const steps = deployAt(view.goal, at);
  const unresolved = new Set(view.phase === "unresolved" ? unresolvedPkgs(view).map((pkg) => pkg.id) : []);
  if (stops.length === 0 && steps.length === 0) return null;

  return (
    <>
      <Heading count={view.live.length + view.queued.length + view.done.length}>Packages</Heading>
      <ol>
        {stops.map((stop) => (
          <RouteStop key={stop.state.phase.id} at={at} stop={stop} stuck={unresolved} />
        ))}
        {steps.map((deploy) => {
          const label = deployLabel(deploy);
          return (
            <li key={deploy.env} className="flex min-h-11 items-center gap-3 pl-1">
              <span aria-hidden className="size-2.5 rounded-full border border-dashed border-faint" />
              <span className={`font-mono text-xs ${label.tone || "text-faint"}`}>{label.text}</span>
            </li>
          );
        })}
      </ol>
    </>
  );
}

const STOP_MARK: Record<PhaseState["status"], string> = { done: "text-merge", active: "fill-current text-build", waiting: "text-faint", upcoming: "text-faint" };

function RouteStop({ at, stop, stuck }: { at: number; stop: Stop; stuck: Set<string> }) {
  const { state } = stop;
  const total = state.live.length + state.queued.length + state.done.length;
  const [open, setOpen] = useState(state.status === "active" || state.done.some((pkg) => stuck.has(pkg.id)));
  const Mark = state.status === "done" ? Check : Circle;
  const count = state.status === "upcoming" ? "not sliced yet" : state.status === "done" ? `${total} ended` : `${state.done.length}/${total}`;

  return (
    <li className="relative">
      <span aria-hidden className="absolute bottom-0 left-[9px] top-11 w-px bg-line" />
      <button aria-expanded={open} className="flex min-h-11 w-full items-center gap-3 rounded pl-1 text-left active:bg-white/[0.04] disabled:active:bg-transparent" disabled={total === 0} type="button" onClick={() => setOpen(!open)}>
        <Mark aria-hidden className={`size-2.5 shrink-0 ${STOP_MARK[state.status]}`} />
        <span className={`min-w-0 flex-1 truncate text-sm font-medium ${state.status === "active" ? "text-ink" : "text-dim"}`}>{stop.title}</span>
        <span className="shrink-0 font-mono text-xs text-faint">{count}</span>
        {total > 0 ? <ChevronDown aria-hidden className={`size-4 shrink-0 text-faint transition-transform motion-reduce:transition-none ${open ? "rotate-180" : ""}`} /> : <span className="w-4" />}
      </button>
      <Reveal className="pb-3 pl-6" show={open}>
        <StopPackages at={at} state={state} />
      </Reveal>
    </li>
  );
}

// Moving packages first, then planned, then ended. Deeper group paths become captions.
// A stop with work moving lists only that until the rest is asked for.
function StopPackages({ at, state }: { at: number; state: PhaseState }) {
  const [all, setAll] = useState(state.status !== "active");
  const ordered = [...state.live.map((live) => ({ pkg: live.pkg, live })), ...(all ? [...state.queued, ...state.done] : []).map((pkg) => ({ pkg, live: null }))];
  const rest = [state.done.length > 0 ? `${state.done.length} ended` : "", state.queued.length > 0 ? `${state.queued.length} up next` : ""].filter(Boolean);
  const subs = state.phase.subs;
  const nested = new Set(subs.flatMap((sub) => sub.pkgs.map((pkg) => pkg.id)));
  const groups = [{ id: "", title: "", ids: null as Set<string> | null }, ...subs.map((sub) => ({ id: sub.id, title: sub.title, ids: new Set(sub.pkgs.map((pkg) => pkg.id)) }))];

  return (
    <div className="space-y-1.5">
      {groups.map((group) => {
        const lines = ordered.filter((line) => (group.ids ? group.ids.has(line.pkg.id) : !nested.has(line.pkg.id)));
        if (lines.length === 0) return null;
        return (
          <div key={group.id} className="space-y-1.5">
            {group.title ? <p className="px-1 pt-1.5 text-xs text-dim">{group.title}</p> : null}
            <Presence items={lines} keyOf={(line) => line.pkg.id}>
              {({ item, key, ref }) => (item.live ? <PkgCard key={key} ref={ref} at={at} view={item.live} /> : <RestCard key={key} ref={ref} pkg={item.pkg} />)}
            </Presence>
          </div>
        );
      })}
      {!all && rest.length > 0 ? (
        <button className="flex min-h-11 items-center px-1 font-mono text-xs text-dim" type="button" onClick={() => setAll(true)}>
          {rest.join(" · ")} · show
        </button>
      ) : null}
    </div>
  );
}

// The stage a moving package is in, in its lifecycle colour; red while its checks fail.
export function StageWord({ view }: { view: PkgView }) {
  if (view.pkg.exited && view.stage === "implementing") return <span className="shrink-0 font-mono text-[11px] font-semibold text-checks">Exited</span>;
  const slot = LIFECYCLE[slotOf(view)];
  return <span className={`shrink-0 font-mono text-[11px] font-semibold ${view.failed ? "text-fail" : slot.tone}`}>{slot.label}</span>;
}

// A moving package: what it is, its stage, checks and review. A tap opens its lifecycle, time in stage, PR and worker.
function PkgCard({ at, ref, view }: { at: number; ref?: (node: HTMLElement | null) => void; view: PkgView }) {
  const act = useAct();
  const [open, setOpen] = useState(false);
  const pkg = view.pkg;
  const now = slotOf(view);
  const exited = pkg.exited && view.stage === "implementing";

  return (
    <div ref={ref} className="rounded-md bg-white/[0.035]" data-pkg-row>
      <button aria-expanded={open} className="flex min-h-11 w-full items-start gap-3 px-3 py-2.5 text-left" type="button" onClick={() => setOpen(!open)}>
        <span className="mt-1.5 flex">
          <Pip failed={view.failed} stage={view.stage} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-sm leading-snug [overflow-wrap:anywhere]">{pkg.title}</span>
          <span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5">
            <StageWord view={view} />
            {exited ? null : (
              <span className="grid">
                <StageStatus at={at} view={view} />
              </span>
            )}
            {pkg.owner?.liveness === "unknown" ? <span className="font-mono text-[11px] text-checks">Not answering</span> : null}
            <CiCell ci={pkg.ci} stale={pkg.stale.includes("github")} />
          </span>
        </span>
        <ChevronDown aria-hidden className={`mt-0.5 size-4 shrink-0 text-faint transition-transform motion-reduce:transition-none ${open ? "rotate-180" : ""}`} />
      </button>
      <Reveal className="space-y-2.5 pb-3 pl-8 pr-3" show={open}>
        <p className="flex justify-between font-mono text-[11px]">
          {LIFECYCLE.map((slot, index) => (
            <span key={slot.label} className={index < now ? "text-dim" : index === now ? `font-semibold ${view.failed ? "text-fail" : slot.tone}` : "text-faint"}>
              {slot.label}
            </span>
          ))}
        </p>
        {view.untimed ? null : <p className="font-mono text-[11px] text-dim">In {LIFECYCLE[now].label} for {span(at - view.since)}</p>}
        <p className="flex flex-wrap items-center gap-x-4 gap-y-1">
          <PrLink className={PR_TAP} pr={pkg.pr} repos={pkg.goalRepos} waits={waitsOnOthers(pkg)} />
          <ReviewCell review={pkg.review} />
        </p>
        <Owner owner={pkg.owner} />
        {waitsOnOthers(pkg) ? <Tap confirm="Finish?" label="Finish" run={(button) => finishPkg(pkg.id, button.closest<HTMLElement>("[data-pkg-row]"), () => act({ kind: "finish", pkgId: pkg.id }))} /> : null}
      </Reveal>
    </div>
  );
}

// A planned or ended package: its title and how it ended.
function RestCard({ pkg, ref }: { pkg: Pkg; ref?: (node: HTMLElement | null) => void }) {
  const outcome = pkg.outcome ? OUTCOME[pkg.outcome] : null;
  return (
    <div ref={ref} className="flex min-h-11 items-start gap-3 rounded-md px-3 py-2.5" data-pkg-row>
      <span className="mt-1.5 flex">
        <Pip stage={outcome ? "ended" : "planned"} />
      </span>
      <span className="min-w-0 flex-1">
        <span className={`block text-sm leading-snug [overflow-wrap:anywhere] ${outcome ? "text-faint line-through decoration-faint/60" : "text-dim"}`}>{pkg.title}</span>
        <span className="mt-1 flex flex-wrap items-center gap-x-3">
          <span className={`font-mono text-[11px] ${outcome?.tone ?? "text-faint"}`}>{outcome?.label ?? "Planned"}</span>
          <PrLink className={PR_TAP} pr={pkg.pr} repos={pkg.goalRepos} />
        </span>
      </span>
    </div>
  );
}
