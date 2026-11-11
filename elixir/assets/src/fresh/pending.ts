// What the operator did on the board shows as done the moment they click; the request goes to the factory meanwhile.
// Every read is shown through the actions still under way, and through the ones the factory agreed to until a read
// shows them, so a read taken before the factory caught up cannot bring an item back. A refusal takes the action back
// and is kept, with why, until the next attempt.
import { useSyncExternalStore } from "react";

import type { Board, Decision, Goal, Pkg } from "./model";
import type { OperatorAction } from "./operator";

type Entry = { action: OperatorAction; agreed: boolean; answer: Promise<string | null> };
export type Refused = { action: OperatorAction; reason: string };

const entries = new Map<string, Entry>();
const refusals = new Map<string, Refused>();
const listeners = new Set<() => void>();
let shown: readonly OperatorAction[] = [];

function changed() {
  shown = [...entries.values()].map((entry) => entry.action);
  listeners.forEach((listener) => listener());
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export const goalKey = (goalId: string) => `goal:${goalId}`;

// One action at a time per thing it acts on. A goal takes one step at a time; shelf cleanup runs once at a time.
export function keyOf(action: OperatorAction) {
  switch (action.kind) {
    case "answer":
      return `answer:${action.askId}`;
    case "ack":
    case "feedback":
    case "dismiss_feedback":
      return `${action.kind}:${action.decisionId}`;
    case "release":
      return `release:${action.goalId}`;
    case "goal":
      return goalKey(action.goalId);
    case "finish":
      return `finish:${action.pkgId}`;
    case "dismiss":
      return `dismiss:${action.cardIds.join(",")}`;
    case "archive":
      return "archive";
  }
}

// Shows the action's outcome at once and sends it. An action already under way is not sent again.
// Resolves with why the factory refused, or null once it agreed; the board is read again after either.
export function operate(action: OperatorAction, send: (action: OperatorAction) => Promise<void>, reread: () => void): Promise<string | null> {
  const key = keyOf(action);
  const known = entries.get(key);
  if (known) return known.answer;
  refusals.delete(key);
  const entry: Entry = { action, agreed: false, answer: Promise.resolve(null) };
  entry.answer = send(action).then(
    () => {
      entry.agreed = true;
      return null;
    },
    (caught: unknown) => {
      const reason = caught instanceof Error ? caught.message : "The backend refused this.";
      entries.delete(key);
      refusals.set(key, { action, reason });
      return reason;
    },
  ).then((reason) => {
    changed();
    reread();
    return reason;
  });
  entries.set(key, entry);
  changed();
  return entry.answer;
}

// A fresh read that shows an agreed action's outcome ends it.
export function settle(board: Board) {
  let ended = false;
  for (const [key, entry] of entries) {
    if (entry.agreed && outcome(board, entry.action) === null) {
      entries.delete(key);
      ended = true;
    }
  }
  if (ended) changed();
}

// The actions the board is shown through. Changes whenever one starts, is refused or ends.
export const pendingActions = () => shown;

export function usePending() {
  return useSyncExternalStore(subscribe, pendingActions);
}

// Whether the action under `key` is on its way to the factory, and why its last attempt was refused.
export function useOperation(key: string | null) {
  const busy = useSyncExternalStore(subscribe, () => (key ? entries.get(key)?.agreed === false : false));
  const refused = useSyncExternalStore(subscribe, () => (key ? (refusals.get(key) ?? null) : null));
  return { busy, refused };
}

export function project(board: Board, actions: readonly OperatorAction[]): Board {
  return actions.reduce((shownBoard, action) => outcome(shownBoard, action) ?? shownBoard, board);
}

// The board once the action took effect, the way the factory records it, or null where it already shows that.
function outcome(board: Board, action: OperatorAction): Board | null {
  switch (action.kind) {
    case "answer":
      return board.asks.some((ask) => ask.id === action.askId && ask.until === null) ? { ...board, asks: board.asks.filter((ask) => ask.id !== action.askId) } : null;
    case "ack":
      return withDecision(board, action.decisionId, (decision) => (decision.state === "recorded" ? { ...decision, state: "acknowledged" } : null));
    case "feedback":
      // The factory types the feedback into its terminal; until then it shows as being sent.
      return withDecision(board, action.decisionId, (decision) => (decision.state === "recorded" ? { ...decision, state: "feedback", feedback: action.text, undelivered: "delivering" } : null));
    case "dismiss_feedback":
      return withDecision(board, action.decisionId, (decision) => (decision.state === "feedback" && decision.undelivered !== null ? { ...decision, undelivered: null } : null));
    case "release":
      return withGoal(board, action.goalId, (goal) => (goal.owner?.liveness === "unknown" ? { ...goal, owner: null } : null));
    case "finish":
      return finished(board, action.pkgId);
    case "dismiss":
      return dismissed(board, action.cardIds);
    case "archive": {
      const archived = project(board, action.goalIds.map((goalId) => ({ kind: "goal", goalId, step: "archive" })));
      return archived === board ? null : archived;
    }
    case "goal":
      return stepped(board, action.goalId, action.step);
  }
}

function withDecision(board: Board, decisionId: string, change: (decision: Decision) => Decision | null): Board | null {
  const found = board.decisions.find((decision) => decision.id === decisionId);
  const next = found ? change(found) : null;
  return next ? { ...board, decisions: board.decisions.map((decision) => (decision === found ? next : decision)) } : null;
}

function withGoal(board: Board, goalId: string, change: (goal: Goal) => Goal | null): Board | null {
  const found = board.goals.find((goal) => goal.id === goalId);
  const next = found ? change(found) : null;
  return next ? { ...board, goals: board.goals.map((goal) => (goal === found ? next : goal)) } : null;
}

function dismissed(board: Board, cardIds: string[]): Board | null {
  const cards = board.cards.map((card) => (cardIds.includes(card.id) && card.state !== "dismissed" ? { ...card, state: "dismissed" as const } : card));
  return cards.some((card, index) => card !== board.cards[index]) ? { ...board, cards } : null;
}

function finished(board: Board, pkgId: string): Board | null {
  const end = (pkg: Pkg): Pkg => (pkg.id === pkgId ? { ...pkg, outcome: "finished", endAt: board.readAt } : pkg);
  const open = board.goals.find((goal) => goal.pkgs.some((pkg) => pkg.id === pkgId && pkg.outcome === null));
  return open ? withGoal(board, open.id, (goal) => ({ ...goal, pkgs: goal.pkgs.map(end) })) : null;
}

// Completing or archiving a goal withdraws its questions; deleting it takes everything about it off the board.
function stepped(board: Board, goalId: string, step: Extract<OperatorAction, { kind: "goal" }>["step"]): Board | null {
  const withdrawn = (next: Board | null) => (next ? { ...next, asks: next.asks.filter((ask) => ask.goalId !== goalId) } : null);
  switch (step) {
    case "complete":
      return withdrawn(withGoal(board, goalId, (goal) => (goal.phase === "done" || goal.phase === "archived" ? null : { ...goal, phase: "done", completedAt: board.readAt })));
    case "archive":
      return withdrawn(withGoal(board, goalId, (goal) => (goal.phase === "archived" ? null : { ...goal, phase: "archived", archivedAt: board.readAt, owner: null })));
    case "restore":
      return withGoal(board, goalId, (goal) => (goal.phase === "archived" ? { ...goal, phase: goal.completedAt === null ? "intake" : "done", archivedAt: null } : null));
    case "delete":
      if (!board.goals.some((goal) => goal.id === goalId)) return null;
      return {
        ...board,
        goals: board.goals.filter((goal) => goal.id !== goalId),
        asks: board.asks.filter((ask) => ask.goalId !== goalId),
        decisions: board.decisions.filter((decision) => decision.goalId !== goalId),
      };
  }
}
