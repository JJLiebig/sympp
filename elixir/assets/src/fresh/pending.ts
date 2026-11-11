// What the operator did on the board shows as done the moment they click; the request goes to the factory meanwhile.
// Every read is shown through the actions still under way, and through the ones the factory agreed to until a read
// shows them, so a read taken before the factory caught up cannot bring an item back. A refusal takes the action back
// and is kept, with why, until the next attempt on the same thing.
import { useSyncExternalStore } from "react";

import type { Board, Decision, Goal, Pkg } from "./model";
import type { OperatorAction } from "./operator";

// `touches` names what the action acts on: actions on the same thing are sent, and end, in the order they were taken.
type Entry = { action: OperatorAction; key: string; touches: string[]; agreed: boolean; answer: Promise<string | null> };
export type Refused = { action: OperatorAction; reason: string };

const entries: Entry[] = [];
const refusals = new Map<string, Refused>();
const listeners = new Set<() => void>();
let shown: readonly OperatorAction[] = [];

function changed() {
  shown = entries.map((entry) => entry.action);
  listeners.forEach((listener) => listener());
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const goalKey = (goalId: string) => `goal:${goalId}`;

// Which action this is. Several cards hidden in one go, and shelf cleanup, are one action however many they take.
function keyOf(action: OperatorAction) {
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
      return `${goalKey(action.goalId)}:${action.step}`;
    case "finish":
      return `finish:${action.pkgId}`;
    case "dismiss":
      return action.cardIds.length === 1 ? `dismiss:${action.cardIds[0]}` : "dismiss";
    case "archive":
      return "archive";
  }
}

function touchesOf(action: OperatorAction) {
  if (action.kind === "goal") return [goalKey(action.goalId)];
  if (action.kind === "archive") return action.goalIds.map(goalKey);
  return [keyOf(action)];
}

// Where a refusal shows: a goal's step under the goal, anything else where it was taken.
function homeOf(action: OperatorAction) {
  return action.kind === "goal" ? goalKey(action.goalId) : keyOf(action);
}

const overlaps = (entry: Entry, touches: string[]) => entry.touches.some((thing) => touches.includes(thing));

// Shows the action's outcome at once and sends it, after any earlier action on the same thing still on its way.
// Taking the latest action on something again, such as a second click, does not send it again.
// Resolves with why the factory refused, or null once it agreed; the board is read again after either.
export function operate(action: OperatorAction, send: (action: OperatorAction) => Promise<void>, reread: () => void): Promise<string | null> {
  const key = keyOf(action);
  const touches = touchesOf(action);
  const latest = entries.findLast((entry) => overlaps(entry, touches));
  if (latest?.key === key) return latest.answer;
  refusals.delete(homeOf(action));
  const earlier = entries.filter((entry) => !entry.agreed && overlaps(entry, touches)).map((entry) => entry.answer);
  const entry: Entry = { action, key, touches, agreed: false, answer: Promise.resolve(null) };
  entry.answer = (earlier.length > 0 ? Promise.all(earlier).then(() => send(action)) : send(action)).then(
    () => {
      entry.agreed = true;
      return null;
    },
    (caught: unknown) => {
      const reason = caught instanceof Error ? caught.message : "The backend refused this.";
      entries.splice(entries.indexOf(entry), 1);
      refusals.set(homeOf(action), { action, reason });
      return reason;
    },
  ).then((reason) => {
    changed();
    reread();
    return reason;
  });
  entries.push(entry);
  changed();
  return entry.answer;
}

// A fresh read that shows an agreed action's outcome ends it, along with the agreed actions taken before it on the
// same thing: the factory took them first, so the read has them too, even where a later one undid them.
export function settle(board: Board) {
  const ended = new Set<Entry>();
  entries.forEach((entry, index) => {
    if (!entry.agreed || outcome(board, entry.action) !== null) return;
    entries.slice(0, index + 1).filter((before) => before.agreed && overlaps(before, entry.touches)).forEach((before) => ended.add(before));
  });
  if (ended.size === 0) return;
  entries.splice(0, entries.length, ...entries.filter((entry) => !ended.has(entry)));
  changed();
}

// The actions the board is shown through. Changes whenever one starts, is refused or ends.
export const pendingActions = () => shown;

export function usePending() {
  return useSyncExternalStore(subscribe, pendingActions);
}

// Whether the action is on its way to the factory, and why the last attempt on what it acts on was refused.
export function useOperation(action: OperatorAction | null) {
  const busy = useSyncExternalStore(subscribe, () => (action ? entries.some((entry) => entry.key === keyOf(action) && !entry.agreed) : false));
  const refused = useSyncExternalStore(subscribe, () => (action ? (refusals.get(homeOf(action)) ?? null) : null));
  return { busy, refused };
}

// Why the goal's last step was refused.
export function useGoalRefusal(goalId: string) {
  return useSyncExternalStore(subscribe, () => refusals.get(goalKey(goalId)) ?? null);
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
