// What became of the answers sent from this board. The factory saves an answer, then types it into the terminal
// that asked; that can fail, or be cut short when the factory restarts mid-send. An answer that arrived is said
// quietly. One that did not stays on the board with its answer to copy, until the operator dismisses it. Nothing is
// typed again by itself: typing an answer twice is not harmless.
import { useSyncExternalStore } from "react";

import type { Ask } from "./model";

export type Delivery = { state: "pending" | "delivered" | "not_delivered"; reason?: string | null };
export type Unarrived = { ask: Ask; answer: string; reason: string | null };

// The factory gives up on a send cut short after a minute; the board looks again just after, even without a change
// signal, and then every half minute while any answer is still being typed.
const SETTLE_MS = 62e3;
const AGAIN_MS = 30e3;

type Entry = { ask: Ask; answer: string; route: string | null; state: "answering" | "pending" | "not_delivered"; reason: string | null };

const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
let unarrived: Unarrived[] = [];
let timer: ReturnType<typeof setTimeout> | null = null;

function changed() {
  unarrived = [...entries.values()].filter((entry) => entry.state === "not_delivered").map(({ ask, answer, reason }) => ({ ask, answer, reason }));
  listeners.forEach((listener) => listener());
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
// leaves the board once answered.
export function track(ask: Ask, answer: string) {
  entries.set(ask.id, { ask, answer, route: null, state: "answering", reason: null });
}

// The factory saved the answer; `delivery` says whether it is being typed or could not be.
export function answered(askId: string, delivery: Delivery | null, route: string | null) {
  const entry = entries.get(askId);
  if (!entry) return;
  entry.route = route;
  apply(askId, entry, delivery);
}

function apply(askId: string, entry: Entry, delivery: Delivery | null) {
  if (delivery?.state === "pending") {
    if (entry.state !== "pending") lookAgain(SETTLE_MS);
    entry.state = "pending";
    return;
  }
  if (delivery?.state === "not_delivered") {
    entries.set(askId, { ...entry, state: "not_delivered", reason: delivery.reason ?? null });
  } else {
    entries.delete(askId);
    if (delivery?.state === "delivered") say("Answer delivered");
  }
  changed();
}

// Looks again at every answer still being typed. Called on each change signal and once the factory would have given up.
export async function recheck() {
  const waiting = [...entries].filter(([, entry]) => entry.state === "pending" && entry.route);
  await Promise.all(
    waiting.map(async ([askId, entry]) => {
      const delivery = await read(entry.route!).catch(() => ({ state: "pending" as const }));
      if (entries.get(askId) === entry) apply(askId, entry, delivery);
    }),
  );
  if ([...entries.values()].some((entry) => entry.state === "pending")) lookAgain(AGAIN_MS);
}

function lookAgain(ms: number) {
  if (timer !== null) return;
  timer = setTimeout(() => {
    timer = null;
    void recheck();
  }, ms);
}

export function dismiss(askId: string) {
  if (entries.delete(askId)) changed();
}

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
