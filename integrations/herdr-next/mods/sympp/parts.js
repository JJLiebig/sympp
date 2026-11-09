// The v2 pieces every level shares: the terminal a thing is worked on by, an ask with its answer
// form, a decision to review with Ack and Feedback, a small-work card, and a task's phase with its
// operator actions. Drawn in the dashboard's language (ui.js); actions live on the view (main.js).

import { div, svg } from "gpui-kit";
import { v_flex, h_flex, Button } from "gpui-base";
import { ago, PHASE_LABEL } from "./model.js";
import { OPERATOR } from "./controls.js";
import { reviewText } from "./scope.js";
import { answerForm } from "./jobview.js";
import { CLEAR, MONO, SANS, icon, tint, signal, mono, ghost, youButton, field, button } from "./ui.js";

// ---------- Worked on by ----------

const ROLE = { chief: "Chief", architect: "Architect", worker: "Worker", card: "Agent" };

// Live is a filled dot, not answering a ring, finished a dash: the same marks as the web board.
export function liveDot(t, liveness) {
  if (liveness === "live") return div().size(6).flex_none().rounded(3).bg(signal().merge);
  if (liveness === "unknown") return div().size(7).flex_none().rounded(4).border(1.5).border_color(signal().checks);
  return div().w(6).h(1.5).flex_none().bg(t.dim);
}

// A terminal's address with its liveness. A running one is a link that focuses it; Release appears
// beside an owner that stopped answering, and asks again before it acts.
export function ownerChip(v, t, given, id, release = null) {
  if (!given) return null;
  // A terminal known only by its address is live while Herdr shows it running.
  const owner = given.liveness ? given : { ...given, liveness: v.running(given.address) ? "live" : null };
  const word = { live: "live", unknown: "not answering", finished: "finished" }[owner.liveness];
  const tip = [`${ROLE[owner.role] ?? "Terminal"} ${owner.address}`, word, owner.since ? `since ${ago(owner.since, v.now())}` : null].filter(Boolean).join(" · ");
  // A link only while the online factory itself sees that terminal live: an address alone, or an
  // offline copy's, may name another terminal now.
  const reachable = given.liveness === "live" && v.net.data?.offline === false;
  const chip = Button.new(`owner-${id}`).flex().flex_none().items_center().gap(5).h(20).px(5).rounded(4)
    .font_family(MONO).text_size(11).text_color(owner.liveness === "finished" ? t.dim : t.muted)
    .accessibility_label(tip).tooltip(reachable ? `${tip}. Click to focus it.` : tip)
    .when(reachable, (el) => el.cursor_pointer().hover((s) => s.bg(tint(t.foreground, "14")).text_color(t.foreground))
      .on_click((_e, cx) => { cx.stop_propagation(); v.focusTerminal(owner.address, cx); }))
    .when(owner.liveness !== null, (el) => el.child(liveDot(t, owner.liveness))).child(owner.address);
  const op = release ? v.ops[`release:${release.path}`] : null;
  const error = v.ops[`focus:${owner.address}`]?.error ?? op?.error ?? null;
  return h_flex().id(`owned-${id}`).flex_none().gap(2).items_center()
    .child(chip)
    .when(owner.liveness === "unknown" && Boolean(release), (el) => el.child(confirmButton(v, t, `release-${id}`, "Release", "Release this owner?",
      `release:${release.path}`, (cx) => v.operate(`release:${release.path}`, `${OPERATOR}${release.path}/release`, {}, cx), signal().checks)))
    .when(Boolean(error), (el) => el.child(div().max_w(180).truncate().text_size(11).text_color(signal().fail).tooltip(error).child(error)));
}

// An action that asks once more before it acts: the first click arms it, the second sends.
export function confirmButton(v, t, id, label, confirm, key, act, color = null) {
  const op = v.ops[key] ?? {};
  const armed = op.armed && !op.pending;
  const tone = color ?? t.muted;
  return Button.new(id).flex().flex_none().items_center().h(20).px(6).rounded(4).cursor_pointer()
    .font_family(SANS).text_size(11.5).font_medium().text_color(armed ? t.foreground : tone)
    .bg(armed ? tint(color ?? t.foreground, "2a") : CLEAR).hover((s) => s.bg(tint(color ?? t.foreground, "1f")))
    .focus((s) => s.border(1).border_color(t.accent)).disabled(Boolean(op.pending)).when(Boolean(op.pending), (el) => el.opacity(0.5))
    .accessibility_label(armed ? confirm : label).tooltip(armed ? "Click again to confirm" : label)
    .on_click((_e, cx) => { cx.stop_propagation(); if (armed) act(cx); else v.arm(key, cx); })
    .child(op.pending ? "…" : armed ? confirm : label);
}

// ---------- Asks ----------

// Where an ask or decision comes from: its task (or card) and topic, small and quiet. With `goTo`,
// a click on it goes to the task.
function context(t, parts, id, goTo = null) {
  const text = parts.filter(Boolean).join(" · ");
  if (!text) return div().flex_1();
  const el = div().id(`from-${id}`).flex_1().min_w(0).truncate().text_size(11).text_color(t.dim).child(text);
  return goTo ? el.cursor_pointer().hover((s) => s.text_color(t.foreground)).tooltip("Open the task").on_click((_e, cx) => { cx.stop_propagation(); goTo(cx); }) : el;
}

// An ask, as the dashboard's: an orange rule, the question in plain ink, who asks, and Answer. The
// answer form opens in place, with the decision prompt's choices when it has one.
export function askBlock(v, t, ask, { where = [], id = ask.key, goTo = null } = {}) {
  const draft = v.answers[ask.key];
  const open = Boolean(draft?.open);
  const action = draft?.saved ? mono(11, t.dim).child("answered")
    : ask.route ? youButton(t, `answer-${id}`, "Answer", (cx) => v.openAnswer(ask, cx), "Answer here") : null;
  return v_flex().id(`ask-${id}`).flex_none().mr(4).mt(2).mb(8)
    .child(h_flex().items_start()
      .child(div().w(2).flex_none().self_stretch().rounded(1).bg(signal().you))
      .child(v_flex().flex_1().min_w(0).pl(12).gap(4)
        .when(where.length > 0 || Boolean(ask.by), (el) => el.child(h_flex().gap(8).items_center()
          .child(context(t, where, id, goTo)).when(Boolean(ask.by), (x) => x.child(ownerChip(v, t, ask.by, `ask-${id}`)))))
        .child(h_flex().gap(10).items_center()
          .child(div().flex_1().min_w(0).py(1).text_size(13.5).line_height("19px").text_color(t.foreground).child(ask.text))
          .when(!open && Boolean(action), (el) => el.child(action)))))
    .when(open, (el) => el.child(div().pl(14).child(answerForm(v, t, ask))));
}

// ---------- Decisions ----------

// A decision a chief or architect flagged, neutral where an ask is orange: a quiet rule, the call and
// why, who made it. A click anywhere on it opens Feedback; Ack is its own button. Feedback that
// never reached a finished terminal stays as Undelivered until dismissed.
export function decisionBlock(v, t, d, { where = [], goTo = null } = {}) {
  const draft = v.feedback[d.key];
  const open = Boolean(draft?.open);
  const ack = v.ops[`ack:${d.id}`];
  const head = h_flex().gap(8).items_center().child(context(t, where, d.key, goTo)).when(Boolean(d.by), (x) => x.child(ownerChip(v, t, d.by, `decision-${d.id}`)));
  const body = v_flex().gap(2)
    .child(div().text_size(13.5).line_height("19px").text_color(t.foreground).child(d.text))
    .when(Boolean(d.rationale), (el) => el.child(div().text_size(12).line_height("17px").text_color(t.muted).child(d.rationale)));
  const row = h_flex().id(`decision-${d.id}`).flex_none().items_start().mr(4).mt(2).mb(8).rounded(5)
    .child(div().w(2).flex_none().self_stretch().rounded(1).bg(tint(t.foreground, "40")))
    .child(v_flex().flex_1().min_w(0).pl(12).gap(4).child(head).child(body)
      .when(d.undelivered, (el) => el.child(undelivered(v, t, d)))
      .when(d.sending, (el) => el.child(div().text_size(11.5).text_color(t.dim).child(`Sending “${d.feedback ?? ""}”…`)))
      .when(Boolean(d.routes.ack && d.routes.feedback) && !open, (el) => el.child(h_flex().gap(4).pt(2).items_center()
        .child(ghost(t, `ack-${d.id}`, ack?.pending ? "…" : "Ack", (cx) => v.operate(`ack:${d.id}`, d.routes.ack, {}, cx), { strong: true, tip: "Acknowledge this decision", disabled: Boolean(ack?.pending) }))
        .child(ghost(t, `feedback-${d.id}`, "Feedback", (cx) => v.openFeedback(d, cx)))
        .when(Boolean(ack?.error), (x) => x.child(div().text_size(11.5).text_color(signal().fail).child(ack.error)))))
      .when(open, (el) => el.child(feedbackForm(v, t, d, draft))));
  if (!d.routes.feedback || open) return row;
  return row.cursor_pointer().hover((s) => s.bg(tint(t.foreground, "07"))).accessibility_label(`Decision: ${d.text}. Click to give feedback.`)
    .on_click((_e, cx) => v.openFeedback(d, cx));
}

function undelivered(v, t, d) {
  const op = v.ops[`dismiss:${d.id}`];
  const row = h_flex().gap(8).mt(2).px(8).py(5).rounded(5).items_center().border(1).border_color(tint(t.foreground, "1a"))
    .child(div().flex_none().px(5).rounded(3).text_size(10.5).font_semibold().text_color(signal().checks).bg(tint(signal().checks, "1f")).child("Undelivered"))
    .child(div().flex_1().min_w(0).text_size(12).text_color(t.muted).child(`“${d.feedback ?? ""}”`))
    .child(Button.new(`dismiss-feedback-${d.id}`).flex().flex_none().items_center().justify_center().size(18).rounded(4).cursor_pointer()
      .text_color(t.dim).hover((s) => s.bg(tint(t.foreground, "14")).text_color(t.foreground)).disabled(Boolean(op?.pending))
      .accessibility_label("Dismiss").tooltip("Dismiss: the feedback stays on the decision")
      .on_click((_e, cx) => { cx.stop_propagation(); v.operate(`dismiss:${d.id}`, d.routes.dismiss, {}, cx); })
      .child(svg(icon("x")).size(11).flex_none()));
  return op?.error ? v_flex().gap(4).child(row).child(div().text_size(11.5).text_color(signal().fail).child(op.error)) : row;
}

// The factory delivers feedback to the terminal that made the call. While that terminal runs here,
// Focus sends it and, once the factory has delivered it there, opens that terminal.
function feedbackForm(v, t, d, draft) {
  const role = d.by?.role === "architect" ? "architect" : "chief";
  const reachable = Boolean(d.by) && v.running(d.by.address);
  return v_flex().gap(8).pt(4).on_mouse_down("left", (_e, cx) => cx.stop_propagation())
    .child(field(t, "Feedback", draft.input, true))
    .when(Boolean(draft.error), (el) => el.child(div().role("alert").text_size(12).text_color(signal().fail).child(draft.error)))
    .child(h_flex().gap(6).flex_wrap()
      .child(button(t, `send-feedback-${d.id}`, draft.pending ? "Sending…" : "Send", (cx) => v.sendFeedback(d, false, cx), { strong: true, disabled: draft.pending }))
      .when(reachable, (el) => el.child(button(t, `focus-feedback-${d.id}`, `Focus ${role}`, (cx) => v.sendFeedback(d, true, cx), { disabled: draft.pending, tip: `Send, then open the ${role}` })))
      .child(button(t, `cancel-feedback-${d.id}`, "Cancel", (cx) => { draft.open = false; v.keys.focus(); cx.notify(); }, { disabled: draft.pending })));
}

// ---------- Cards ----------

const CARD_STATE = { working: "Working", review_ci: "Review/CI", merged: "Merged", done: "Done" };
const cardTone = (t, state) => ({ working: signal().build, review_ci: signal().review, merged: tint(signal().merge, "aa"), done: t.dim }[state] ?? t.muted);

// Small work outside any task: its task, branch and PR, checks and review, its state and terminal,
// and Dismiss. `ci` is the drawn checks dot, or null.
export function cardRow(v, t, card, ci) {
  const settled = card.state === "merged" || card.state === "done";
  const tone = cardTone(t, card.state);
  const op = v.ops[`dismiss-card:${card.id}`];
  const pr = card.pr.number ? Button.new(`card-pr-${card.id}`).flex_none().cursor_pointer().font_family(MONO).text_size(11).text_color(t.muted).underline()
    .hover((s) => s.text_color(t.foreground)).tooltip(`Open PR #${card.pr.number}`)
    .on_click((_e, cx) => { cx.stop_propagation(); if (card.pr.url) cx.open_url(card.pr.url); }).child(`#${card.pr.number}`) : null;
  const review = reviewText(card.review);
  return v_flex().id(`card-${card.id}`).flex_none().px(10).py(7).gap(4).rounded(5).hover((s) => s.bg(tint(t.foreground, "07")))
    .child(h_flex().gap(10).items_center()
      .child(div().size(8).flex_none().rounded(2).bg(tone))
      .child(div().flex_1().min_w(0).truncate().text_size(13).text_color(settled ? t.muted : t.foreground).child(card.task))
      .when(Boolean(ci), (el) => el.child(ci))
      .when(Boolean(card.owner), (x) => x.child(ownerChip(v, t, card.owner, `card-${card.id}`)))
      .child(Button.new(`dismiss-card-${card.id}`).flex().flex_none().items_center().justify_center().size(18).rounded(4).cursor_pointer()
        .text_color(t.dim).hover((s) => s.bg(tint(t.foreground, "14")).text_color(t.foreground)).disabled(Boolean(op?.pending))
        .accessibility_label(`Dismiss ${card.task}`).tooltip("Dismiss")
        .on_click((_e, cx) => { cx.stop_propagation(); v.operate(`dismiss-card:${card.id}`, `${OPERATOR}/cards/${encodeURIComponent(card.id)}/dismiss`, {}, cx); })
        .child(svg(icon("x")).size(11).flex_none())))
    .child(h_flex().pl(18).gap(10).items_center()
      .child(mono(11, tone).w(64).child(CARD_STATE[card.state]))
      .child(mono(11, t.dim).flex_1().min_w(0).truncate().child(card.branch ?? ""))
      .when(Boolean(review), (el) => el.child(mono(11, t.dim).child(review)))
      .when(Boolean(pr), (el) => el.child(pr)))
    .when(Boolean(op?.error), (el) => el.child(div().pl(18).text_size(11.5).text_color(signal().fail).child(op.error)));
}

// ---------- Task phase ----------

const PHASE_TONE = (t) => ({ intake: t.dim, planned: t.muted, active: signal().build, unresolved: signal().checks, done: signal().merge, archived: t.dim });

export function phaseBadge(t, phase, id) {
  const tone = PHASE_TONE(t)[phase] ?? t.muted;
  return h_flex().id(`phase-${id}`).flex_none().gap(5).items_center()
    .child(div().size(6).flex_none().rounded(3).bg(tone))
    .child(div().text_size(11.5).font_semibold().text_color(tone).child(PHASE_LABEL[phase] ?? phase));
}

// The person's calls on a whole task: Complete while it is open, Archive once it is done or
// unresolved, Restore once archived, and Delete. Complete and Delete ask again; Restore undoes Archive.
export function phaseActions(v, t, job) {
  const path = `${OPERATOR}/work-requests/${encodeURIComponent(job.id)}`;
  const go = (step) => (cx) => v.operate(`${step}:${job.id}`, `${path}/${step}`, {}, cx);
  const error = ["complete", "archive", "restore", "delete"].map((step) => v.ops[`${step}:${job.id}`]?.error).find(Boolean);
  const remove = confirmButton(v, t, `delete-${job.id}`, "Delete", "Delete this task?", `delete:${job.id}`,
    (cx) => v.operate(`delete:${job.id}`, `${path}/delete`, {}, cx, (cx) => { if (v.level !== "factory" && !v.pinned) v.goUp(cx); }));
  const list = job.phase === "archived" ? [ghost(t, `restore-${job.id}`, "Restore", go("restore"))]
    : job.phase === "done" ? [ghost(t, `archive-${job.id}`, "Archive", go("archive"))]
      : [confirmButton(v, t, `complete-${job.id}`, "Complete", "Complete this task?", `complete:${job.id}`, go("complete")),
        ...(job.phase === "unresolved" ? [ghost(t, `archive-${job.id}`, "Archive", go("archive"))] : [])];
  return h_flex().flex_none().gap(2).items_center().children([...list, remove])
    .when(Boolean(error), (el) => el.child(div().max_w(200).truncate().text_size(11.5).text_color(signal().fail).tooltip(error).child(error)));
}
