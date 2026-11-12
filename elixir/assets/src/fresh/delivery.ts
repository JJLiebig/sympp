// What became of the answers sent from this board. The factory saves an answer, then types it into the terminal
// that asked; that can fail, or be cut short when the factory restarts mid-send. An answer that arrived is said
// quietly. One that did not stays on the board with its answer to copy, until the operator dismisses it. Nothing is
// typed again by itself: typing an answer twice is not harmless.
import { useSyncExternalStore } from "react";

import { api } from "./api";
import type { Ask } from "./model";

export type Delivery = { state: "pending" | "delivered" | "not_delivered"; reason?: string | null };
export type Unarrived = { ask: Ask; answer: string; reason: string | null };

// Kept in this browser from the moment an answer is sent, so it survives a reload and every board tab shares it.
// Each answer has its own key, so tabs that write at once never overwrite each other's answers.
const PREFIX = "sympp.board.answer:";

// The factory gives up on a send cut short after a minute; the board looks again just after, even without a change
// signal, and then every half minute while any answer is still being typed.
const SETTLE_MS = 62e3;
const AGAIN_MS = 30e3;
// An answer still marked as being sent after this long had its send end without word, such as in a tab that closed
// or reloaded: its delivery says whether the factory saved it.
const SENT_MS = 30e3;

// `at` is when the answer was sent.
type Entry = { ask: Ask; answer: string; route: string; at: number; state: "answering" | "pending" | "not_delivered"; reason: string | null };
const followed = (entry: Entry) => entry.state === "pending" || (entry.state === "answering" && Date.now() - entry.at > SENT_MS);
const unsettled = () => [...entries.values()].some((entry) => entry.state !== "not_delivered");

const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
let unarrived: Unarrived[] = [];
let timer: ReturnType<typeof setTimeout> | null = null;

function shown() {
  unarrived = [...entries.values()].filter((entry) => entry.state === "not_delivered").map(({ ask, answer, reason }) => ({ ask, answer, reason }));
  listeners.forEach((listener) => listener());
}

function changed(askId: string) {
  save(askId);
  shown();
}

function save(askId: string) {
  try {
    const entry = entries.get(askId);
    if (entry) window.localStorage.setItem(PREFIX + askId, JSON.stringify(entry));
    else window.localStorage.removeItem(PREFIX + askId);
  } catch {
    // Without storage the board still follows its answers; it only forgets them on reload.
  }
}

// Takes in one answer as stored; null when it is gone.
function take(key: string | null, value: string | null) {
  if (!key?.startsWith(PREFIX)) return;
  const askId = key.slice(PREFIX.length);
  try {
    if (value === null) entries.delete(askId);
    else entries.set(askId, JSON.parse(value) as Entry);
  } catch {
    // An unreadable record is skipped.
  }
}

// Answers still being typed, or sent without word back, are looked at again on the board's first change signal, or
// shortly without one.
function restore() {
  try {
    const storage = window.localStorage;
    for (let index = 0; index < storage.length; index++) {
      const key = storage.key(index);
      take(key, key && storage.getItem(key));
    }
    // Another board tab answered, settled or dismissed something.
    window.addEventListener("storage", (event) => {
      take(event.key, event.newValue);
      shown();
      // This tab looks too, in case the tab that sent it closes.
      if (unsettled()) lookAgain(AGAIN_MS);
    });
  } catch {
    // Storage is unavailable.
  }
  shown();
  if (unsettled()) lookAgain(AGAIN_MS);
}

async function readRoute(route: string): Promise<Delivery | null> {
  const response = await fetch(route, { headers: { accept: "application/json" } });
  // An ask the factory no longer knows has nothing left to report.
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Could not read the delivery (${response.status})`);
  return ((await response.json()) as { delivery?: Delivery | null }).delivery ?? null;
}

let read = readRoute;

// The demo has no factory and says itself what became of each answer.
export function readDeliveriesWith(reader: (route: string) => Promise<Delivery | null>) {
  read = reader;
}

// The question and the answer as the operator gave it, kept from the moment they send, since a card's question
// leaves the board once answered. An earlier answer the factory saved, or may have, stays: a retry is refused.
export function track(ask: Ask, answer: string) {
  if (entries.has(ask.id) && entries.get(ask.id)!.state !== "answering") return;
  entries.set(ask.id, { ask, answer, route: api(`/asks/${encodeURIComponent(ask.id)}/delivery`), at: Date.now(), state: "answering", reason: null });
  save(ask.id);
}

// The factory saved the answer; `delivery` says whether it is being typed or could not be. An answer whose send
// got no response is followed as if being typed: if the factory never saved it, its delivery says so.
export function answered(askId: string, delivery: Delivery | null, route: string | null) {
  const entry = entries.get(askId);
  if (!entry) return;
  if (route) entry.route = route;
  apply(askId, entry, delivery);
}

function apply(askId: string, entry: Entry, delivery: Delivery | null) {
  if (delivery?.state === "pending") {
    if (entry.state !== "pending") lookAgain(SETTLE_MS);
    entry.state = "pending";
    save(askId);
    return;
  }
  if (delivery?.state === "not_delivered") {
    entries.set(askId, { ...entry, state: "not_delivered", reason: delivery.reason ?? null });
  } else {
    entries.delete(askId);
    if (delivery?.state === "delivered") say("Answer delivered");
  }
  changed(askId);
}

// Looks again at every answer still being typed. Called on each change signal and once the factory would have given up.
export async function recheck() {
  const waiting = [...entries].filter(([, entry]) => followed(entry));
  await Promise.all(
    waiting.map(async ([askId, entry]) => {
      const delivery = await read(entry.route).catch(() => ({ state: "pending" as const }));
      if (entries.get(askId) === entry) apply(askId, entry, delivery);
    }),
  );
  if (unsettled()) lookAgain(AGAIN_MS);
}

function lookAgain(ms: number) {
  if (timer !== null) return;
  timer = setTimeout(() => {
    timer = null;
    void recheck();
  }, ms);
}

// The factory refused this attempt, so it has nothing to deliver.
export function refused(askId: string) {
  if (entries.get(askId)?.state === "answering") dismiss(askId);
}

export function dismiss(askId: string) {
  if (entries.delete(askId)) changed(askId);
}

restore();

// The answers that did not arrive, oldest sent first. Changes whenever one settles or is dismissed.
export const unarrivedAnswers = () => unarrived;

export function useUnarrived() {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    unarrivedAnswers,
  );
}

function say(note: string) {
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("fresh:say", { detail: note }));
}
