import { afterEach, expect, it, vi } from "vitest";

import { answered, dismiss, recheck, track, unarrivedAnswers } from "./delivery";
import { demoLedger } from "./mock";
import { buildBoard } from "./model";
import { send } from "./operator";

const NOW = Date.parse("2026-11-10T12:00:00Z");
const askOf = (askId: string) => buildBoard(demoLedger(NOW).hydrated, {}).board.asks.find((ask) => ask.id === askId)!;

// The factory: an answer is saved and starts being typed; the delivery route then says how that ended.
function factory(outcomes: Array<Record<string, unknown> | null>) {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === "POST") return Response.json({ ok: true, delivery: { state: "pending" }, delivery_route: `${url.replace("/answer", "")}/delivery` });
    return Response.json({ delivery: outcomes.shift() ?? null });
  });
  vi.stubGlobal("fetch", fetch);
  return fetch;
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

it("an answer cut short shows as undelivered with what was answered, and is never typed again by itself", async () => {
  vi.useFakeTimers();
  const fetch = factory([{ state: "pending" }, { state: "not_delivered", reason: "delivery_interrupted" }]);
  const ask = askOf("ask-slack");
  track(ask, "Added.");
  await send({ kind: "answer", askId: ask.id, answer: { text: "Added." } });
  expect(unarrivedAnswers()).toEqual([]);

  // The stream says nothing; the board looks again once the factory would have given up on the send.
  await vi.advanceTimersByTimeAsync(62e3);
  expect(unarrivedAnswers()).toEqual([]);
  await vi.advanceTimersByTimeAsync(30e3);
  expect(unarrivedAnswers()).toEqual([{ ask, answer: "Added.", reason: "delivery_interrupted" }]);

  await vi.advanceTimersByTimeAsync(10 * 60e3);
  expect(fetch.mock.calls.filter(([, init]) => init?.method === "POST")).toHaveLength(1);
  dismiss(ask.id);
  expect(unarrivedAnswers()).toEqual([]);
});

it("an answer typed into its terminal leaves nothing behind", async () => {
  factory([{ state: "delivered", to: "jjdesktop/t2dq" }]);
  const ask = askOf("ask-release");
  track(ask, "Release only the owner");
  answered(ask.id, { state: "pending" }, "/asks/ask-release/delivery");
  await recheck();
  expect(unarrivedAnswers()).toEqual([]);
  // Once settled it is not looked at again.
  await recheck();
  expect(vi.mocked(fetch)).toHaveBeenCalledTimes(1);
});

it("an undelivered answer is still there after the board reloads", async () => {
  const kept = new Map<string, string>();
  vi.stubGlobal("window", { localStorage: { getItem: (key: string) => kept.get(key) ?? null, setItem: (key: string, value: string) => kept.set(key, value) } });
  const ask = askOf("ask-vod");
  track(ask, "Yes, drop them.");
  answered(ask.id, { state: "not_delivered", reason: "send_failed" }, "/asks/ask-vod/delivery");

  vi.resetModules();
  const reloaded = await import("./delivery");
  expect(reloaded.unarrivedAnswers()).toEqual([{ ask, answer: "Yes, drop them.", reason: "send_failed" }]);
  reloaded.dismiss(ask.id);
  dismiss(ask.id);
});

it("an answer with no terminal to type into is undelivered at once", async () => {
  factory([]);
  const ask = askOf("ask-vod");
  track(ask, "Yes, drop them.");
  answered(ask.id, { state: "not_delivered", reason: "no_asking_terminal" }, "/asks/ask-vod/delivery");
  expect(unarrivedAnswers()).toEqual([{ ask, answer: "Yes, drop them.", reason: "no_asking_terminal" }]);
  dismiss(ask.id);
});
