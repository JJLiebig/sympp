import { api } from "./api";
import type { Archived, Board, Hydrated } from "./model";
import { settle } from "./pending";

// Change signals queue one catch-up read without invalidating the active read.
// Explicit reads supersede earlier work, so saves, timers and reconnects can
// recover from a stalled fetch and cannot be overwritten by a pre-save response.
export function coalescedRead<T>(load: () => Promise<T>, show: (value: T) => void, fail: (error: unknown) => void) {
  let running = false;
  let pending = false;
  let sequence = 0;
  const read = async () => {
    const turn = ++sequence;
    pending = false;
    running = true;
    try {
      const value = await load();
      if (turn === sequence) show(value);
    } catch (error) {
      if (turn === sequence) fail(error);
    } finally {
      if (turn === sequence) {
        running = false;
        if (pending) void read();
      }
    }
  };
  const changed = () => {
    if (running) pending = true;
    else void read();
  };
  return { read, changed };
}

// What a route last answered, with its ETag. The board asks with that ETag, and HTTP 304 hands back this same
// object, so a read that changed nothing is told apart by identity.
export type Tagged<T> = { body: T; etag: string | null };
export type Fetched = { hydrated: Tagged<Hydrated>; archived: Tagged<Archived> | null };

export async function conditional<T>(url: string, shown: Tagged<T> | null): Promise<Tagged<T>> {
  const headers: Record<string, string> = { accept: "application/json" };
  if (shown?.etag) headers["if-none-match"] = shown.etag;
  const response = await fetch(url, { headers });
  if (response.status === 304 && shown) return shown;
  // A refused or failed read is an error, not an empty ledger.
  if (!response.ok) throw new Error(`Could not read the ledger (${response.status})`);
  return { body: (await response.json()) as T, etag: response.headers.get("etag") };
}

// Reads the board against what it shows. Null when nothing changed. `shown` must be what the board shows, never a
// read it threw away: that read's ETag would make the next one answer 304 for a board the operator never saw.
export async function readBoard(shown: Fetched | null): Promise<Fetched | null> {
  const [hydrated, archived] = await Promise.all([
    conditional<Hydrated>(api("/dashboard/hydrated"), shown?.hydrated ?? null),
    // Archived goals are read separately. Without them the board still shows everything else.
    conditional<Archived>(api("/dashboard?surface=archived"), shown?.archived ?? null).catch(() => null),
  ]);
  return shown && hydrated === shown.hydrated && archived === shown.archived ? null : { hydrated, archived };
}

// A board read, and the routes it was read from, which the next read asks with.
export type Read<L extends { board: Board }> = { loaded: L; fetched: Fetched | null };

// The board's reads, each against what it shows: `show` gets each read, or null when nothing changed. Every read
// that arrives ends the operator's actions it shows done, even an unchanged one: a change signal can read an
// action's outcome before the factory has answered the action, and the read after its answer is then unchanged.
export function boardReads<L extends { board: Board }>(load: (shown: Fetched | null) => Promise<Read<L> | null>, show: (fresh: Read<L> | null) => void, fail: (error: unknown) => void) {
  let shown: Read<L> | null = null;
  return coalescedRead(() => load(shown?.fetched ?? null), (fresh: Read<L> | null) => {
    if (fresh) shown = fresh;
    if (shown) settle(shown.loaded.board);
    show(fresh);
  }, fail);
}

// After a dropped stream, wait longer each time it fails again.
const RETRY_MS = [1e3, 2e3, 5e3, 10e3, 30e3];

// The backend says when the board changed; the board then reads again. The stream reconnects after it drops, and
// every connect reads, because changes missed meanwhile are not replayed. The first connect queues behind the
// board's first read, so a change made before the stream was listening is still read.
export function listen(url: string, { read, changed }: { read: () => void; changed: () => void }) {
  let stream: EventSource | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let failures = 0;
  let connected = false;
  const connect = () => {
    const current = new EventSource(url);
    stream = current;
    current.addEventListener("open", () => {
      failures = 0;
      // A reconnect also gets past a read that stalled with the connection.
      if (connected) read();
      else changed();
      connected = true;
    });
    current.addEventListener("dashboard_changed", changed);
    current.addEventListener("error", () => {
      if (stream !== current) return;
      current.close();
      stream = null;
      timer = setTimeout(connect, RETRY_MS[Math.min(failures++, RETRY_MS.length - 1)]);
    });
  };
  connect();
  return () => {
    clearTimeout(timer);
    stream?.close();
    stream = null;
  };
}
