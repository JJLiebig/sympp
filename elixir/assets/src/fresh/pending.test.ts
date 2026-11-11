import { afterEach, expect, it, vi } from "vitest";

import { applyDemo, demoLedger, type DemoLedger } from "./mock";
import { buildBoard, needsReview, openAt, type Board } from "./model";
import { send, type OperatorAction } from "./operator";
import { operate, pendingActions, project, settle } from "./pending";

// The demo ledger stands in for the factory: a send changes it the way the backend would, a read builds the board.
const NOW = Date.parse("2026-11-10T12:00:00Z");
const read = (ledger: DemoLedger) => buildBoard(ledger.hydrated, {}, ledger.archived).board;
const shown = (board: Board) => project(board, pendingActions());
const reviewing = (board: Board) => shown(board).decisions.filter(needsReview).map((decision) => decision.id);
const asking = (board: Board) => shown(board).asks.filter((ask) => openAt(ask, board.readAt)).map((ask) => ask.id);

function deferred() {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

afterEach(() => vi.unstubAllGlobals());

it("an acked decision leaves the board at once, and a second click while it is sent sends nothing", async () => {
  const board = read(demoLedger(NOW));
  const answer = deferred();
  const factory = vi.fn(() => answer.promise);
  const ack: OperatorAction = { kind: "ack", decisionId: "dec-alerts-scope" };
  expect(reviewing(board)).toContain("dec-alerts-scope");

  const first = operate(ack, factory, () => undefined);
  expect(reviewing(board)).not.toContain("dec-alerts-scope");
  const second = operate(ack, factory, () => undefined);
  expect(factory).toHaveBeenCalledTimes(1);

  answer.resolve();
  expect(await first).toBeNull();
  expect(await second).toBeNull();
});

it("a refused decision comes back as the factory has it, with why", async () => {
  const board = read(demoLedger(NOW));
  const before = board.decisions.find((decision) => decision.id === "dec-cards");
  const answer = deferred();
  const reread = vi.fn();

  const sent = operate({ kind: "feedback", decisionId: "dec-cards", text: "Keep cards for chiefs only." }, () => answer.promise, reread);
  // While it is sent, the decision shows the feedback on its way.
  expect(shown(board).decisions.find((decision) => decision.id === "dec-cards")).toMatchObject({ state: "feedback", feedback: "Keep cards for chiefs only." });

  answer.reject(new Error("refused"));
  expect(await sent).toBe("refused");
  expect(shown(board).decisions.find((decision) => decision.id === "dec-cards")).toEqual(before);
  expect(reread).toHaveBeenCalledOnce();
});

it("a refusal that says the outcome already holds counts as done", async () => {
  const board = read(demoLedger(NOW));
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ error: { code: "decision_transition_refused", next_action: "none" } }), { status: 409 })));

  expect(await operate({ kind: "ack", decisionId: "dec-recap-pdf" }, send, () => undefined)).toBeNull();
  // The read taken before the factory caught up still lists it; the board does not.
  expect(reviewing(board)).not.toContain("dec-recap-pdf");
});

it("a read taken before the factory caught up does not bring an answered question back", async () => {
  let ledger = demoLedger(NOW);
  const stale = read(ledger);
  const answer: OperatorAction = { kind: "answer", askId: "ask-slack", answer: { text: "Added." } };

  await operate(answer, async (action) => void (ledger = applyDemo(ledger, action, NOW)), () => undefined);
  settle(stale);
  expect(asking(stale)).not.toContain("ask-slack");

  // Once a read shows it answered, the board shows that read as it is.
  const fresh = read(ledger);
  settle(fresh);
  expect(pendingActions()).not.toContainEqual(answer);
  expect(asking(fresh)).not.toContain("ask-slack");
});
