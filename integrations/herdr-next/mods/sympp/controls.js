// Native JSON actions share the backend's persisted operator contracts.
// Operator actions (answers, decisions, Finish, Release, task phase, cards) live under this path.
export const OPERATOR = "/api/v1/sympp/herdr";
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

// What to tell the person when a saved answer could not be typed into the asking terminal; null when
// it was delivered. The answer stays on the ask either way.
const UNDELIVERED = {
  terminal_finished: "the asking terminal has finished",
  terminal_unreachable: "the asking terminal is on another machine or out of reach",
  no_asking_terminal: "the ask has no asking terminal",
  send_failed: "sending it to the asking terminal failed",
};
export function undeliveredNote(payload) {
  const delivery = payload?.delivery;
  if (!delivery || delivery.state !== "not_delivered") return null;
  return `Answer saved, but ${UNDELIVERED[delivery.reason] ?? "it wasn't delivered"}. The agent can still read it.`;
}

// A refusal in words: what the route said, then what to do about it when it names a next step.
const NEXT_STEP = {
  restore: "Restore the task, then try again.",
  "ack or feedback": "Ack it or send feedback instead.",
  dismiss: "Dismiss the undelivered feedback instead.",
};
export function refusal(error, status) {
  const said = typeof error?.message === "string" && error.message.trim() ? error.message.trim().split(";")[0].replace(/\.$/, "") : null;
  const next = typeof error?.next_action === "string" ? error.next_action : "";
  const step = NEXT_STEP[next] ?? (next.startsWith("wait") ? "Try again in a moment." : null);
  if (!said) return `sympp answered ${status}. Try again after refreshing.`;
  return step ? `${said}. ${step}` : `${said}.`;
}

export async function postAction(endpoint, path, body, fetcher = fetch) {
  const response = await fetcher(`${endpoint}${path}`, {
    method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => null);
  // The refusal keeps the route's code and next step, which say whether the outcome already holds.
  if (!response.ok) throw Object.assign(new Error(refusal(payload?.error, response.status)), { code: payload?.error?.code ?? null, next: payload?.error?.next_action ?? null });
  if (!payload) throw new Error("sympp returned an unreadable response. Refresh before trying again.");
  return payload;
}

// A copied ledger can retain live WR IDs and terminal addresses; focusing or typing into a terminal
// belongs to the currently connected factory.
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

// ---------- Actions shown as done ----------
// An operator action shows on the panel the moment it is taken; the request goes to the factory meanwhile.
// Every read is drawn through the actions still on their way, and through the ones the factory agreed to until
// a read shows them, so a read taken before the factory caught up cannot bring an item back. A refusal takes
// the action back; the control that sent it keeps the reason, and a form keeps what was entered.

// The action a native route takes, read from the route itself, or null for a route whose outcome the panel
// doesn't draw ahead of the factory. A task takes one step at a time, in order; anything else is one action per route.
export function actionOf(path, body = {}) {
  const match = /^\/api\/v1\/sympp\/herdr\/(asks|decisions|work-packages|work-requests|cards)\/([^/]+)\/([a-z]+)$/.exec(path ?? "");
  if (!match || !OUTCOMES[`${match[1]}/${match[3]}`]) return null;
  const [, kind, id, step] = match;
  return { kind, id: decodeURIComponent(id), step, text: typeof body.text === "string" ? body.text : null,
    key: path, subject: kind === "work-requests" ? `${kind}/${id}` : path };
}

// Refusals that say the outcome already holds: another click or another screen got there first, so they count
// as done. An answer or feedback carries what the person wrote, which such a refusal did not record.
const none = (error) => (error.next ?? "").split(":")[0] === "none";
const HANDLED = {
  "decisions/ack": none,
  "decisions/dismiss": none,
  "work-packages/finish": (error) => error.code === "already_ended",
  "work-requests/release": (error) => error.code === "not_owned",
};

// Reads and agreements in the order they happened: a read only settles what the factory agreed to before it began.
let clock = 0;
export const readStarts = () => ++clock;

// Sends `act` after any earlier action on the same task still on its way. Taking the latest action on something
// again, such as a second click, does not send it again. `changed` runs when what is drawn changes.
// Resolves with the factory's reply (null when it was already done); rejects with the refusal.
export function take(list, act, send, changed = () => {}) {
  if (!act) return send();
  let latest = null;
  for (const entry of list) if (entry.subject === act.subject) latest = entry;
  if (latest?.key === act.key) return latest.answer;
  const earlier = list.filter((entry) => !entry.agreed && entry.subject === act.subject).map((entry) => entry.answer.catch(() => null));
  const entry = { act, key: act.key, subject: act.subject, agreed: false, answer: null };
  entry.answer = (earlier.length ? Promise.all(earlier).then(send) : send()).then(
    (payload) => { entry.agreed = true; entry.agreedAt = ++clock; return payload; },
    (error) => {
      if (HANDLED[`${act.kind}/${act.step}`]?.(error)) { entry.agreed = true; entry.agreedAt = ++clock; return null; }
      list.splice(list.indexOf(entry), 1);
      throw error;
    },
  ).finally(changed);
  list.push(entry);
  changed();
  return entry.answer;
}

// A read begun at `since` (readStarts) that shows an agreed action's outcome ends it, along with the agreed actions
// taken before it on the same task: the factory took them first, so the read has them too, even where a later one
// undid them. A read begun before the factory agreed may predate the action, so it ends nothing.
export function settle(list, payload, since) {
  if (!Array.isArray(payload?.work_request_details)) return;
  const ended = new Set();
  list.forEach((entry, index) => {
    if (!entry.agreed || entry.agreedAt > since || !holds(payload, entry.act)) return;
    for (const before of list.slice(0, index + 1)) if (before.agreed && before.subject === entry.subject) ended.add(before);
  });
  for (const entry of ended) list.splice(list.indexOf(entry), 1);
}

// The read as it looks once every action in `list` took effect.
export function project(payload, list) {
  if (!list.length || !Array.isArray(payload?.work_request_details)) return payload;
  const shown = JSON.parse(JSON.stringify(payload));
  for (const { act } of list) if (!holds(shown, act)) OUTCOMES[`${act.kind}/${act.step}`].apply(shown, act);
  return shown;
}

const holds = (payload, act) => OUTCOMES[`${act.kind}/${act.step}`].holds(payload, act);
const details = (payload) => payload.work_request_details ?? [];
const holders = (payload) => [...details(payload), ...(payload.cards ?? [])];
const requestOf = (payload, id) => details(payload).find((detail) => detail.work_request?.id === id);
const decisionOf = (payload, id) => details(payload).flatMap((detail) => detail.decisions_to_review ?? []).find((d) => d.id === id);
const packageOf = (payload, id) => details(payload).flatMap((detail) => detail.work_packages ?? []).find((pkg) => (pkg.work_package_id || pkg.id) === id);
const cardOf = (payload, id) => (payload.cards ?? []).find((card) => card.id === id);
const dropDecision = (payload, id) => details(payload).forEach((detail) => { detail.decisions_to_review = (detail.decisions_to_review ?? []).filter((d) => d.id !== id); });
const phaseIs = (detail, value) => detail?.work_request?.phase === value;
// Restoring only clears the archive; the factory then reads the phase off the task as it stands.
function restoredPhase(detail) {
  if (detail.work_request.completed_at) return "done";
  const statuses = (detail.work_packages ?? []).map((pkg) => pkg.status);
  if (!statuses.length) return "intake";
  if (statuses.some((status) => status === "dispatched" || status === "ready")) return "active";
  return statuses.some((status) => status !== "ended") ? "planned" : "unresolved";
}
// Closing a task withdraws its questions.
const close = (detail, fields) => { Object.assign(detail.work_request, fields); detail.asks = []; };

// Each route's outcome as the factory records it: whether a read already shows it, and how to draw it ahead.
const OUTCOMES = {
  "asks/answer": {
    holds: (p, act) => !holders(p).some((holder) => (holder.asks ?? []).some((ask) => ask.id === act.id && (ask.state ?? "open") === "open")),
    apply: (p, act) => holders(p).forEach((holder) => { if (holder.asks) holder.asks = holder.asks.filter((ask) => ask.id !== act.id); }),
  },
  "decisions/ack": {
    holds: (p, act) => (decisionOf(p, act.id)?.review_state ?? "acknowledged") !== "recorded",
    apply: (p, act) => dropDecision(p, act.id),
  },
  "decisions/dismiss": {
    holds: (p, act) => !decisionOf(p, act.id)?.dismiss_route,
    apply: (p, act) => dropDecision(p, act.id),
  },
  // The factory types the feedback into the terminal that made the call; until then it shows as being sent.
  "decisions/feedback": {
    holds: (p, act) => (decisionOf(p, act.id)?.review_state ?? "feedback") !== "recorded",
    apply: (p, act) => Object.assign(decisionOf(p, act.id), { review_state: "feedback", feedback: act.text, ack_route: null, feedback_route: null, dismiss_route: null }),
  },
  "work-packages/finish": {
    holds: (p, act) => { const pkg = packageOf(p, act.id); return !pkg || pkg.status === "ended" || Boolean(pkg.delivery?.outcome); },
    apply: (p, act) => Object.assign(packageOf(p, act.id), { status: "ended", progress: null, delivery: { outcome: "finished", recorded_at: p.generated_at } }),
  },
  "cards/dismiss": {
    holds: (p, act) => (cardOf(p, act.id)?.state ?? "dismissed") === "dismissed",
    apply: (p, act) => { cardOf(p, act.id).state = "dismissed"; },
  },
  "work-requests/release": {
    holds: (p, act) => requestOf(p, act.id)?.work_request.worked_on?.liveness !== "unknown",
    apply: (p, act) => { requestOf(p, act.id).work_request.worked_on = null; },
  },
  "work-requests/complete": {
    holds: (p, act) => { const detail = requestOf(p, act.id); return !detail || phaseIs(detail, "done") || phaseIs(detail, "archived"); },
    apply: (p, act) => close(requestOf(p, act.id), { phase: "done", completed_at: p.generated_at }),
  },
  "work-requests/archive": {
    holds: (p, act) => { const detail = requestOf(p, act.id); return !detail || phaseIs(detail, "archived"); },
    apply: (p, act) => close(requestOf(p, act.id), { phase: "archived", archived_at: p.generated_at, worked_on: null }),
  },
  "work-requests/restore": {
    holds: (p, act) => !phaseIs(requestOf(p, act.id), "archived"),
    apply: (p, act) => { const detail = requestOf(p, act.id); Object.assign(detail.work_request, { phase: restoredPhase(detail), archived_at: null }); },
  },
  "work-requests/delete": {
    holds: (p, act) => !requestOf(p, act.id),
    apply: (p, act) => { p.work_request_details = details(p).filter((detail) => detail.work_request?.id !== act.id); },
  },
};
