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

// A browser's storage shared by board tabs, which hears what another tab stores.
function browser() {
  const kept = new Map<string, string>();
  const window = Object.assign(new EventTarget(), { localStorage: { getItem: (key: string) => kept.get(key) ?? null, setItem: (key: string, value: string) => kept.set(key, value) } });
  vi.stubGlobal("window", window);
  return {
    // Another tab stores the board's answers as this one would.
    otherTab: (value: string) => window.dispatchEvent(Object.assign(new Event("storage"), { key: "sympp.board.answers", newValue: value })),
    stored: () => kept.get("sympp.board.answers") ?? null,
  };
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

it("an undelivered answer is still there after the board reloads, and in the board's other tabs", async () => {
  const storage = browser();
  const open = async () => {
    vi.resetModules();
    return import("./delivery");
  };
  const tab = await open();
  const ask = askOf("ask-vod");
  tab.track(ask, "Yes, drop them.");
  tab.answered(ask.id, { state: "not_delivered", reason: "send_failed" }, "/asks/ask-vod/delivery");

  const reloaded = await open();
  expect(reloaded.unarrivedAnswers()).toEqual([{ ask, answer: "Yes, drop them.", reason: "send_failed" }]);
  // The reloaded tab dismisses it; the first one stops showing it too.
  reloaded.dismiss(ask.id);
  storage.otherTab(storage.stored()!);
  expect(tab.unarrivedAnswers()).toEqual([]);
});

it("an answer another tab was still sending when it closed is looked at from this one", async () => {
  vi.useFakeTimers();
  const storage = browser();
  const open = async () => {
    vi.resetModules();
    return import("./delivery");
  };
  const tab = await open();
  const sender = await open();
  const ask = askOf("ask-slack");
  sender.track(ask, "Added.");
  storage.otherTab(storage.stored()!);
  // The sending tab closes before the factory's answer comes back; the factory had saved it.
  factory([{ state: "not_delivered", reason: "delivery_interrupted" }]);
  await vi.advanceTimersByTimeAsync(60e3);
  expect(tab.unarrivedAnswers()).toEqual([{ ask, answer: "Added.", reason: "delivery_interrupted" }]);
});

it("an answer whose response never came back is followed, and a refused retry neither replaces nor drops it", async () => {
  browser();
  vi.stubGlobal("fetch", vi.fn(async (_url: string, init?: RequestInit) => {
    if (init?.method === "POST") throw new TypeError("network");
    return Response.json({ delivery: { state: "not_delivered", reason: "terminal_finished" } });
  }));
  const ask = askOf("ask-slack");
  track(ask, "Added.");
  await expect(send({ kind: "answer", askId: ask.id, answer: { text: "Added." } })).rejects.toThrow();
  // The first answer went through after all, so a second one is refused.
  const network = vi.mocked(fetch).getMockImplementation()!;
  vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => (init?.method === "POST" ? Response.json({ error: { code: "ask_not_open" } }, { status: 409 }) : network(url, init))));
  track(ask, "Something else.");
  await expect(send({ kind: "answer", askId: ask.id, answer: { text: "Something else." } })).rejects.toThrow();
  await recheck();
  expect(unarrivedAnswers()).toEqual([{ ask, answer: "Added.", reason: "terminal_finished" }]);
  dismiss(ask.id);

  // A refused first answer has nothing to follow.
  track(ask, "Added.");
  await expect(send({ kind: "answer", askId: ask.id, answer: { text: "Added." } })).rejects.toThrow();
  await recheck();
  expect(unarrivedAnswers()).toEqual([]);
  expect(vi.mocked(fetch).mock.calls.filter(([, init]) => init?.method !== "POST")).toHaveLength(1);
});

it("an answer with no terminal to type into is undelivered at once", async () => {
  factory([]);
  const ask = askOf("ask-vod");
  track(ask, "Yes, drop them.");
  answered(ask.id, { state: "not_delivered", reason: "no_asking_terminal" }, "/asks/ask-vod/delivery");
  expect(unarrivedAnswers()).toEqual([{ ask, answer: "Yes, drop them.", reason: "no_asking_terminal" }]);
  dismiss(ask.id);
});
