import { Check, ChevronDown, ChevronLeft, Circle } from "lucide-react";
import { useLayoutEffect, useRef, useState, type RefObject } from "react";

import { ActionMenu, actionsFor, GoalRefusal, type Action } from "./actions";
import { areaLabel } from "./areas";
import { finishPkg } from "./exits";
import { deployAt, span, unresolvedPkgs, waitsOnOthers, type Ask, type Board, type Decision, type GoalView, type Phase, type Pkg, type PkgView } from "./model";
import { calm, EASE, Presence } from "./motion";
import { useAct, type GoalStep } from "./operator";
import { CiCell, deployLabel, LIFECYCLE, OrgIcon, OUTCOME, Pip, PrLink, ReviewCell, slotOf, StageStatus } from "./parts";
import { AskCard, DecisionCard, Heading, INSET, Tap, useGoalStep, Who } from "./phone-parts";
import { BriefAge, etaText, GoalTitle, looseStates, PhaseBadge, phaseStates, reportFor, type PhaseState } from "./report";
import { Reveal } from "./reveal";
import { SinceChip } from "./since";

// A PR name is a small link; its padding makes it a fingertip tall without moving the text.
const PR_TAP = "-mx-2.5 -my-3.5 px-2.5 py-3.5";
// Package rows sit right of the route's line.
const ROUTE_INSET = "pl-[calc(var(--inset-l)+1.5rem)] pr-[var(--inset-r)]";
// Where the goal's actions are the expected next step they are pinned under the thumb; on a goal still under way they wait in the ⋯ menu.
const PINNED = new Set<Phase>(["done", "unresolved", "archived"]);

// One goal on its own screen: what it is and who works on it, what needs the operator, then its route of packages.
export function GoalScreen({ asks, at, board, decisions, onBack, onOpen, view, views }: { asks: Ask[]; at: number; board: Board; decisions: Decision[]; onBack: () => void; onOpen: (goalId: string) => void; view: GoalView; views: GoalView[] }) {
  const root = useRef<HTMLDivElement>(null);
  const head = useRef<HTMLElement>(null);
  const step = useGoalStep();
  const goal = view.goal;
  const pinned = PINNED.has(view.phase);
  // A goal that leaves the board goes back to the list after its exit; a restored one stays.
  const run = async (key: GoalStep) => {
    if ((await step(goal.id, key, head.current)) && key !== "restore") onBack();
  };

  // The screen slides in from the side it came from; with reduced motion it only fades.
  useLayoutEffect(() => {
    const node = root.current;
    if (!node) return;
    if (calm()) node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150 });
    else node.animate([{ opacity: 0, transform: "translateX(24px)" }, { opacity: 1, transform: "none" }], { duration: 240, easing: EASE });
  }, []);

  return (
    <div ref={root} className={`min-h-dvh ${pinned ? "pb-[calc(env(safe-area-inset-bottom)+5.5rem)]" : "pb-[calc(env(safe-area-inset-bottom)+2rem)]"}`}>
      <header className="sticky top-0 z-20 border-b border-line bg-bg/95 pt-[env(safe-area-inset-top)] backdrop-blur">
        <div className="flex h-13 items-center gap-1 pl-[max(0.25rem,env(safe-area-inset-left))] pr-[max(0.25rem,env(safe-area-inset-right))]">
          <button aria-label="Back" className="flex size-11 shrink-0 items-center justify-center rounded-md text-dim active:bg-line" type="button" onClick={onBack}>
            <ChevronLeft className="size-5" />
          </button>
          <span className="min-w-0 flex-1 truncate text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">{areaLabel(goal.area)}</span>
          <span className={pinned ? "pr-3" : ""}>
            <PhaseBadge small view={view} />
          </span>
          {pinned ? null : <ActionMenu touch items={actionsFor(view.phase)} label={`Actions for ${goal.title}`} onPick={(key) => void run(key)} />}
        </div>
      </header>
      <main>
        <GoalHead at={at} head={head} view={view} />
        {pinned ? null : <GoalRefusal className={INSET} goalId={goal.id} />}
        {asks.length > 0 ? (
          <>
            <Heading count={asks.length} tone="text-you">Needs you</Heading>
            <ul className="space-y-2">
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
            <ul className="space-y-2">
              {decisions.map((decision) => (
                <DecisionCard key={decision.id} bare at={at} board={board} decision={decision} onOpen={onOpen} />
              ))}
            </ul>
          </>
        ) : null}
      </main>
      {pinned ? <Pinned actions={actionsFor(view.phase)} goalId={goal.id} onRun={run} /> : null}
    </div>
  );
}

// The title, who works on it, and the architect's own words. Exits play on this block.
function GoalHead({ at, head, view }: { at: number; head: RefObject<HTMLElement | null>; view: GoalView }) {
  const act = useAct();
  const report = reportFor(view);
  const goal = view.goal;

  return (
    <section ref={head} className={`pb-2 pt-5 ${INSET}`} data-goal={goal.id}>
      <h1 className="text-xl font-semibold leading-snug [overflow-wrap:anywhere]">
        <OrgIcon org={goal.org} /> <GoalTitle goal={goal} />
      </h1>
      <p className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
        {view.ask ? <span className="text-xs font-semibold text-you">Needs you{view.asks.length > 1 ? ` · ${view.asks.length}` : ""}</span> : null}
        <SinceChip goalId={goal.id} />
        <Who terminal={goal.owner} />
      </p>
      {goal.owner?.liveness === "unknown" ? <Tap className="mt-3 items-start" confirm="Release?" label="Release" run={() => act({ kind: "release", goalId: goal.id }).then(() => null)} /> : null}
      {report.brief || report.eta ? (
        <p className="mt-3 text-[15px] leading-relaxed text-ink/90 [overflow-wrap:anywhere]">
          {report.brief}
          {report.eta ? <span className="text-dim"> {etaText(report.eta)}</span> : null}
          <BriefAge at={at} report={report} />
        </p>
      ) : null}
    </section>
  );
}

// The goal's actions when they are the next step: the first is the one expected, Delete stays red.
function Pinned({ actions, goalId, onRun }: { actions: Action[]; goalId: string; onRun: (key: GoalStep) => Promise<void> }) {
  return (
    <footer className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-bg/95 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-3 backdrop-blur">
      <div className={INSET}>
        <GoalRefusal className="pb-2" goalId={goalId} />
        <div className="flex gap-2">
          {actions.map((action, index) => (
            <Tap key={action.key} className="flex-1" confirm={`${action.label}?`} label={action.label} look={action.danger ? "danger" : index === 0 ? "primary" : "plain"} run={() => onRun(action.key)} />
          ))}
        </div>
      </div>
    </footer>
  );
}

type Stop = { state: PhaseState; title: string };
const LOOSE_TITLE: Record<string, string> = { now: "Now", next: "Up next", done: "Ended" };
const LOOSE_ORDER = ["now", "next", "done"];

// The architect's phases in order, or else now, up next and ended.
function stopsOf(view: GoalView): Stop[] {
  const phases = phaseStates(view);
  if (phases.length > 0) return phases.map((state) => ({ state, title: state.phase.title }));
  return looseStates(view)
    .sort((left, right) => LOOSE_ORDER.indexOf(left.phase.id) - LOOSE_ORDER.indexOf(right.phase.id))
    .map((state) => ({ state, title: LOOSE_TITLE[state.phase.id] }));
}

// The goal's route, top to bottom. A stop with work moving is open, as is one holding a package that did not land;
// any other opens on a tap. Deploys close the route.
function Route({ at, view }: { at: number; view: GoalView }) {
  const stops = stopsOf(view);
  const steps = deployAt(view.goal, at);
  const stuck = new Set(view.phase === "unresolved" ? unresolvedPkgs(view).map((pkg) => pkg.id) : []);
  if (stops.length === 0 && steps.length === 0) return null;

  return (
    <>
      <Heading count={view.live.length + view.queued.length + view.done.length}>Packages</Heading>
      <ol>
        {stops.map((stop) => (
          <RouteStop key={stop.state.phase.id} at={at} open={stop.state.status === "active" || stop.state.done.some((pkg) => stuck.has(pkg.id))} stop={stop} />
        ))}
        {steps.map((deploy) => {
          const label = deployLabel(deploy);
          return (
            <li key={deploy.env} className={`flex min-h-11 items-center gap-3 ${INSET}`}>
              <span aria-hidden className="ml-1 size-2.5 rounded-full border border-dashed border-faint" />
              <span className={`font-mono text-xs ${label.tone || "text-faint"}`}>{label.text}</span>
            </li>
          );
        })}
      </ol>
    </>
  );
}

const STOP_MARK: Record<PhaseState["status"], string> = { done: "text-merge", active: "fill-current text-build", waiting: "text-faint", upcoming: "text-faint" };

function stopCount(state: PhaseState, total: number) {
  if (state.status === "upcoming") return "not sliced yet";
  return state.status === "done" ? `${total} ended` : `${state.done.length}/${total}`;
}

function RouteStop({ at, open: opened, stop }: { at: number; open: boolean; stop: Stop }) {
  const { state } = stop;
  const total = state.live.length + state.queued.length + state.done.length;
  const [open, setOpen] = useState(opened);
  const Mark = state.status === "done" ? Check : Circle;

  return (
    <li className="relative">
      <span aria-hidden className="absolute bottom-0 left-[calc(var(--inset-l)+8.5px)] top-11 w-px bg-line" />
      <button aria-expanded={open} className={`flex min-h-11 w-full items-center gap-3 text-left active:bg-white/[0.04] disabled:active:bg-transparent ${INSET}`} disabled={total === 0} type="button" onClick={() => setOpen(!open)}>
        <Mark aria-hidden className={`ml-1 size-2.5 shrink-0 ${STOP_MARK[state.status]}`} />
        <span className={`min-w-0 flex-1 truncate text-sm font-medium ${state.status === "active" ? "text-ink" : "text-dim"}`}>{stop.title}</span>
        <span className="shrink-0 font-mono text-xs text-faint">{stopCount(state, total)}</span>
        {total > 0 ? <ChevronDown aria-hidden className={`size-4 shrink-0 text-faint transition-transform motion-reduce:transition-none ${open ? "rotate-180" : ""}`} /> : <span className="w-4" />}
      </button>
      <Reveal className="pb-3" show={open}>
        <StopPackages at={at} state={state} />
      </Reveal>
    </li>
  );
}

type Line = { pkg: Pkg; live: PkgView | null };

// A stop with work moving lists only that until the rest is asked for: moving packages first, then planned, then ended.
// Deeper group paths become captions.
function StopPackages({ at, state }: { at: number; state: PhaseState }) {
  const [all, setAll] = useState(state.status !== "active");
  const lines: Line[] = [...state.live.map((live) => ({ pkg: live.pkg, live })), ...(all ? [...state.queued, ...state.done] : []).map((pkg) => ({ pkg, live: null }))];
  const nested = new Set(state.phase.subs.flatMap((sub) => sub.pkgs.map((pkg) => pkg.id)));
  const groups = [{ id: "", title: "", has: (id: string) => !nested.has(id) }, ...state.phase.subs.map((sub) => ({ id: sub.id, title: sub.title, has: (id: string) => sub.pkgs.some((pkg) => pkg.id === id) }))];
  const rest = [state.done.length > 0 ? `${state.done.length} ended` : "", state.queued.length > 0 ? `${state.queued.length} up next` : ""].filter(Boolean);

  return (
    <div className="space-y-px">
      {groups.map((group) => (
        <Group key={group.id} at={at} lines={lines.filter((line) => group.has(line.pkg.id))} title={group.title} />
      ))}
      {!all && rest.length > 0 ? (
        <button className={`flex min-h-11 w-full items-center font-mono text-xs text-dim ${ROUTE_INSET}`} type="button" onClick={() => setAll(true)}>
          {rest.join(" · ")} · show
        </button>
      ) : null}
    </div>
  );
}

function Group({ at, lines, title }: { at: number; lines: Line[]; title: string }) {
  if (lines.length === 0) return null;
  return (
    <div className="space-y-px">
      {title ? <p className={`pb-1 pt-2 text-xs text-dim ${ROUTE_INSET}`}>{title}</p> : null}
      <Presence items={lines} keyOf={(line) => line.pkg.id}>
        {({ item, key, ref }) => (item.live ? <PkgCard key={key} ref={ref} at={at} view={item.live} /> : <RestCard key={key} ref={ref} pkg={item.pkg} />)}
      </Presence>
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
  const [open, setOpen] = useState(false);
  const pkg = view.pkg;
  const exited = pkg.exited && view.stage === "implementing";

  return (
    <div ref={ref} className="bg-white/[0.035]" data-pkg-row>
      <button aria-expanded={open} className={`flex min-h-11 w-full items-start gap-3 py-2.5 text-left ${ROUTE_INSET}`} type="button" onClick={() => setOpen(!open)}>
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
            <CiCell ci={pkg.ci} stale={pkg.stale.includes("github")} />
            {pkg.owner?.liveness === "unknown" ? <span className="font-mono text-[11px] text-checks">Not answering</span> : null}
          </span>
        </span>
        <ChevronDown aria-hidden className={`mt-0.5 size-4 shrink-0 text-faint transition-transform motion-reduce:transition-none ${open ? "rotate-180" : ""}`} />
      </button>
      <Reveal className={`space-y-2.5 pb-3 ${ROUTE_INSET}`} show={open}>
        <PkgDetail at={at} view={view} />
      </Reveal>
    </div>
  );
}

// The lifecycle strip, time in stage, PR and review, the worker, and Finish while the PR waits on another repository.
function PkgDetail({ at, view }: { at: number; view: PkgView }) {
  const act = useAct();
  const pkg = view.pkg;
  const now = slotOf(view);

  return (
    <div className="space-y-2.5 pl-5">
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
      <Who terminal={pkg.owner} />
      {waitsOnOthers(pkg) ? <Tap className="items-start" confirm="Finish?" label="Finish" run={(button) => finishPkg(pkg.id, button.closest<HTMLElement>("[data-pkg-row]"), () => act({ kind: "finish", pkgId: pkg.id }))} /> : null}
    </div>
  );
}

// A planned or ended package: its title and how it ended.
function RestCard({ pkg, ref }: { pkg: Pkg; ref?: (node: HTMLElement | null) => void }) {
  const outcome = pkg.outcome ? OUTCOME[pkg.outcome] : null;
  return (
    <div ref={ref} className={`flex min-h-11 items-start gap-3 py-2.5 ${ROUTE_INSET}`} data-pkg-row>
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
