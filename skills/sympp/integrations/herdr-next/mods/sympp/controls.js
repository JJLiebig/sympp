// Native JSON actions share the backend's persisted operator contracts.
export function requestBody(fields) {
  const body = Object.fromEntries(["title", "repo", "base_branch", "human_description"].map((key) => [key, fields[key].trim()]));
  if (Object.values(body).some((value) => !value)) throw new Error("Fill in the title, repository, base branch and request.");
  return { ...body, work_type: "feature", desired_dispatch_shape: "architect_led_feature_branch", constraints: {} };
}

export function answerBody(question, choice, text) {
  const note = text.trim();
  if (!question.prompt) {
    if (!note) throw new Error("Enter your answer.");
    return { answer: note };
  }
  if (choice === "__custom_redirect__") {
    if (!note) throw new Error("Describe the direction you want instead.");
  } else if (!question.prompt.options?.some((option) => option.id === choice)) {
    throw new Error("Choose an option or write another direction.");
  }
  return { answer_choice: choice, ...(note ? { answer_note: note } : {}) };
}

// What to tell the operator when a saved answer could not be typed into the asking terminal; null
// when it was delivered. The answer stays on the ask either way.
const UNDELIVERED = {
  terminal_finished: "the asking terminal has finished",
  terminal_unreachable: "the asking terminal is on another machine or out of reach",
  no_asking_terminal: "the ask has no asking terminal",
  send_failed: "sending it to the asking terminal failed",
};
export function undeliveredNote(payload) {
  const delivery = payload?.delivery;
  if (!delivery || delivery.state !== "not_delivered") return null;
  return `Answer saved, but ${UNDELIVERED[delivery.reason] ?? "it wasn't delivered"}. The agent can read it on the WorkRequest.`;
}

export async function postAction(endpoint, path, body, fetcher = fetch) {
  const response = await fetcher(`${endpoint}${path}`, {
    method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok) throw new Error(payload?.error?.message || `sympp answered ${response.status}. Try again after refreshing.`);
  if (!payload) throw new Error("sympp returned an unreadable response. Refresh before trying again.");
  return payload;
}

// A copied ledger can retain live WR IDs; agent access belongs to the currently connected factory.
export async function requireAgentAccess(endpoint, fetcher = fetch) {
  const response = await fetcher(`${endpoint}/api/v1/sympp/herdr/dashboard`, { headers: { accept: "application/json" } });
  const payload = await response.json().catch(() => null);
  if (!response.ok || payload?.runtime?.offline !== false) {
    throw new Error(payload?.runtime?.offline === true ? "Agent access is disabled in an offline copy." : "Couldn't verify agent access. Refresh sympp and try again.");
  }
}

// The same latch protects button and keyboard activation; drafts clear only after success.
export async function submitAction(action, send, accepted) {
  if (action.pending) return;
  action.pending = true;
  action.error = null;
  try { await accepted(await send()); }
  catch (error) { action.error = error?.message || "Couldn't save. Check the connection and try again."; }
  finally { action.pending = false; }
}
