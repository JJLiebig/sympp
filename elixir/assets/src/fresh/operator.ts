import { createContext, useContext } from "react";

import { api } from "./api";

// Everything the operator can do from the board. None of it stops a running worker or merges a PR.
export type GoalStep = "complete" | "archive" | "restore" | "delete";
// An answer to a question with choices names the choice, with an optional note; any other answer is free text.
export type Answer = { choice: string; note: string } | { text: string };
export type OperatorAction =
  | { kind: "answer"; askId: string; answer: Answer }
  | { kind: "ack"; decisionId: string }
  | { kind: "feedback"; decisionId: string; text: string }
  | { kind: "dismiss_feedback"; decisionId: string }
  | { kind: "release"; goalId: string }
  | { kind: "finish"; pkgId: string }
  | { kind: "dismiss"; cardIds: string[] }
  | { kind: "goal"; goalId: string; step: GoalStep };

// The free-text choice of a question with choices: the note is then the answer.
export const REDIRECT = "__custom_redirect__";

// Resolves once the action went through; rejects with a message the operator can act on.
export const ActContext = createContext<(action: OperatorAction) => Promise<void>>(async () => undefined);

export function useAct() {
  return useContext(ActContext);
}

const at = (kind: string, id: string) => `/${kind}/${encodeURIComponent(id)}`;

function answerBody(answer: Answer) {
  return "choice" in answer ? { answer_choice: answer.choice, answer_note: answer.note } : { answer: answer.text };
}

function requests(action: OperatorAction): Array<[path: string, body: Record<string, unknown>]> {
  switch (action.kind) {
    case "answer":
      return [[`${at("asks", action.askId)}/answer`, answerBody(action.answer)]];
    case "ack":
      return [[`${at("decisions", action.decisionId)}/ack`, {}]];
    case "dismiss_feedback":
      return [[`${at("decisions", action.decisionId)}/dismiss`, {}]];
    case "feedback":
      return [[`${at("decisions", action.decisionId)}/feedback`, { text: action.text }]];
    case "release":
      return [[`${at("work-requests", action.goalId)}/release`, {}]];
    case "finish":
      return [[`${at("work-packages", action.pkgId)}/finish`, {}]];
    case "dismiss":
      return action.cardIds.map((id) => [`${at("cards", id)}/dismiss`, {}]);
    case "goal":
      return [[`${at("work-requests", action.goalId)}/${action.step}`, {}]];
  }
}

// What a refusal's `next_action` asks of the operator, in words.
const NEXT: Record<string, string> = {
  restore: "This goal is archived. Restore it first.",
  complete_or_archive: "Complete or archive the goal instead.",
  dismiss: "Its feedback could not be delivered. Dismiss it instead.",
  "ack or feedback": "This decision still waits for an ack or feedback.",
  "wait: the feedback is being typed": "The feedback is still being typed into its terminal. Try again in a minute.",
  wait: "The factory has not caught up yet. Try again in a minute.",
  none: "Nothing is left to do here. It was already handled.",
};

type Refusal = { error?: { message?: string; next_action?: string } | null };

// A refusal in plain words: what to do next where the backend says, else its message.
export function refusalText(payload: Refusal | null) {
  const next = payload?.error?.next_action ?? "";
  return NEXT[next] ?? NEXT[next.split(":")[0]] ?? payload?.error?.message ?? "The backend refused this.";
}

export async function send(action: OperatorAction) {
  for (const [path, body] of requests(action)) {
    const response = await fetch(api(path), { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify(body) }).catch(() => null);
    if (response?.ok) continue;
    if (!response) throw new Error("Could not reach the backend.");
    throw new Error(refusalText((await response.json().catch(() => null)) as Refusal | null));
  }
}
