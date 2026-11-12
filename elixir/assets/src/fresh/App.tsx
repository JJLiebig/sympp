import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { flushSync } from "react-dom";

import { api } from "./api";
import { setAreas, type AreaRule } from "./areas";
import { NeedsYou } from "./asks";
import { lanesOf, Rest } from "./board";
import { Briefing } from "./briefing";
import { Cards, visibleCards } from "./cards";
import { Decisions } from "./decisions";
import { answered, readDeliveriesWith, recheck, useUnarrived } from "./delivery";
import { applyDemo, demoDelivery, demoLedger, type DemoLedger, type DemoVariant } from "./mock";
import { buildBoard, liveCountAt, openAt, viewAt, type Board, type HistoryEvent, type Settings } from "./model";
import { focusGoal } from "./motion";
import { ActContext, send, type OperatorAction } from "./operator";
import { Outline } from "./outline";
import { operate, project, usePending } from "./pending";
import { boardReads, listen, readBoard, type Fetched, type Read } from "./reads";
import { Phases } from "./phases";
import { PhoneBoard, usePhone } from "./phone";
import { DensityContext, type Density } from "./report";
import { setSamples, type SampleRule } from "./samples";
import { BoardMenu } from "./settings";
import { changesBetween, SinceContext, SinceLine } from "./since";
import { Status, useTabSignal } from "./status";

const DIRECTIONS = [
  { key: "outline", label: "Outline", hint: "Goals that open themselves", view: Outline, width: "max-w-[1280px]" },
  { key: "briefing", label: "Briefing", hint: "Each goal reports in", view: Briefing, width: "max-w-[1280px]" },
  { key: "phases", label: "Phases", hint: "Where each goal is on its route", view: Phases, width: "max-w-[1280px]" },
] as const;
const DENSITIES: Array<{ key: Density; label: string; hint: string }> = [
  { key: "closed", label: "Collapsed", hint: "Headlines only" },
  { key: "attention", label: "Attention", hint: "Open only the goals that need your answer" },
  { key: "active", label: "Active", hint: "Every goal shows what is moving now" },
  { key: "open", label: "Expanded", hint: "Every goal shows done, now and up next" },
];
const REPLAY_DAYS = 10;
const STEP_MS = 15 * 60 * 1000;
// A frozen snapshot never changes, so there the sketch pretends the last visit was three hours ago.
const AWAY_MS = 3 * 3600e3;
const SEEN_KEY = "sympp.board.seenAt";
// Change signals keep the board current. A slow reread covers a signal lost without the stream dropping; between
// reads the board's clock still moves, so the time each package has spent does too.
const REREAD_MS = 5 * 60e3;
const CLOCK_MS = 60e3;

// `vite --mode demo` runs the board on invented work with no backend. `?demo=quiet` shows it with nobody waiting, `?demo=empty` with nothing on it.
const DEMO = import.meta.env.MODE === "demo";
// A link can open the board on a view, a density and an area: `?view=phases&show=open&area=Herdr`.
const LINKED = typeof window === "undefined" ? new URLSearchParams() : new URLSearchParams(window.location.search);
const START = {
  direction: Math.max(0, DIRECTIONS.findIndex((entry) => entry.key === LINKED.get("view"))),
  density: DENSITIES.find((entry) => entry.key === LINKED.get("show"))?.key ?? "active",
};

// `replayable` is true on a snapshot, which carries recorded history; a backend only knows the present.
type Loaded = { board: Board; now: number; busiest: number; samples: number[]; replayable: boolean; settings: Settings };
// A read and what it was read from, which the next read asks with; null when the backend said nothing changed.
type Fresh = Read<Loaded> | null;

export function App() {
  const { loaded, failure, picked, setAt, read } = useLiveBoard();
  const [direction, setDirection] = useState(START.direction);
  const [area, setArea] = useState<string | null>(LINKED.get("area"));
  const [density, setDensity] = useState<Density>(START.density);
  const [seenAt, setSeenAt] = useState<number | null>(rememberedVisit);
  const [replay, setReplay] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const act = useOperator(read);
  const unarrived = useUnarrived();
  useShortcuts(setDirection, setNote);
  // The board shows what the operator just did before the factory has caught up; see pending.ts.
  const pending = usePending();
  const data = useMemo(() => (loaded ? { ...loaded, board: project(loaded.board, pending) } : null), [loaded, pending]);

  const phone = usePhone();
  const at = shownAt(phone, data, picked);
  const since = lastLookAt(seenAt, at, data?.replayable !== false);
  const markSeen = () => {
    rememberVisit(at);
    setSeenAt(at);
  };
  // An ask can sit in an area that is filtered out, so the filter is lifted before jumping to its goal.
  const goToGoal = (goalId: string) => {
    flushSync(() => setArea(null));
    focusGoal(goalId);
  };
  const { views, changes, asks, areas, shown, cards, shownCards, lanes, grouped } = useShaped(data, at, since, area);
  const directions = DIRECTIONS.filter((entry) => entry.key !== "phases" || grouped);
  const current = directions.find((entry) => entry.key === DIRECTIONS[direction]?.key) ?? directions[0];
  const View = current.view;
  useTabSignal(asks.length + unarrived.length);

  if (!data) return <Unread failure={failure} />;
  // A phone gets its own arrangement of the same views; see phone.tsx.
  if (phone) {
    return (
      <ActContext.Provider value={act}>
        <SinceContext.Provider value={changes.notes}>
          <PhoneBoard area={area} areas={areas} asks={asks} unarrived={unarrived} at={at} board={data.board} cards={cards} changes={changes} failure={failure} lanes={lanes} settings={data.settings} shownCards={shownCards} since={since} views={views} onArea={setArea} onSaved={read} onSeen={markSeen} />
        </SinceContext.Provider>
        <Toast className="left-4 right-4" note={note} />
      </ActContext.Provider>
    );
  }

  return (
    <div className={`min-h-screen ${replay ? "pb-28" : "pb-10"}`}>
      <header className="sticky top-0 z-20 border-b border-line bg-bg/95 px-4 backdrop-blur sm:px-8">
        <div className="flex min-h-12 flex-wrap items-center gap-x-6 gap-y-1 py-1.5">
          <BoardMenu settings={data.settings} onSaved={read} />
          <nav className="flex shrink-0 gap-1">
            {directions.map((entry, index) => (
              <button key={entry.key} className={`rounded px-2.5 py-1 text-xs ${entry.key === current.key ? "bg-ink text-bg" : "text-dim hover:text-ink"}`} title={entry.hint} type="button" onClick={() => setDirection(DIRECTIONS.indexOf(entry))}>
                <span className="mr-1.5 font-mono opacity-60">{index + 1}</span>
                {entry.label}
              </button>
            ))}
          </nav>
          <nav className="flex min-w-0 max-w-full gap-1 overflow-x-auto whitespace-nowrap text-xs [scrollbar-width:none]">
            {[null, ...areas].map((name) => (
              <button key={name ?? "all"} className={`rounded px-2 py-1 ${name === area ? "bg-line text-ink" : "text-dim hover:text-ink"}`} type="button" onClick={() => setArea(name)}>
                {name ?? "Everything"}
              </button>
            ))}
          </nav>
          <nav className="flex min-w-0 max-w-full items-center gap-1 overflow-x-auto whitespace-nowrap text-xs [scrollbar-width:none]">
            <span className="mr-1 text-faint">Show</span>
            {DENSITIES.map((entry) => (
              <button key={entry.key} className={`rounded px-2 py-1 ${entry.key === density ? "bg-line text-ink" : "text-dim hover:text-ink"}`} title={entry.hint} type="button" onClick={() => setDensity(entry.key)}>
                {entry.label}
              </button>
            ))}
          </nav>
          <span className="ml-auto flex shrink-0 items-center gap-4">
            {data.replayable ? (
              <button className={`whitespace-nowrap rounded px-2 py-1 font-mono text-[11px] hover:bg-line ${at >= data.now ? "text-faint" : "text-checks"}`} title={`Show or hide the replay bar. Showing ${stamp(at)}`} type="button" onClick={() => setReplay(!replay)}>
                Replay
              </button>
            ) : null}
            <Lost failure={failure} />
            <Status needed={asks.length + unarrived.length} views={views} />
          </span>
        </div>
      </header>
      <main className="px-4 py-6 sm:px-8">
        <SinceLine at={at} changes={changes} since={since} width={current.width} onPick={goToGoal} onSeen={markSeen} />
        <ActContext.Provider value={act}>
          <div className={`mx-auto ${current.width}`}>
            <NeedsYou asks={asks} at={at} unarrived={unarrived} board={data.board} views={views} onGoal={goToGoal} />
            <Decisions at={at} board={data.board} decisions={data.board.decisions.filter((entry) => entry.at <= at)} onGoal={goToGoal} />
          </div>
          {/* Switching the view, the area or the density draws the board afresh, so the switch itself never animates. */}
          <Fragment key={`${current.key}:${area ?? ""}:${density}`}>
            <SinceContext.Provider value={changes.notes}>
              <DensityContext.Provider value={density}>
                <View at={at} views={shown} />
              </DensityContext.Provider>
            </SinceContext.Provider>
            <div className={`mx-auto ${current.width}`}>
              <Cards at={at} cards={shownCards} />
              <Rest at={at} lanes={lanes} />
            </div>
          </Fragment>
        </ActContext.Provider>
      </main>
      {replay ? <Scrubber at={at} data={data} onChange={setAt} /> : null}
      <Toast className="left-1/2 max-w-xl -translate-x-1/2" note={note} />
    </div>
  );
}

// The board as last read, kept current by the factory's change signals.
function useLiveBoard() {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [picked, setAt] = useState(0);
  // The first read opens on the busiest moment; later reads keep the board live unless it is replaying.
  // Background changes share a read and one catch-up; actions, timers and reconnects supersede earlier reads to
  // recover and respect committed writes: a read started before a write the factory agreed to is thrown away.
  const [{ read, changed, tick }] = useState(() => {
    let shownNow: number | null = null;
    let readAt = { now: 0, wall: 0 };
    const follow = (now: number) => {
      const before = shownNow;
      shownNow = now;
      return (current: number) => followNow(current, before ?? now, now);
    };
    const reads = boardReads(load, (fresh: Fresh) => {
      setFailure(null);
      // Nothing changed: the board stays as it is.
      if (!fresh) return;
      const first = shownNow === null;
      readAt = { now: fresh.loaded.now, wall: Date.now() };
      const moved = follow(fresh.loaded.now);
      setLoaded(fresh.loaded);
      setAt((current) => (first ? fresh.loaded.busiest : moved(current)));
    }, (caught: unknown) => {
      setFailure(caught instanceof Error ? caught.message : "Could not read the ledger");
    });
    const tick = () => {
      if (shownNow === null) return;
      const now = readAt.now + Date.now() - readAt.wall;
      const moved = follow(now);
      setLoaded((current) => (current ? { ...current, now } : current));
      setAt(moved);
    };
    return { ...reads, tick };
  });
  // The stream is opened before the first read, so a change made meanwhile is read too.
  useChangeSignal(!DEMO, read, changed);
  useEffect(() => { void read(); }, [read]);
  // A snapshot or the demo never changes on its own, so it is read once. Anything else is reread, also while the first read has yet to succeed.
  const live = !DEMO && loaded?.replayable !== true;
  useEvery(live, REREAD_MS, read);
  useEvery(live, CLOCK_MS, tick);
  return { loaded, failure, picked, setAt, read };
}

// Every action goes the same way: shown as done at once, sent, then the board is read again. The demo's own
// ledger stands in for the factory.
function useOperator(read: () => void) {
  return useCallback((action: OperatorAction) => operate(action, DEMO ? demoSend : send, read), [read]);
}

// What the board shows at `at`, with the area filter applied to goals and cards. Questions and decisions ignore the filter.
function useShaped(data: Loaded | null, at: number, since: number, area: string | null) {
  const views = useMemo(() => (data ? viewAt(data.board, at) : []), [at, data]);
  const changes = useMemo(() => changesBetween(data ? viewAt(data.board, since) : [], views), [data, since, views]);
  const cards = useMemo(() => (data ? visibleCards(data.board.cards, at) : []), [at, data]);
  const open = views.filter((view) => view.phase !== "done" && view.phase !== "archived");
  const areas = [...new Set([...open.map((view) => view.goal.area[0]), ...cards.map((card) => card.area[0])])];
  const shown = area ? views.filter((view) => view.goal.area[0] === area) : views;
  // Phases has nothing to add until a goal on the board is grouped, so it is offered only then.
  const grouped = lanesOf(views, at).main.some((view) => view.goal.pkgs.some((pkg) => pkg.group));
  return { views, changes, asks: data?.board.asks.filter((ask) => openAt(ask, at)) ?? [], areas, shown, cards, shownCards: area ? cards.filter((card) => card.area[0] === area) : cards, lanes: lanesOf(shown, at), grouped };
}

// A short note the board says out loud, such as why a step did not go through.
function Toast({ className, note }: { className: string; note: string | null }) {
  if (!note) return null;
  return <p className={`fixed bottom-24 z-30 rounded bg-ink px-3 py-2 text-sm text-bg ${className}`} role="status">{note}</p>;
}

// A board that has never loaded shows only that it is reading, or why it could not.
function Unread({ failure }: { failure: string | null }) {
  return <p className={`p-10 text-sm ${failure ? "text-fail" : "text-dim"}`}>{failure ?? "Reading the ledger…"}</p>;
}

// A failed read keeps what the board last showed and says so.
function Lost({ failure }: { failure: string | null }) {
  if (!failure) return null;
  return <span className="whitespace-nowrap text-xs text-fail" title={failure}>Connection lost · showing the last read</span>;
}

// The demo's invented work, made on the first read. Actions change it the way the backend would.
if (DEMO) readDeliveriesWith(async (askId) => demoDelivery(askId));
let demo: { ledger: DemoLedger; now: number } | null = null;

function demoNow() {
  if (!demo) {
    const now = Date.now();
    demo = { ledger: demoLedger(now, LINKED.get("demo") === "quiet" || LINKED.get("demo") === "empty" ? LINKED.get("demo") as DemoVariant : "busy"), now };
  }
  return demo;
}

// The demo types an answer into its terminal a moment after it is sent.
async function demoSend(action: OperatorAction) {
  const current = demoNow();
  current.ledger = applyDemo(current.ledger, action, current.now);
  if (action.kind !== "answer") return;
  answered(action.askId, { state: "pending" }, action.askId);
  window.setTimeout(() => void recheck(), 1500);
}

async function load(shown: Fetched | null): Promise<Fresh> {
  if (DEMO) {
    const { ledger, now } = demoNow();
    return { loaded: { board: buildBoard(ledger.hydrated, {}, ledger.archived).board, now, busiest: now, samples: [], replayable: false, settings: {} }, fetched: null };
  }
  const [fetched, history, local] = await Promise.all([
    readBoard(shown),
    sketchOnly<Record<string, HistoryEvent[]>>("/__snapshot/history"),
    sketchOnly<{ areas?: AreaRule[]; samples?: SampleRule[] }>("/__snapshot/local"),
  ]);
  if (!fetched) return null;
  setAreas(local?.areas ?? []);
  setSamples(local?.samples ?? []);
  const { hydrated, archived } = fetched;
  const { board, now } = buildBoard(hydrated.body, history ?? {}, archived?.body ?? null);
  // Against a backend there is no history to replay: the board shows the present.
  const settings = hydrated.body.settings ?? {};
  if (!history) return { loaded: { board, now, busiest: now, samples: [], replayable: false, settings }, fetched };

  const start = now - REPLAY_DAYS * 24 * 3600e3;
  const samples = Array.from({ length: (now - start) / STEP_MS + 1 }, (_unused, index) => liveCountAt(board.goals, start + index * STEP_MS));
  const busiest = start + samples.indexOf(Math.max(...samples)) * STEP_MS;
  return { loaded: { board, now, busiest, samples, replayable: true, settings }, fetched };
}

// These routes exist on the snapshot server only, so only a development server is asked.
async function sketchOnly<T>(path: string): Promise<T | null> {
  if (!import.meta.env.DEV) return null;
  const response = await fetch(path).catch(() => null);
  if (!response?.ok || !response.headers.get("content-type")?.includes("json")) return null;
  return (await response.json()) as T;
}

// The last visit is remembered in this browser only; a private window or cleared data starts over.
function rememberedVisit(): number | null {
  try {
    return Number(window.localStorage.getItem(SEEN_KEY)) || null;
  } catch {
    return null;
  }
}

function rememberVisit(at: number) {
  try {
    window.localStorage.setItem(SEEN_KEY, String(at));
  } catch {
    // Without storage the board still works; it only forgets the visit on reload.
  }
}

function lastLookAt(seenAt: number | null, at: number, replayable: boolean) {
  if (seenAt !== null && seenAt <= at) return seenAt;
  return replayable ? at - AWAY_MS : at;
}

function useEvery(active: boolean, ms: number, run: () => void) {
  useEffect(() => {
    if (!active) return undefined;
    const timer = window.setInterval(run, ms);
    return () => window.clearInterval(timer);
  }, [active, ms, run]);
}

// The phone has no replay bar, so it always shows the present.
function shownAt(phone: boolean, data: Loaded | null, picked: number) {
  return phone && data ? data.now : picked;
}

function followNow(current: number, before: number, now: number) {
  return current >= before ? now : current;
}

// The backend only says that something changed; the board then asks whether its read is still current, and looks
// again at answers still being typed. This stream is also how the backend knows a board is open, so that it does
// not open another one.
function useChangeSignal(active: boolean, read: () => void, changed: () => void) {
  useEffect(() => {
    if (!active) return undefined;
    return listen(api("/dashboard/events"), {
      read: () => {
        read();
        void recheck();
      },
      changed: () => {
        changed();
        void recheck();
      },
    });
  }, [active, read, changed]);
}

function stamp(at: number) {
  return new Date(at).toLocaleString([], { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

// A sketch tool, not part of the product: move through the ledger's history to watch the board change.
function Scrubber({ at, data, onChange }: { at: number; data: Loaded; onChange: (at: number) => void }) {
  const start = data.now - REPLAY_DAYS * 24 * 3600e3;
  const peak = Math.max(1, ...data.samples);
  const path = data.samples.map((value, index) => `${index === 0 ? "M" : "L"}${(index / (data.samples.length - 1)) * 100},${24 - (value / peak) * 22}`).join(" ");
  const live = at >= data.now;

  return (
    <footer className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-bg/95 px-4 py-3 backdrop-blur sm:px-8">
      <div className="flex items-center gap-4 text-xs">
        <span className={`w-64 shrink-0 font-mono ${live ? "text-merge" : "text-checks"}`}>
          {live ? "Now" : "Replaying"} · {stamp(at)}
        </span>
        <div className="relative h-8 flex-1">
          <svg className="absolute inset-0 size-full text-faint" preserveAspectRatio="none" viewBox="0 0 100 24">
            <path d={path} fill="none" stroke="currentColor" strokeWidth="1" vectorEffect="non-scaling-stroke" />
          </svg>
          <input aria-label="Replay time" className="absolute inset-0 w-full cursor-pointer opacity-80" max={data.now} min={start} step={STEP_MS} type="range" value={at} onChange={(event) => onChange(Number(event.target.value))} />
        </div>
        <button className="rounded px-2 py-1 text-dim hover:bg-line hover:text-ink" type="button" onClick={() => onChange(data.busiest)}>Busiest</button>
        <button className="rounded px-2 py-1 text-dim hover:bg-line hover:text-ink" type="button" onClick={() => onChange(data.now)}>Now</button>
      </div>
    </footer>
  );
}

function useShortcuts(setDirection: (index: number) => void, setNote: (note: string | null) => void) {
  useEffect(() => {
    let timer = 0;
    const onKey = (event: KeyboardEvent) => {
      const index = ["1", "2", "3"].indexOf(event.key);
      // Digits typed into a field are text, not a view switch.
      const typing = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement;
      if (index >= 0 && !typing) setDirection(index);
    };
    const onSay = (event: Event) => {
      setNote((event as CustomEvent<string>).detail);
      window.clearTimeout(timer);
      timer = window.setTimeout(() => setNote(null), 6000);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("fresh:say", onSay);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("fresh:say", onSay);
    };
  }, [setDirection, setNote]);
}
