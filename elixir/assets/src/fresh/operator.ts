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
  | { kind: "archive"; goalIds: string[] }
  | { kind: "goal"; goalId: string; step: GoalStep };

// The free-text choice of a question with choices: the note is then the answer.
export const REDIRECT = "__custom_redirect__";

// Shows the action as done and sends it. Resolves with why the factory refused, in words the operator can act on,
// or null once it agreed.
export const ActContext = createContext<(action: OperatorAction) => Promise<string | null>>(async () => null);

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
    // One after another, so the ledger takes one write at a time.
    case "archive":
      return action.goalIds.map((id) => [`${at("work-requests", id)}/archive`, {}]);
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
};

type Refusal = { error?: { code?: string; message?: string; next_action?: string } | null };

// Refusals that say the outcome already holds: the decision was reviewed, the question is closed, the package
// ended, nobody owns the goal. Another click or another screen got there first, so they count as done.
const HANDLED = new Set(["ask_not_open", "already_ended", "not_owned"]);

function handled(payload: Refusal | null) {
  const error = payload?.error;
  return (error?.next_action ?? "").split(":")[0] === "none" || HANDLED.has(error?.code ?? "");
}

// A refusal in plain words: what to do next where the backend says, else its message.
function refusalText(payload: Refusal | null) {
  const next = payload?.error?.next_action ?? "";
  return NEXT[next] ?? NEXT[next.split(":")[0]] ?? payload?.error?.message ?? "The backend refused this.";
}

// Resolves once every request of the action went through, or was already done; rejects with a refusal in words.
export async function send(action: OperatorAction) {
  for (const [path, body] of requests(action)) {
    const response = await fetch(api(path), { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify(body) }).catch(() => null);
    if (response?.ok) continue;
    if (!response) throw new Error("Could not reach the backend.");
    const payload = (await response.json().catch(() => null)) as Refusal | null;
    if (!handled(payload)) throw new Error(refusalText(payload));
  }
}
