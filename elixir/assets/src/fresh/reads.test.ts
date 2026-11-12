import { afterEach, expect, it, vi } from "vitest";

import { applyDemo, demoLedger, type DemoLedger } from "./mock";
import { buildBoard, openAt, type Board } from "./model";
import type { OperatorAction } from "./operator";
import { operate, project, pendingActions } from "./pending";
import { boardReads, coalescedRead, listen, readBoard, type Fetched, type Read } from "./reads";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

it("publishes answered asks despite continuous invalidations and catches up after a failed read", async () => {
  const first = deferred<string[]>();
  const answered = deferred<string[]>();
  const failed = deferred<string[]>();
  const recovered = deferred<string[]>();
  const load = vi.fn()
    .mockReturnValueOnce(first.promise)
    .mockReturnValueOnce(answered.promise)
    .mockReturnValueOnce(failed.promise)
    .mockReturnValueOnce(recovered.promise);
  const show = vi.fn();
  const fail = vi.fn();
  const { read, changed } = coalescedRead(load, show, fail);
  void read();
  // More changes than the dashboard can read: they must not discard its results
  // or start concurrent reads. The next read contains the committed answer.
  for (let i = 0; i < 20; i++) changed();
  expect(load).toHaveBeenCalledTimes(1);
  first.resolve(["open-ask"]);
  await first.promise;
  expect(show).toHaveBeenLastCalledWith(["open-ask"]);
  expect(load).toHaveBeenCalledTimes(2);
  changed();
  answered.resolve([]);
  await answered.promise;
  expect(show).toHaveBeenLastCalledWith([]);
  expect(load).toHaveBeenCalledTimes(3);
  changed();
  const offline = new Error("offline");
  failed.reject(offline);
  await failed.promise.catch(() => undefined);
  expect(fail).toHaveBeenCalledWith(offline);
  recovered.resolve([]);
  await recovered.promise;
  expect(show).toHaveBeenCalledTimes(3);
  expect(load).toHaveBeenCalledTimes(4);
  // A later timer or reconnect can start another read after the queue drains.
  load.mockResolvedValueOnce(["new-ask"]);
  await read();
  expect(show).toHaveBeenLastCalledWith(["new-ask"]);
});

it("explicit refreshes recover from stalled reads and reject pre-save data and errors", async () => {
  const stalled = deferred<string>();
  const preSave = deferred<string>();
  const load = vi.fn().mockReturnValueOnce(stalled.promise).mockReturnValueOnce(preSave.promise).mockResolvedValue("saved");
  const show = vi.fn();
  const fail = vi.fn();
  const { read, changed } = coalescedRead(load, show, fail);
  const initial = read();
  changed();
  const beforeSave = read();
  changed();
  // The successful save starts its own read despite both earlier fetches hanging.
  await read();
  expect(show).toHaveBeenLastCalledWith("saved");
  preSave.resolve("old settings");
  await beforeSave;
  stalled.reject(new Error("old connection"));
  await initial;
  expect(show).toHaveBeenCalledExactlyOnceWith("saved");
  expect(fail).not.toHaveBeenCalled();
  expect(load).toHaveBeenCalledTimes(3);
});

// The factory as the board reads it: each route answers with its ETag, and 304 when asked with the current one.
// `hold` keeps the next hydrated read waiting until the test lets it answer.
function factory(start: DemoLedger) {
  let ledger = start;
  let version = 1;
  let hold: Promise<void> | null = null;
  const asked: Array<string | null> = [];
  const etag = () => `"v${version}"`;
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    const tag = (init?.headers as Record<string, string> | undefined)?.["if-none-match"] ?? null;
    const archivedRoute = url.includes("archived");
    if (!archivedRoute) asked.push(tag);
    // What the read answers is fixed when it reaches the factory, however long it then takes to arrive.
    const [body, current] = [archivedRoute ? ledger.archived : ledger.hydrated, etag()];
    if (!archivedRoute && hold) await hold;
    if (tag === current) return new Response(null, { status: 304 });
    return new Response(JSON.stringify(body), { status: 200, headers: { etag: current } });
  });
  vi.stubGlobal("fetch", fetch);
  return {
    asked,
    fetch,
    change(next: DemoLedger) {
      ledger = next;
      version += 1;
    },
    get ledger() {
      return ledger;
    },
    holdNext() {
      let release!: () => void;
      hold = new Promise<void>((yes) => { release = yes; });
      return () => {
        hold = null;
        release();
      };
    },
  };
}

class FakeStream {
  static opened: FakeStream[] = [];
  closed = false;
  private listeners = new Map<string, Array<() => void>>();
  constructor(readonly url: string) {
    FakeStream.opened.push(this);
  }
  addEventListener(type: string, listener: () => void) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  close() {
    this.closed = true;
  }
  emit(type: string) {
    if (!this.closed) this.listeners.get(type)?.forEach((listener) => listener());
  }
}

// The board's read path, as App wires it: change signals and reconnects read against what is shown.
async function load(shown: Fetched | null) {
  const fetched = await readBoard(shown);
  return fetched && { loaded: { board: buildBoard(fetched.hydrated.body, {}).board }, fetched };
}

function liveBoard() {
  let shown: Board | null = null;
  const show = vi.fn((fresh: Read<{ board: Board }> | null) => {
    if (fresh) shown = fresh.loaded.board;
  });
  const { read, changed } = boardReads(load, show, (error) => { throw error; });
  FakeStream.opened = [];
  vi.stubGlobal("EventSource", FakeStream);
  const stop = listen("/events", { read, changed });
  const openAsks = () => (shown ? project(shown, pendingActions()).asks.filter((ask) => openAt(ask, Infinity)).map((ask) => ask.id) : []);
  return { read, show, stop, openAsks, stream: () => FakeStream.opened.at(-1)! };
}

const NOW = Date.parse("2026-11-10T12:00:00Z");

it("a change signal reads again with the shown ETag: 304 changes nothing, another client's change appears", async () => {
  const server = factory(demoLedger(NOW));
  const board = liveBoard();
  board.stream().emit("open");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(1));
  expect(board.openAsks()).toContain("ask-slack");

  board.stream().emit("dashboard_changed");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(2));
  expect(server.asked).toEqual([null, '"v1"']);
  expect(board.show).toHaveBeenLastCalledWith(null);

  // Someone else answers the question; only the signal tells this board.
  server.change(applyDemo(server.ledger, { kind: "answer", askId: "ask-slack", answer: { text: "Added." } }, NOW));
  board.stream().emit("dashboard_changed");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(3));
  expect(board.openAsks()).not.toContain("ask-slack");
  board.stop();
});

it("a dropped stream reconnects later each time, and reads on every connect", async () => {
  vi.useFakeTimers();
  factory(demoLedger(NOW));
  const board = liveBoard();
  board.stream().emit("open");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(1));

  board.stream().emit("error");
  board.stream().emit("error");
  expect(FakeStream.opened).toHaveLength(1);
  await vi.advanceTimersByTimeAsync(1000);
  expect(FakeStream.opened).toHaveLength(2);
  board.stream().emit("error");
  await vi.advanceTimersByTimeAsync(1000);
  expect(FakeStream.opened).toHaveLength(2);
  await vi.advanceTimersByTimeAsync(1000);
  expect(FakeStream.opened).toHaveLength(3);

  // Changes made while it was away are not replayed, so a connect reads.
  board.stream().emit("open");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(2));
  board.stop();
  await vi.advanceTimersByTimeAsync(60e3);
  expect(FakeStream.opened.every((stream) => stream.closed)).toBe(true);
});

it("an action whose outcome a change signal read first ends when the factory agrees, though the next read is unchanged", async () => {
  const server = factory(demoLedger(NOW));
  const board = liveBoard();
  board.stream().emit("open");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(1));

  // The factory commits and signals before its answer to the action reaches the board.
  const ack: OperatorAction = { kind: "ack", decisionId: "dec-alerts-scope" };
  const agreed = operate(ack, async (action) => {
    server.change(applyDemo(server.ledger, action, NOW));
    board.stream().emit("dashboard_changed");
    await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(2));
  }, () => void board.read());
  expect(await agreed).toBeNull();
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(3));
  expect(board.show).toHaveBeenLastCalledWith(null);
  expect(pendingActions()).not.toContainEqual(ack);
  board.stop();
});

it("a read started before an agreed answer is thrown away and cannot bring the question back", async () => {
  const server = factory(demoLedger(NOW));
  const board = liveBoard();
  board.stream().emit("open");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(1));

  // Something else changed, and its read reaches the factory before the answer does.
  server.change(server.ledger);
  const release = server.holdNext();
  board.stream().emit("dashboard_changed");
  await vi.waitFor(() => expect(server.asked).toHaveLength(2));

  const answer: OperatorAction = { kind: "answer", askId: "ask-slack", answer: { text: "Added." } };
  expect(await operate(answer, async (action) => server.change(applyDemo(server.ledger, action, NOW)), () => void board.read())).toBeNull();
  release();
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(2));
  await new Promise((resolve) => setTimeout(resolve, 0));
  // Only the read after the answer was shown, and once it shows the answer the pending action ends.
  expect(board.show).toHaveBeenCalledTimes(2);
  expect(board.show.mock.lastCall?.[0]?.fetched?.hydrated.etag).toBe('"v3"');
  expect(pendingActions()).not.toContainEqual(answer);
  expect(board.openAsks()).not.toContain("ask-slack");

  // The shown read is the one after the answer, so the next signal asks with its ETag and is told nothing changed.
  board.stream().emit("dashboard_changed");
  await vi.waitFor(() => expect(board.show).toHaveBeenCalledTimes(3));
  expect(board.show).toHaveBeenLastCalledWith(null);
  expect(server.asked.at(-1)).toBe('"v3"');
  board.stop();
});
