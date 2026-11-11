// The board on a phone: the same goal views as desktop, arranged for one hand and a glance. Two tabs at the
// bottom, Needs you and Goals, and one goal at a time on its own screen. Where the operator is lives in the URL,
// so the phone's back gesture leaves a goal and a link can open one.
import { Check, ChevronRight, X } from "lucide-react";
import { Fragment, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";

import { areaLabel } from "./areas";
import type { Lanes } from "./board";
import type { visibleCards } from "./cards";
import { needsReview, span, type Ask, type Board, type Decision, type GoalView, type Settings } from "./model";
import { calm, Presence } from "./motion";
import { useAct, type OperatorAction } from "./operator";
import { CiCell, Deploy, OrgIcon, Pip, PrLink, ReviewCell } from "./parts";
import { useOperation } from "./pending";
import { GoalScreen, StageWord } from "./phone-goal";
import { AskCard, CARD, DecisionCard, Heading, INSET, TroubleCard } from "./phone-parts";
import { DotStrip, GoalTitle, PhaseBadge, reportFor } from "./report";
import { BoardMenu } from "./settings";
import { SinceChip, type Changes } from "./since";
import { isBroken, TROUBLE_WORD, troublesOf, type Trouble } from "./trouble";

const PHONE = "(max-width: 640px)";

// Whether the board is on a phone-sized screen. It follows the screen as it turns or resizes.
export function usePhone() {
  return useSyncExternalStore(
    (change) => {
      const query = window.matchMedia(PHONE);
      query.addEventListener("change", change);
      return () => query.removeEventListener("change", change);
    },
    () => window.matchMedia(PHONE).matches,
  );
}

type Cards = ReturnType<typeof visibleCards>;
export type PhoneProps = {
  at: number;
  board: Board;
  // Every goal, and the lanes after the area filter.
  views: GoalView[];
  lanes: Lanes;
  asks: Ask[];
  cards: Cards;
  shownCards: Cards;
  changes: Changes;
  since: number;
  areas: string[];
  area: string | null;
  failure: string | null;
  settings: Settings;
  onArea: (area: string | null) => void;
  onSaved: () => void;
  onSeen: () => void;
};

type Tab = "you" | "goals";
// Where the operator is: a tab, or one goal on its own screen above it.
type Place = { tab: Tab; goal: string | null };

function placeOf(fallback: Tab): Place {
  const query = new URLSearchParams(window.location.search);
  const tab = query.get("tab");
  return { tab: tab === "you" || tab === "goals" ? tab : fallback, goal: query.get("goal") };
}

function urlOf(place: Place) {
  const query = new URLSearchParams(window.location.search);
  query.set("tab", place.tab);
  if (place.goal) query.set("goal", place.goal);
  else query.delete("goal");
  return `${window.location.pathname}?${query}`;
}

// Opening a goal adds a history entry, so back, the gesture or the button, returns to the list where it was.
// A goal opened from a link has no list behind it: back replaces it with the tab.
function usePlace(fallback: Tab) {
  const [place, setPlace] = useState(() => placeOf(fallback));
  const first = useRef(fallback);
  const scrolls = useRef<Record<Tab, number>>({ you: 0, goals: 0 });
  const restore = useRef<number | null>(null);

  useEffect(() => {
    const pop = () => {
      const next = placeOf(first.current);
      if (!next.goal) restore.current = scrolls.current[next.tab];
      setPlace(next);
    };
    window.addEventListener("popstate", pop);
    return () => window.removeEventListener("popstate", pop);
  }, []);
  useLayoutEffect(() => {
    window.scrollTo(0, restore.current ?? 0);
    restore.current = null;
  }, [place]);

  const go = (next: Place, push: boolean) => {
    if (!place.goal) scrolls.current[place.tab] = window.scrollY;
    if (!next.goal) restore.current = scrolls.current[next.tab];
    window.history[push ? "pushState" : "replaceState"](push ? { phoneGoal: true } : null, "", urlOf(next));
    setPlace(next);
  };
  return {
    place,
    open: (goal: string) => go({ ...place, goal }, true),
    back: () => (window.history.state?.phoneGoal ? window.history.back() : go({ ...place, goal: null }, false)),
    tab: (tab: Tab) => go({ tab, goal: null }, false),
  };
}

// Everything in Needs you, in its four parts. The tab's count is their sum.
type Inbox = { asks: Ask[]; broken: Trouble[]; stuck: Trouble[]; decisions: Decision[]; total: number };
// What the operator can settle from here comes first.
const STUCK_ORDER = ["unresolved", "release", "waits", "exited", "silent"];
const stuckKind = (trouble: Trouble) => (trouble.kind === "silent" && trouble.pkg === null ? "release" : trouble.kind);

function inboxOf({ asks, at, board, cards, views }: PhoneProps): Inbox {
  const troubles = troublesOf(views, cards, at);
  const decisions = board.decisions.filter((entry) => entry.at <= at && needsReview(entry));
  const parts = {
    asks: [...asks].sort((left, right) => left.from - right.from),
    broken: troubles.filter(isBroken),
    stuck: troubles.filter((trouble) => !isBroken(trouble)).sort((left, right) => STUCK_ORDER.indexOf(stuckKind(left)) - STUCK_ORDER.indexOf(stuckKind(right))),
    decisions: decisions.sort((left, right) => right.at - left.at),
  };
  return { ...parts, total: parts.asks.length + parts.broken.length + parts.stuck.length + parts.decisions.length };
}

export function PhoneBoard(props: PhoneProps) {
  const { at, board, views } = props;
  const inbox = inboxOf(props);
  const { place, open, back, tab } = usePlace(inbox.total > 0 ? "you" : "goals");
  // A goal that leaves the board from its own screen keeps the screen while its exit plays; the screen then goes back.
  const [held, setHeld] = useState<GoalView | null>(null);
  const shown = (place.goal ? views.find((view) => view.goal.id === place.goal) : undefined) ?? (held && held.goal.id === place.goal ? held : undefined);

  if (place.goal && shown) {
    return (
      <div className="phone">
        <GoalScreen
          key={shown.goal.id}
          asks={inbox.asks.filter((ask) => ask.goalId === shown.goal.id)}
          at={at}
          board={board}
          decisions={inbox.decisions.filter((entry) => entry.goalId === shown.goal.id)}
          view={shown}
          views={views}
          onBack={back}
          onHold={setHeld}
          onOpen={open}
        />
      </div>
    );
  }

  return (
    <div className="phone min-h-dvh pb-[calc(env(safe-area-inset-bottom)+5rem)]">
      <header className="sticky top-0 z-20 border-b border-line bg-bg/95 pt-[env(safe-area-inset-top)] backdrop-blur">
        <div className={`flex h-13 items-center gap-3 ${INSET}`}>
          <BoardMenu touch settings={props.settings} onSaved={props.onSaved} />
          <span className="min-w-0 flex-1 truncate text-xs text-fail">{props.failure ? "Connection lost · showing the last read" : ""}</span>
          <StatusDot needed={props.asks.length} />
        </div>
      </header>
      <main>{place.tab === "you" ? <YouTab {...props} inbox={inbox} onGoals={() => tab("goals")} onOpen={open} /> : <GoalsTab {...props} troubles={[...inbox.broken, ...inbox.stuck]} onOpen={open} />}</main>
      <TabBar asks={inbox.asks.length} goals={props.lanes.main.length} place={place} waiting={inbox.total} onTab={tab} />
    </div>
  );
}

// The board's first question, answered in the corner: orange and pulsing while a question waits, green otherwise.
function StatusDot({ needed }: { needed: number }) {
  return (
    <span className="flex size-11 items-center justify-center" role="img" aria-label={needed > 0 ? `You are needed in ${needed}` : "You are not needed"}>
      <span className={`size-2.5 rounded-full ${needed > 0 ? "animate-pulse bg-you motion-reduce:animate-none" : "bg-merge"}`} />
    </span>
  );
}

// The two tabs, at the bottom where the thumb is. Needs you counts everything in it, in orange while a question waits.
function TabBar({ asks, goals, onTab, place, waiting }: { asks: number; goals: number; onTab: (tab: Tab) => void; place: Place; waiting: number }) {
  const tabs = [
    { key: "you" as const, label: "Needs you", count: waiting, tone: asks > 0 ? "bg-you text-bg" : "bg-line text-ink" },
    { key: "goals" as const, label: "Goals", count: goals, tone: "text-faint" },
  ];
  return (
    <nav className="fixed inset-x-0 bottom-0 z-20 flex border-t border-line bg-bg/95 pb-[env(safe-area-inset-bottom)] backdrop-blur">
      {tabs.map((entry) => {
        const on = place.tab === entry.key;
        return (
          <button key={entry.key} aria-current={on ? "page" : undefined} className={`relative flex h-14 flex-1 items-center justify-center gap-2 text-sm font-medium ${on ? "text-ink" : "text-dim"}`} type="button" onClick={() => onTab(entry.key)}>
            <span aria-hidden className={`absolute inset-x-8 top-0 h-0.5 rounded-full transition-colors ${on ? "bg-ink" : "bg-transparent"}`} />
            {entry.label}
            {entry.count > 0 ? <span className={`min-w-5 rounded-full px-1.5 text-center font-mono text-[11px] leading-5 ${entry.tone}`}>{entry.count}</span> : null}
          </button>
        );
      })}
    </nav>
  );
}

// Everything that waits on the operator: questions first, then what is broken, what is stuck, and calls to review.
function YouTab({ at, board, inbox, onGoals, onOpen, views }: PhoneProps & { inbox: Inbox; onGoals: () => void; onOpen: (goalId: string) => void }) {
  if (inbox.total === 0) {
    return (
      <div className="flex min-h-[60dvh] flex-col items-center justify-center gap-5 text-center">
        <p className="flex items-center gap-2 text-dim">
          <span className="size-2 rounded-full bg-merge" />
          You are not needed
        </p>
        <button className="h-11 rounded-md border border-line px-5 text-sm font-medium text-ink" type="button" onClick={onGoals}>
          See what is moving
        </button>
      </div>
    );
  }

  return (
    <>
      <Glance
        counts={[
          { id: "questions", label: "Questions", count: inbox.asks.length, tone: "text-you" },
          { id: "broken", label: "Broken", count: inbox.broken.length, tone: "text-fail" },
          { id: "stuck", label: "Stuck", count: inbox.stuck.length, tone: "text-checks" },
          { id: "decisions", label: "Decisions", count: inbox.decisions.length, tone: "text-ink" },
        ]}
      />
      <Group id="questions" items={inbox.asks} keyOf={(ask) => ask.id} label="Questions" tone="text-you">
        {(ask, ref) => <AskCard ref={ref} ask={ask} at={at} board={board} views={views} onOpen={onOpen} />}
      </Group>
      <Group id="broken" items={inbox.broken} keyOf={(trouble) => trouble.key} label="Broken" tone="text-fail">
        {(trouble, ref) => <TroubleCard ref={ref} at={at} trouble={trouble} onOpen={onOpen} />}
      </Group>
      <Group id="stuck" items={inbox.stuck} keyOf={(trouble) => trouble.key} label="Stuck" tone="text-checks">
        {(trouble, ref) => <TroubleCard ref={ref} at={at} trouble={trouble} onOpen={onOpen} />}
      </Group>
      <Group id="decisions" items={inbox.decisions} keyOf={(decision) => decision.id} label="Decisions to review" tone="text-dim">
        {(decision, ref) => <DecisionCard ref={ref} at={at} board={board} decision={decision} onOpen={onOpen} />}
      </Group>
    </>
  );
}

// How much waits in each part, in one row at the top; a tap goes to that part.
function Glance({ counts }: { counts: Array<{ id: string; label: string; count: number; tone: string }> }) {
  return (
    <div className={`mt-4 grid grid-cols-4 gap-1.5 ${INSET}`}>
      {counts.map((entry) => (
        <button key={entry.id} className="flex min-h-16 flex-col items-start justify-between rounded-lg border border-line bg-panel px-2.5 py-2 text-left disabled:opacity-40" disabled={entry.count === 0} type="button" onClick={() => document.getElementById(entry.id)?.scrollIntoView({ behavior: calm() ? "auto" : "smooth" })}>
          <span className={`font-mono text-xl font-semibold leading-none tabular-nums ${entry.count > 0 ? entry.tone : "text-faint"}`}>{entry.count}</span>
          <span className="text-[11px] text-dim">{entry.label}</span>
        </button>
      ))}
    </div>
  );
}

function Group<T>({ children, id, items, keyOf, label, tone }: { children: (item: T, ref: (node: HTMLElement | null) => void) => ReactNode; id: string; items: T[]; keyOf: (item: T) => string; label: string; tone: string }) {
  if (items.length === 0) return null;
  return (
    <>
      <Heading count={items.length} id={id} tone={tone}>{label}</Heading>
      <ul className="space-y-2">
        <Presence items={items} keyOf={keyOf}>
          {({ item, key, ref }) => <Fragment key={key}>{children(item, ref)}</Fragment>}
        </Presence>
      </ul>
    </>
  );
}

// What changed while away, the area filter, then every goal in sight, small work, and the shelves.
function GoalsTab({ area, areas, at, changes, lanes, onArea, onOpen, onSeen, shownCards, since, troubles }: PhoneProps & { onOpen: (goalId: string) => void; troubles: Trouble[] }) {
  const byGoal = (goalId: string) => troubles.filter((trouble) => "view" in trouble && trouble.view.goal.id === goalId);
  const shelved = lanes.landed.length + lanes.parked.length + lanes.dormant.length + lanes.backlog.length + lanes.settled.length + lanes.archived.length;
  const nothing = lanes.main.length + shownCards.length + shelved === 0;
  if (nothing && area === null) return <p className="py-24 text-center text-dim">Nothing on the board</p>;

  return (
    <>
      <Since at={at} changes={changes} since={since} onOpen={onOpen} onSeen={onSeen} />
      <AreaChips area={area} areas={areas} onArea={onArea} />
      {nothing ? <p className="py-16 text-center text-dim">Nothing here</p> : null}
      {lanes.main.length > 0 ? (
        <ul className="mt-3 space-y-2">
          <Presence items={lanes.main} keyOf={(view) => view.goal.id}>
            {({ item, key, ref }) => <GoalCard key={key} ref={ref} troubles={byGoal(item.goal.id)} view={item} onOpen={onOpen} />}
          </Presence>
        </ul>
      ) : null}
      <SmallWork cards={shownCards} />
      <Shelf at={at} label="Landed · last 24 hours" views={lanes.landed} onOpen={onOpen} />
      <Shelf at={at} label="Parked" views={lanes.parked} onOpen={onOpen} />
      <Shelf at={at} label="Dormant" views={lanes.dormant} onOpen={onOpen} />
      <Shelf at={at} label="Not started" views={lanes.backlog} onOpen={onOpen} />
      <Shelf at={at} label="Settled" views={lanes.settled} onOpen={onOpen} />
      <Shelf at={at} label="Archived" views={lanes.archived} onOpen={onOpen} />
    </>
  );
}

// The area filter. A chosen area stays offered after its last goal leaves, so the way back to Everything stays.
function AreaChips({ area, areas, onArea }: { area: string | null; areas: string[]; onArea: (area: string | null) => void }) {
  const names = area === null || areas.includes(area) ? areas : [...areas, area];
  if (names.length < 2 && area === null) return null;
  return (
    <nav className={`mt-2 flex gap-1.5 overflow-x-auto [scrollbar-width:none] ${INSET}`}>
      {[null, ...names].map((name) => (
        <button key={name ?? "all"} className={`h-11 shrink-0 rounded-full px-4 text-sm ${name === area ? "bg-line text-ink" : "text-dim"}`} type="button" onClick={() => onArea(name)}>
          {name ?? "Everything"}
        </button>
      ))}
    </nav>
  );
}

// The totals since the last look; each opens the next goal behind it. Nothing shows while nothing changed.
function Since({ at, changes, onOpen, onSeen, since }: { at: number; changes: Changes; onOpen: (goalId: string) => void; onSeen: () => void; since: number }) {
  const turns = useRef(new Map<string, number>());
  if (changes.totals.length === 0) return null;
  const next = (label: string, goalIds: string[]) => {
    const turn = turns.current.get(label) ?? 0;
    turns.current.set(label, turn + 1);
    onOpen(goalIds[turn % goalIds.length]);
  };

  return (
    <section className={`pt-3 ${INSET}`}>
      <p className="text-xs text-faint">Since you last looked, {span(at - since)} ago</p>
      <p className="-mx-2 mt-0.5 flex flex-wrap">
        {changes.totals.map((total) => (
          <button key={total.label} className="h-11 rounded px-2 text-sm text-ink active:bg-line" type="button" onClick={() => next(total.label, total.goalIds)}>
            {total.label}
          </button>
        ))}
        <button className="h-11 rounded px-2 text-sm text-dim active:bg-line" type="button" onClick={onSeen}>
          Mark as seen
        </button>
      </p>
    </section>
  );
}

const MOVING_SHOWN = 3;

// One goal at a glance: what it is, whether it needs the operator, what is wrong, and what is moving. A tap opens it.
function GoalCard({ onOpen, ref, troubles, view }: { onOpen: (goalId: string) => void; ref: (node: HTMLElement | null) => void; troubles: Trouble[]; view: GoalView }) {
  // The phase badge already says Unresolved.
  const words = [...new Set(troubles.map((trouble) => trouble.kind))].filter((kind) => kind !== "unresolved").map((kind) => TROUBLE_WORD[kind]);

  return (
    <li ref={ref} className={CARD} data-goal={view.goal.id}>
      <button className={`block w-full py-3.5 text-left transition-colors active:bg-white/[0.04] ${INSET}`} type="button" onClick={() => onOpen(view.goal.id)}>
        <span className="flex items-start gap-2">
          <span className="min-w-0 flex-1 font-medium leading-snug [overflow-wrap:anywhere]">
            <OrgIcon org={view.goal.org} /> <GoalTitle goal={view.goal} />
          </span>
          <ChevronRight aria-hidden className="mt-0.5 size-4 shrink-0 text-faint" />
        </span>
        <span className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
          <PhaseBadge small view={view} />
          {view.ask ? (
            <span className="flex items-center gap-1.5 text-xs font-semibold text-you">
              <span aria-hidden className="size-1.5 animate-pulse rounded-full bg-you motion-reduce:animate-none" />
              Needs you{view.asks.length > 1 ? ` · ${view.asks.length}` : ""}
            </span>
          ) : null}
          {words.map((word) => (
            <span key={word.text} className={`text-xs font-semibold ${word.tone}`}>{word.text}</span>
          ))}
          <SinceChip goalId={view.goal.id} />
        </span>
        <span className="mt-1 block truncate text-[11px] uppercase tracking-[0.12em] text-faint">{areaLabel(view.goal.area)}</span>
        <Progress view={view} />
      </button>
    </li>
  );
}

// The goal's dots and counts, then up to three moving packages with their stage, failing ones first.
function Progress({ view }: { view: GoalView }) {
  const total = view.live.length + view.queued.length + view.done.length;
  const live = [...view.live].sort((left, right) => Number(right.failed) - Number(left.failed));
  if (total === 0) return <span className="mt-2 block text-sm text-dim">{reportFor(view).brief}</span>;

  return (
    <>
      <span className="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1">
        <DotStrip view={view} />
        <span className="font-mono text-xs text-dim">
          {view.live.length > 0 ? `${view.live.length} moving · ` : ""}
          {view.done.length}/{total} done
        </span>
      </span>
      {live.length > 0 ? (
        <span className="mt-3 block space-y-1.5 border-t border-line pt-2.5">
          {live.slice(0, MOVING_SHOWN).map((entry) => (
            <span key={entry.pkg.id} className="flex items-center gap-2.5 text-sm">
              <Pip failed={entry.failed} stage={entry.stage} />
              <span className="min-w-0 flex-1 truncate text-ink/90">{entry.pkg.title}</span>
              <StageWord view={entry} />
            </span>
          ))}
          {live.length > MOVING_SHOWN ? <span className="block pl-[18px] font-mono text-[11px] text-faint">+{live.length - MOVING_SHOWN} more</span> : null}
        </span>
      ) : null}
    </>
  );
}

const CARD_STATE = { working: { label: "Working", tone: "text-build" }, review_ci: { label: "Review/CI", tone: "text-review" }, merged: { label: "Merged", tone: "text-merge/80" }, done: { label: "Done", tone: "text-dim" } };
const CARD_ORDER = { review_ci: 0, working: 1, merged: 2, done: 3 };
const CARD_PIP = { working: "implementing", review_ci: "review_ci", merged: "ended", done: "ended" } as const;

// Small work without a goal: its state, checks, review and PR, and a way to clear it off.
function SmallWork({ cards }: { cards: Cards }) {
  const sorted = [...cards].sort((left, right) => CARD_ORDER[left.state] - CARD_ORDER[right.state] || right.since - left.since);
  if (sorted.length === 0) return null;

  return (
    <>
      <Heading count={cards.length}>Small work</Heading>
      <ul className="space-y-px">
        <Presence items={sorted} keyOf={(card) => card.id}>
          {({ item, key, ref }) => <SmallRow key={key} ref={ref} card={item} />}
        </Presence>
      </ul>
    </>
  );
}

// One card. A dismissal the backend refuses says why under the task.
function SmallRow({ card, ref }: { card: Cards[number]; ref: (node: HTMLElement | null) => void }) {
  const act = useAct();
  const dismissal: OperatorAction = { kind: "dismiss", cardIds: [card.id] };
  const failure = useOperation(dismissal).refused?.reason ?? null;
  const ended = card.state === "merged" || card.state === "done";
  const dismiss = () => void act(dismissal);

  return (
    <li ref={ref} className="flex items-start gap-3 bg-white/[0.035] py-1 pl-[var(--inset-l)] pr-[max(0.25rem,env(safe-area-inset-right))]">
      <span className="mt-[15px] flex">
        <Pip stage={CARD_PIP[card.state]} failed={card.ci === "failing" && !ended} />
      </span>
      <span className="min-w-0 flex-1 py-2">
        <span className={`block text-sm leading-snug [overflow-wrap:anywhere] ${ended ? "text-dim" : "text-ink"}`}>{card.task}</span>
        <span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5">
          <span className={`font-mono text-[11px] font-semibold ${CARD_STATE[card.state].tone}`}>{CARD_STATE[card.state].label}</span>
          <CiCell ci={card.ci} stale={card.stale.includes("github")} />
          <ReviewCell review={card.review} />
          <PrLink className="-mx-2.5 -my-3.5 px-2.5 py-3.5" pr={card.pr} repos={[card.repo.toLowerCase()]} />
        </span>
        {failure ? (
          <span className="mt-1 block text-xs text-fail" role="alert">
            {failure}
          </span>
        ) : null}
      </span>
      <button aria-label={`Dismiss ${card.task}`} className="flex size-11 shrink-0 items-center justify-center rounded-md text-faint active:bg-line" type="button" onClick={dismiss}>
        <X className="size-4" />
      </button>
    </li>
  );
}

// Goals that ask for nothing, folded under one line each kind. A goal opens on its own screen with its actions.
function Shelf({ at, label, onOpen, views }: { at: number; label: string; onOpen: (goalId: string) => void; views: GoalView[] }) {
  if (views.length === 0) return null;
  const landed = label.startsWith("Landed");
  return (
    <details className="group mt-6 border-t border-line" open={landed}>
      <summary className={`flex min-h-12 cursor-pointer list-none items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint [&::-webkit-details-marker]:hidden ${INSET}`}>
        <ChevronRight aria-hidden className="size-3.5 transition-transform group-open:rotate-90 motion-reduce:transition-none" />
        {label} · {views.length}
      </summary>
      <ul>
        {views.map((view) => (
          <li key={view.goal.id} data-goal={view.goal.id}>
            <button className={`flex min-h-12 w-full items-center gap-3 py-2 text-left active:bg-white/[0.04] ${INSET}`} type="button" onClick={() => onOpen(view.goal.id)}>
              {landed ? <Check aria-hidden className="size-4 shrink-0 text-merge" /> : null}
              <span className="min-w-0 flex-1">
                <span className="block text-sm leading-snug text-ink/90 [overflow-wrap:anywhere]">{view.goal.title}</span>
                <span className="mt-0.5 flex flex-wrap items-center gap-x-2 text-[11px] text-faint">
                  <span className="uppercase tracking-[0.12em]">{areaLabel(view.goal.area)}</span>
                  {landed ? <Deploy at={at} goal={view.goal} /> : null}
                  {view.goal.report?.parked ? <span className="normal-case">{view.goal.report.parked.text}</span> : null}
                </span>
              </span>
              <span className="shrink-0 font-mono text-[11px] text-faint">{span(at - (view.goal.archivedAt ?? view.goal.report?.parked?.at ?? view.lastMoveAt))}</span>
            </button>
          </li>
        ))}
      </ul>
    </details>
  );
}
