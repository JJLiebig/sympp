import { createContext, useContext } from "react";

import { api } from "./api";

// Everything the operator can do from the board. None of it stops a running worker or merges a PR.
export type Subject = { goalId: string } | { pkgId: string } | { cardId: string };
export type GoalStep = "complete" | "archive" | "restore" | "delete";
export type OperatorAction =
  | { kind: "answer"; askId: string; answer: string; choice: string | null }
  | { kind: "ack"; decisionId: string }
  | { kind: "feedback"; decisionId: string; text: string }
  | { kind: "dismiss_feedback"; decisionId: string }
  | { kind: "release"; subject: Subject }
  | { kind: "finish"; pkgId: string }
  | { kind: "dismiss"; cardIds: string[] }
  | { kind: "goal"; goalId: string; step: GoalStep };

// Resolves once the action went through; rejects with a message the operator can act on.
export const ActContext = createContext<(action: OperatorAction) => Promise<void>>(async () => undefined);

export function useAct() {
  return useContext(ActContext);
}

const at = (kind: string, id: string) => `/${kind}/${encodeURIComponent(id)}`;

function subjectPath(subject: Subject) {
  if ("goalId" in subject) return at("work-requests", subject.goalId);
  if ("pkgId" in subject) return at("work-packages", subject.pkgId);
  return at("cards", subject.cardId);
}

function requests(action: OperatorAction): Array<[path: string, body: Record<string, unknown>]> {
  switch (action.kind) {
    case "answer":
      return [[`${at("asks", action.askId)}/answer`, { answer: action.answer, choice: action.choice }]];
    case "ack":
      return [[`${at("decisions", action.decisionId)}/ack`, {}]];
    case "dismiss_feedback":
      return [[`${at("decisions", action.decisionId)}/dismiss`, {}]];
    case "feedback":
      return [[`${at("decisions", action.decisionId)}/feedback`, { text: action.text }]];
    case "release":
      return [[`${subjectPath(action.subject)}/release`, {}]];
    case "finish":
      return [[`${at("work-packages", action.pkgId)}/finish`, {}]];
    case "dismiss":
      return action.cardIds.map((id) => [`${at("cards", id)}/dismiss`, {}]);
    case "goal":
      return [[`${at("work-requests", action.goalId)}/${action.step}`, {}]];
  }
}

export async function send(action: OperatorAction) {
  for (const [path, body] of requests(action)) {
    const response = await fetch(api(path), { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify(body) }).catch(() => null);
    if (response?.ok) continue;
    const payload = (await response?.json().catch(() => null)) as { error?: { message?: string } } | null;
    throw new Error(payload?.error?.message || (response ? "The backend refused this." : "Could not reach the backend."));
  }
}
