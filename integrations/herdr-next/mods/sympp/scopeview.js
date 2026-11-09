// The Topic, Space and task views, drawn in the web dashboard's visual language: Geist with Geist
// Mono, its step colours, its box strip and its four-step track (Launching, Implementing, Review/CI,
// Ready; checks as a dot), and its orange for what needs the person. Topic and Space draw the same
// view; a space only narrows the tasks. A task is its name and its strip; the person's asks come
// first, decisions to review after them, small work last.

import { div, svg } from "gpui-kit";
import { v_flex, h_flex, Button } from "gpui-base";
import { shared } from "herdr";
import * as J from "./job.js";
import * as L from "./levels.js";
import * as R from "./rails.js";
import * as St from "./studio.js";
import * as S from "./scope.js";
import * as O from "./overview.js";
import * as M from "./model.js";
import * as P from "./parts.js";
import { reviewPane } from "./jobview.js";
import { CLEAR, EXPAND, MONO, SANS, icon, tint, signal, micro, mono, ghost } from "./ui.js";
import { CHIEF_SPACES, isChiefSpace } from "./chief.js";

// ---------- Controls ----------

function glyphButton(t, id, glyph, tip, action, { on = false } = {}) {
  return Button.new(id).flex().flex_none().items_center().justify_center().size(26).rounded(6).cursor_pointer()
    .bg(on ? tint(t.foreground, "14") : CLEAR).text_color(on ? t.foreground : t.dim)
    .hover((s) => s.bg(tint(t.foreground, "14")).text_color(t.foreground))
    .focus((s) => s.border(1).border_color(t.accent))
    .accessibility_label(tip).tooltip(tip)
    .on_click((_e, cx) => { cx.stop_propagation(); action(cx); })
    .child(svg(icon(glyph)).size(14).flex_none());
}

// ---------- Shared ----------

// The selected row takes the accent, so it never reads as a zebra stripe.
function reach(v, t, el, key, open, label) {
  const on = v.row(key, open);
  return el.cursor_pointer().rounded(6).bg(on ? tint(t.accent, "24") : CLEAR).border(1).border_color(on ? tint(t.accent, "99") : CLEAR)
    .hover((s) => s.bg(on ? tint(t.accent, "2e") : tint(t.foreground, "08")))
    .accessibility_label(label)
    .on_click((_e, cx) => open(cx));
}

// A task's own tab has no level above it, so no way back.
function bar(v, t, title, now, { create = true, back = true } = {}) {
  return h_flex().id("lens-bar").flex_none().h(44).px(v.compact ? 8 : 16).gap(4).items_center()
    .bg(tint(t.foreground, "05")).border_b(1).border_color(tint(t.foreground, "12"))
    .when(back, (el) => el.child(glyphButton(t, "lens-back", "chevron-left", "Back (Esc)", (cx) => v.goUp(cx))))
    .child(div().flex_1().min_w(0).pl(back ? 2 : 6).truncate().font_family(SANS).text_size(13.5).font_semibold().text_color(t.foreground).child(title))
    .child(O.status(v, t, now))
    .when(create, (el) => el.child(glyphButton(t, "new-job", "plus", "New task", (cx) => v.openIntake(cx))))
    .when(v.role === "panel", (el) => el.child(glyphButton(t, "open-big", EXPAND, "Open as a tab", (cx) => v.openBig(cx))))
    .when(v.role === "panel", (el) => el.child(glyphButton(t, "pin", v.pin ? "pin-off" : "pin",
      v.pin ? "Follow Herdr's focus again (P)" : "Stay here instead of following focus (P)", (cx) => v.togglePin(cx), { on: v.pin })));
}

function body(v, id, rows, width) {
  return v_flex().id(id).flex_1().min_h(0).overflow_y_scrollbar().mode("hover")
    .child(h_flex().w_full().justify_center()
      .child(v_flex().w_full().max_w(v.compact ? 10000 : width).px(v.compact ? 8 : 20).pt(v.compact ? 10 : 24).pb(28).gap(1)
        .font_family(SANS).children(rows.filter(Boolean))));
}

function empty(t, text) {
  return div().px(10).py(16).text_size(13).text_color(t.muted).child(text);
}

// ---------- Motion ----------

// Herdr animates opacity, size and position natively, but not colour. A mark whose colour changed
// fades its new look in over the old one: the render that notices the change draws the new look
// transparent, the next lets it rise, a third drops the old look underneath. A row new to a list
// rises the same way, in its place; rows never move because they advanced.
const FADE = 200;
const motionOf = (v) => (v.motion ??= { last: new Map(), fading: new Map(), lists: new Map(), pass: 0, wake: false });

// A mark that may change: `draw(value)` draws it for a value; `id` names this drawing of it.
function marked(v, key, value, draw, id) {
  const m = motionOf(v);
  const before = m.last.get(key);
  m.last.set(key, value);
  if (before !== undefined && before !== value) m.fading.set(key, { from: before, to: value, phase: 0 });
  const f = m.fading.get(key);
  if (!f || f.to !== value) {
    m.fading.delete(key);
    return draw(value);
  }
  m.wake = true;
  return div().relative().flex_none().child(draw(f.from))
    .child(div().id(`${id}-${value}`).absolute().top(0).left(0).opacity(f.phase ? 1 : 0)
      .transition("opacity", { duration: FADE, easing: "ease-out" }).child(draw(value)));
}

// A row in a list: one the list didn't have when last drawn fades in. A list's first drawing,
// e.g. on opening a level, shows as it is.
function arriving(v, list, key, el) {
  const m = motionOf(v);
  let known = m.lists.get(list);
  if (!known) m.lists.set(list, known = { pass: m.pass, keys: new Set() });
  const fresh = known.pass !== m.pass && !known.keys.has(key);
  known.keys.add(key);
  const id = `row:${list}:${key}`;
  if (fresh) m.fading.set(id, { from: null, to: true, phase: 0 });
  const f = m.fading.get(id);
  if (!f) return el;
  m.wake = true;
  return el.opacity(f.phase ? 1 : 0).transition("opacity", { duration: 240, easing: "ease-out" });
}

// After a render: how long until the motion's next step, or null when nothing is fading.
export function motionStep(v) {
  const m = v.motion;
  if (!m?.wake || m.pending) return null;
  m.wake = false;
  m.pending = true;
  return [...m.fading.values()].some((f) => !f.phase) ? 16 : FADE + 60;
}

// Raises what was drawn transparent; settles what has risen.
export function advanceMotion(v) {
  const m = v.motion;
  m.pending = false;
  const rising = [...m.fading.values()].some((f) => !f.phase);
  for (const [key, f] of m.fading) {
    if (!f.phase) f.phase = 1;
    else if (!rising) m.fading.delete(key);
  }
}

// One package's box: ended in a muted green; at work in its step's full colour (red while its checks
// fail); launching, with no worker terminal yet, as an outline in Implementing's colour; planned
// hollow. A changed look fades in. Boxes hold still: the running checks dot is what moves.
function box(v, t, pkg, size, id) {
  const look = pkg.stage === "ended" ? "ended" : pkg.stage === "planned" ? "planned" : pkg.failed ? "failed" : pkg.stage;
  return marked(v, `box:${pkg.id}`, look, (k) => drawBox(t, k, size), id);
}

// Each step's colour: the dashboard's build blue for implementing, review violet for Review/CI, merge
// green for ready.
const TONE = { implementing: "build", review_ci: "review", ready: "merge" };
const stageColor = (t, stage) => signal()[TONE[stage]] ?? t.muted;

function drawBox(t, look, size) {
  const c = signal();
  const base = div().size(size).flex_none().rounded(2);
  if (look === "ended") return base.bg(tint(c.merge, "66"));
  if (look === "planned") return base.border(1).border_color(tint(t.foreground, "38"));
  if (look === "failed") return base.bg(c.fail);
  if (look === "launching") return base.border(1.5).border_color(c.build);
  return base.bg(stageColor(t, look));
}

// The PR's checks: a hollow ring before they start, a solid amber dot with a pulsing amber halo while
// they run, green once passed, red when failed. No words; the tooltip names it.
// A package's dot also says, on hover, when its checks last changed.
const CI_TIP = { waiting: "Checks not started", running: "Checks running", passed: "Checks passed", failed: "Checks failed", unknown: "Checks unavailable" };
function ciDot(v, t, key, state, id, since = null) {
  if (!state) return null;
  const tip = since === null || state === "waiting" ? CI_TIP[state] : `${CI_TIP[state]} · ${since}`;
  return h_flex().id(id).w(8).h(8).flex_none().items_center().justify_center().tooltip(tip).accessibility_label(tip)
    .child(marked(v, `ci:${key}`, state, (s) => drawCi(t, s), `${id}-mark`));
}

function drawCi(t, state) {
  const c = signal();
  const base = div().size(8).flex_none().rounded(4);
  if (state === "waiting" || state === "unknown") return base.border(1.5).border_color(tint(t.foreground, "55"));
  if (state === "running") return div().relative().size(8).flex_none()
    .child(div().absolute().top(-3).left(-3).size(14).rounded(7).border(1.5).border_color(c.checks)
      .loop("opacity", { from: 0, to: 0.9, period: 1600 }))
    .child(base.bg(c.checks));
  return base.bg(state === "passed" ? c.merge : c.fail);
}

// The dashboard's strip: one box per package, a hairline between phases.
function strip(v, t, runs, id, size = 10) {
  return h_flex().id(id).flex_wrap().gap_y(4).items_center().min_w(0).children(runs.map((run, i) =>
    h_flex().id(`${id}-${i}`).flex_none().gap(3).items_center()
      .when(i > 0, (el) => el.ml(4).pl(5).border_l(1).border_color(tint(t.foreground, "26")))
      .when(Boolean(run.phase), (el) => el.tooltip(run.phase))
      .children(run.pkgs.map((pkg) => h_flex().id(`${id}-box-${pkg.id}`).flex_none().tooltip(pkg.title).child(box(v, t, pkg, size, `${id}-box-${pkg.id}`))))));
}

// ---------- Topic and Space ----------

function taskRow(v, t, task, wide) {
  const { job } = task;
  const quiet = task.later;
  const title = div().min_w(0).flex_shrink(1).truncate().text_size(13.5).font_medium().text_color(quiet ? t.muted : t.foreground).child(job.title);
  const phase = job.phase !== "active" ? P.phaseBadge(t, job.phase, job.id) : null;
  const runs = task.total > 0 && !quiet ? strip(v, t, task.strip, `strip-${job.id}`) : null;
  // The task's checks sit at the row's right edge, wide or narrow, in a slot kept from the start.
  const ci = quiet ? null : ciDot(v, t, job.id, task.ci, `ci-${job.id}`);
  const head = h_flex().flex_1().min_w(0).gap(10).items_center().child(title).when(Boolean(phase), (x) => x.child(phase));
  const el = wide
    ? h_flex().id(`task-${job.id}`).flex_none().px(10).py(quiet ? 6 : 11).gap(24).items_center()
      .child(head).when(Boolean(runs), (x) => x.child(h_flex().w(380).flex_none().justify_end().child(runs)))
      .when(Boolean(ci), (x) => x.child(div().ml(-12).flex_none().child(ci)))
    : v_flex().id(`task-${job.id}`).flex_none().px(10).py(quiet ? 6 : 10).gap(8)
      .child(h_flex().gap(10).items_center().child(head).when(Boolean(ci), (x) => x.child(ci)))
      .when(Boolean(runs), (x) => x.child(runs));
  return reach(v, t, el, `task:${job.id}`, (cx) => v.openJob(job, { pkg: task.asks.find((a) => a.pkgId)?.pkgId ?? null }, cx), job.title);
}

// A shelf, closed until asked for, as the dashboard keeps its shelves.
function shelf(v, t, key, label, rows) {
  if (!rows.length) return [];
  const open = v.expanded.has(key);
  const toggle = reach(v, t, h_flex().id(`later-${key}`).flex_none().mt(14).px(10).py(7).gap(8).items_center(), `later:${key}`,
    (cx) => v.toggleExpanded(key, cx), label)
    .child(svg(icon(open ? "chevron-down" : "chevron-right")).size(11).flex_none().text_color(t.dim))
    .child(micro(t, label, t.dim))
    .child(mono(10.5, t.dim).child(String(rows.length)));
  return [toggle, ...(open ? rows : [])];
}

// Small work: one row per card, open ones first, with each card's asks under it.
function cardRows(v, t, cards) {
  if (!cards.length) return [];
  return [
    div().px(10).pt(18).pb(4).child(micro(t, "Small work", t.dim)),
    ...cards.flatMap((card) => [
      arriving(v, "cards", card.id, P.cardRow(v, t, card, ciDot(v, t, card.id, S.ciOf(card), `ci-card-${card.id}`))),
      ...card.asks.map((ask) => div().pl(28).child(P.askBlock(v, t, ask))),
    ]),
  ];
}

function scopeRows(v, t, tasks, cards, key) {
  const wide = !v.compact;
  if (!tasks.length && !cards.length) return [empty(t, "Nothing running here")];
  const current = tasks.filter((task) => !task.later);
  const asking = current.filter((task) => task.asks.length);
  const rest = current.filter((task) => !task.asks.length);
  const group = (task) => arriving(v, `scope:${key}`, task.job.id, v_flex().id(`group-${task.job.id}`).flex_none()
    .child(taskRow(v, t, task, wide))
    .children(task.asks.map((ask) => div().pl(10).child(P.askBlock(v, t, ask.question))))
    .children(task.decisions.map((d) => div().pl(10).child(P.decisionBlock(v, t, d)))));
  return [
    asking.length ? div().px(10).pb(4).child(micro(t, "Needs you", signal().you)) : null,
    ...asking.map(group),
    asking.length && rest.length ? div().h(14).flex_none() : null,
    ...rest.map(group),
    ...cardRows(v, t, cards),
    ...shelf(v, t, key, "Planned and landed", tasks.filter((task) => task.later && !task.archived).map((task) => taskRow(v, t, task, wide))),
    ...shelf(v, t, `archived:${key}`, "Archived", tasks.filter((task) => task.archived).map((task) => taskRow(v, t, task, wide))),
  ];
}

// ---------- Drill-in ----------

// The web board's four-step track: the way travelled dim, the current step in its colour (red while
// its checks fail), the way ahead faint.
const TRACK = ["launching", "implementing", "review_ci", "ready"];
function track(t, pkg) {
  const at = TRACK.indexOf(pkg.stage);
  const now = pkg.failed ? signal().fail : pkg.stage === "launching" ? signal().build : stageColor(t, pkg.stage);
  return h_flex().flex_none().gap(2).items_center().children(TRACK.map((_, i) =>
    div().w(7).h(3).rounded(1).bg(i < at ? tint(t.foreground, "55") : i === at ? now : tint(t.foreground, "1c"))));
}

// The fixed columns of a package's progress: the track, its step and time in it; Review Suite's mode
// and state; the PR. An ended package says how it ended instead; a planned one what it waits on.
function progress(v, t, pkg, now) {
  const ended = pkg.stage === "ended";
  const planned = pkg.stage === "planned";
  const label = ended ? M.ENDING_LABEL[pkg.ending] : planned ? (pkg.after.length ? `After ${pkg.after.join(", ")}` : "Planned") : M.STAGE_LABEL[pkg.stage];
  const tone = ended ? (pkg.outcome === "dropped" ? t.dim : tint(signal().merge, "cc")) : planned ? t.dim : pkg.failed ? signal().fail : stageColor(t, pkg.stage);
  const time = !ended && !planned && !pkg.untimed && pkg.since !== null ? M.span(now - pkg.since) : null;
  const review = !planned ? S.reviewText(pkg.review) : null;
  const pr = pkg.pr.number ? Button.new(`pr-step-${pkg.id}`).flex_none().cursor_pointer().font_family(MONO).text_size(11).text_color(t.muted).underline()
    .hover((s) => s.text_color(t.foreground)).tooltip(`Open ${pkg.pr.repo && pkg.pr.repo !== pkg.repo ? pkg.pr.repo : "PR"} #${pkg.pr.number}`)
    .on_click((_e, cx) => { cx.stop_propagation(); if (pkg.pr.url) cx.open_url(pkg.pr.url); })
    .child(pkg.finishable ? `${M.shortRepo(pkg.pr.repo)}#${pkg.pr.number}` : `#${pkg.pr.number}`) : null;
  return h_flex().flex_1().min_w(0).gap(8).items_center()
    .when(!ended && !planned, (el) => el.child(track(t, pkg)))
    .child(mono(11, tone).font_semibold().when(!planned, (el) => el.w(ended ? 78 : 84)).when(planned, (el) => el.min_w(0).truncate()).child(label))
    .when(!ended && !planned, (el) => el.child(mono(11, t.dim).w(44).child(time ?? "")))
    .child(mono(11, pkg.review.state === "findings" ? signal().checks : t.dim).flex_1().min_w(0).truncate().child(review ?? ""))
    .when(Boolean(pr), (el) => el.child(pr));
}

// Behind a click on a package: its review and its studio.
function pkgActions(v, t, job, pkg, ctx) {
  const ui = typeof v.openStudio === "function" && St.uiPackage(job, pkg, ctx.bindings, ctx.terminals);
  const list = [
    R.roundsOf(pkg).length ? ghost(t, `review-${pkg.id}`, "Review", (cx) => (v.review?.pkgId === pkg.id ? v.closeReview(cx) : v.openReview(job.id, pkg.id, null, cx)), { glyph: "message-circle", strong: v.review?.pkgId === pkg.id }) : null,
    ui ? ghost(t, `studio-${pkg.id}`, "Studio", (cx) => v.openStudio(job, pkg, cx), { glyph: "monitor" }) : null,
  ].filter(Boolean);
  const action = list.length ? h_flex().gap(2).flex_wrap().children(list) : null;
  if (!action && ctx.review?.id !== pkg.id) return null;
  return v_flex().pl(26).pr(8).pb(10).pt(2).gap(8)
    .when(Boolean(action), (el) => el.child(action))
    .when(ctx.review?.id === pkg.id, (el) => el.child(reviewPane(v, t, pkg, ctx, true)));
}

// A package: its box, its name (an orange dot while an ask waits on the person), its checks, the
// terminal working on it and Finish when only Finish can end it; then its progress columns, beside
// the name when wide and under it when narrow. Columns keep their widths so rows line up. Selected,
// it takes the accent rather than a deeper grey, so it stands apart from the zebra rows.
function pkgRow(v, t, job, e, ctx, wide, odd, indent = 0) {
  const { pkg } = e;
  const on = v.pkgSel === pkg.id;
  const focused = on && v.keys.is_focused();
  const quiet = pkg.stage === "ended" || pkg.stage === "planned";
  const name = h_flex().flex_1().min_w(0).gap(8).items_center()
    .child(div().min_w(0).flex_shrink(1).truncate().text_size(13).text_color(quiet ? t.muted : t.foreground).child(pkg.title))
    .when(e.needsYou, (el) => el.child(div().size(6).flex_none().rounded(3).bg(signal().you).tooltip("Waits on you")));
  const lead = h_flex().id(`lead-${pkg.id}`).w(10).flex_none().justify_center().child(box(v, t, pkg, 8, `lead-${pkg.id}`));
  const ci = h_flex().w(8).flex_none().child(ciDot(v, t, pkg.id, S.ciOf(pkg), `ci-${pkg.id}`, M.ago(pkg.pr.checksAt, ctx.now)) ?? div());
  const owner = h_flex().w(wide ? 150 : 118).flex_none().justify_end()
    .child(P.ownerChip(v, t, pkg.owner, `pkg-${pkg.id}`, { path: `/work-packages/${encodeURIComponent(pkg.id)}` }) ?? div());
  const finish = pkg.finishable ? P.confirmButton(v, t, `finish-${pkg.id}`, "Finish", "Finish it?", `finish:${pkg.id}`,
    (cx) => v.operate(`finish:${pkg.id}`, `/work-packages/${encodeURIComponent(pkg.id)}/finish`, {}, cx)) : null;
  const finishError = v.ops[`finish:${pkg.id}`]?.error;
  const columns = progress(v, t, pkg, ctx.now);
  // A nested group indents only the name, so every column keeps its place.
  const named = h_flex().flex_1().min_w(0).gap(10).items_center().pl(indent).child(lead).child(name);
  const content = wide
    ? h_flex().flex_1().min_w(0).gap(10).items_center().child(h_flex().w(280).flex_none().child(named)).child(columns).child(ci).child(owner)
      .child(h_flex().w(64).flex_none().justify_end().child(finish ?? div()))
    : v_flex().flex_1().min_w(0).gap(4)
      .child(h_flex().gap(10).items_center().child(named).child(ci).when(Boolean(finish), (x) => x.child(finish)).child(owner))
      .child(h_flex().gap(10).items_center().child(div().w(10).flex_none()).child(columns));
  const row = h_flex().id(`pkg-${pkg.id}`).flex_none().px(10).py(wide ? 6 : 7).items_center().cursor_pointer().rounded(5)
    .bg(on ? tint(t.accent, "24") : odd ? tint(t.foreground, "07") : CLEAR).border(1).border_color(on ? tint(t.accent, focused ? "cc" : "80") : CLEAR)
    .hover((s) => s.bg(on ? tint(t.accent, "2e") : tint(t.foreground, "10")))
    .accessibility_label(`${pkg.title}, ${pkg.stage === "ended" ? M.ENDING_LABEL[pkg.ending] : M.STAGE_LABEL[pkg.stage]}${e.needsYou ? ", waits on you" : ""}`)
    .on_click((_e, cx) => v.selectPackage(on ? null : pkg.id, cx))
    .child(content);
  const actions = on ? pkgActions(v, t, job, pkg, ctx) : null;
  const shown = arriving(v, `job:${job.id}`, pkg.id, row);
  return [shown, finishError ? div().ml(36).pb(4).text_size(11.5).text_color(signal().fail).child(finishError) : null, actions].filter(Boolean);
}

// The packages at work under their group paths: a phase label per first segment, its nested groups
// indented under it, ungrouped work last without a label.
function grouped(v, t, job, entries, ctx, wide) {
  const rows = [];
  let i = 0;
  const walk = (node) => {
    if (node.name) {
      const top = node.depth === 0;
      rows.push(div().id(`group-${job.id}-${node.depth}-${node.name}`).flex_none().pl(10 + node.depth * 14).pt(top ? 12 : 6).pb(3)
        .child(top ? micro(t, node.name, t.muted) : div().text_size(11.5).font_medium().text_color(t.dim).child(node.name)));
    }
    for (const e of node.items) rows.push(...pkgRow(v, t, job, e, ctx, wide, (i++) % 2 === 0, node.name ? Math.min(node.depth, 2) * 14 : 0));
    for (const child of node.children) walk(child);
  };
  for (const node of S.groupTree(entries)) walk(node);
  return rows;
}

// Ended and planned packages fold into one mark each: a label and their boxes, opened on request.
// The keys reach a fold like a package row, and Enter opens it.
function fold(v, t, job, label, parts, ctx, wide) {
  if (!parts.length) return [];
  const key = `${label}:${job.id}`;
  const open = v.expanded.has(key);
  const on = v.pkgSel === `fold:${key}` && v.keys.is_focused();
  const toggle = h_flex().id(`fold-${key}`).flex_none().mt(6).px(10).py(7).gap(10).items_center().cursor_pointer().rounded(6)
    .border(1).border_color(on ? tint(t.accent, "80") : CLEAR).hover((s) => s.bg(tint(t.foreground, "08")))
    .accessibility_label(label).on_click((_e, cx) => v.toggleExpanded(key, cx))
    .child(svg(icon(open ? "chevron-down" : "chevron-right")).size(11).flex_none().text_color(t.dim))
    .child(micro(t, label, t.dim))
    .child(strip(v, t, [{ pkgs: parts.map((e) => e.pkg) }], `fold-strip-${key}`, 8));
  return [toggle, ...(open ? parts.flatMap((e, i) => pkgRow(v, t, job, e, ctx, wide, i % 2 === 0)) : [])];
}

// The task's head: its phase, the terminal working on it, and the person's calls on it. An
// unresolved task names the packages that didn't land.
function taskHead(v, t, job, task) {
  const dropped = job.packages.filter((pkg) => pkg.outcome === "dropped");
  return v_flex().id("task-head").flex_none().px(10).pb(12).gap(10)
    .child(h_flex().gap(12).items_center().flex_wrap()
      .child(P.phaseBadge(t, job.phase, job.id))
      .child(P.ownerChip(v, t, job.owner, `job-${job.id}`, { path: `/work-requests/${encodeURIComponent(job.id)}` }) ?? div())
      .child(div().flex_1())
      .child(P.phaseActions(v, t, job)))
    .when(task.total > 0, (el) => el.child(strip(v, t, task.strip, `strip-${job.id}`, 11)))
    .when(job.phase === "unresolved" && dropped.length > 0, (el) => el.child(v_flex().id("unresolved").gap(2)
      .children(dropped.map((pkg) => h_flex().gap(8).items_center()
        .child(div().min_w(0).truncate().text_size(12.5).text_color(t.foreground).child(pkg.title))
        .child(mono(11, pkg.ending === "abandoned" ? signal().fail : t.dim).child(M.ENDING_LABEL[pkg.ending].toLowerCase()))))));
}

// The task's head, its asks and decisions, then the packages at work under their groups in planned
// order, with ended and planned work folded below. Packages never move when they advance.
function jobRows(v, t, job, ctx) {
  const task = S.taskOf(job, ctx.now);
  const wide = !v.compact;
  const parts = S.packageParts(task);
  const folded = (label, list) => (list.length ? [`fold:${label}:${job.id}`, ...(v.expanded.has(`${label}:${job.id}`) ? list.map((e) => e.pkg.id) : [])] : []);
  const order = [];
  const visit = (node) => { order.push(...node.items.map((e) => e.pkg.id)); node.children.forEach(visit); };
  S.groupTree(parts.active).forEach(visit);
  v.rowOrder = [...order, ...folded("Landed", parts.landed), ...folded("Up next", parts.queued)];
  if (v.pkgSel && !v.rowOrder.includes(v.pkgSel)) v.pkgSel = null;
  return [
    taskHead(v, t, job, task),
    task.asks.length ? div().px(10).pb(4).child(micro(t, "Needs you", signal().you)) : null,
    ...task.asks.map((ask) => div().pl(10).child(P.askBlock(v, t, ask.question))),
    task.decisions.length ? div().px(10).pt(4).pb(4).child(micro(t, "Decisions to review", t.dim)) : null,
    ...task.decisions.map((d) => div().pl(10).child(P.decisionBlock(v, t, d))),
    !task.total ? empty(t, "Not sliced into packages yet") : null,
    ...grouped(v, t, job, parts.active, ctx, wide),
    ...fold(v, t, job, "Landed", parts.landed, ctx, wide),
    ...fold(v, t, job, "Up next", parts.queued, ctx, wide),
  ];
}

// ---------- Levels ----------

// One task, as the panel's drill-in or as the task's own tab (`tab`: no way back, no new task).
export function taskLevel(v, t, job, ctx) {
  motionOf(v).pass += 1;
  const review = v.review?.jobId === job.id ? job.packages.find((pkg) => pkg.id === v.review.pkgId) ?? null : null;
  if (!review) v.review = null;
  v.shown = { jobId: job.id, bindings: J.jobBindings(job, ctx.bindings) };
  v.agentWatch = { key: job.id, bindings: v.shown.bindings };
  v.currentJob = job;
  const jctx = { ...ctx, offline: ctx.board.offline === true, review };
  return [bar(v, t, job.title, ctx.now, { create: false, back: !ctx.tab }), body(v, "lens-job", jobRows(v, t, job, jctx), 1100)];
}

// The topic's spaces as the dashboard's area filters: All, then each space with a repository, one
// per repository; a Space is its topic with one of them chosen. Chief spaces are left out.
function filters(v, t, path, desk) {
  const topic = desk.find((x) => x.id === path.topic);
  const made = shared(CHIEF_SPACES);
  const seen = new Set();
  const spaces = (topic?.spaces ?? []).filter((s) => {
    const repo = L.spaceRepo(s);
    if (!repo || seen.has(repo) || (topic.kind === "topic" && isChiefSpace(s, topic, made))) return false;
    seen.add(repo);
    return true;
  });
  if (!spaces.length) return null;
  const pill = (id, label, on, go) => Button.new(id).flex().flex_none().items_center().h(22).px(8).rounded(5).cursor_pointer()
    .font_family(SANS).text_size(12).bg(on ? tint(t.foreground, "14") : CLEAR).text_color(on ? t.foreground : t.muted)
    .hover((s) => s.text_color(t.foreground)).focus((s) => s.border(1).border_color(t.accent))
    .accessibility_label(label).on_click((_e, cx) => { cx.stop_propagation(); go(cx); }).child(label);
  return h_flex().id("space-filters").flex_none().px(v.compact ? 12 : 20).pt(10).gap(2).flex_wrap()
    .child(pill("filter-all", "All", !path.space, (cx) => v.openTopic(topic.id, cx)))
    .children(spaces.map((s) => pill(`filter-${s.id}`, [s.name || L.spaceRepo(s), s.machine].filter(Boolean).join(" · "), path.space === s.id, (cx) => v.openSpace(s.id, topic.id, cx))));
}

// A Topic or Space: the tasks touching it, then its small work. ctx: { board, desk, path, bindings, terminals, now }.
export function scopeLevel(v, t, ctx) {
  const { board, desk, path, now } = ctx;
  motionOf(v).pass += 1;
  const title = S.scopeTitle(path, desk);
  if (v.intake) return [bar(v, t, title, now), O.intakeForm(v, t)];
  const tasks = S.scopeTasks(path, desk, board.jobs, v.place, now);
  const cards = S.scopeCards(path, desk, board.cards, v.place);
  return [bar(v, t, title, now), filters(v, t, path, desk), body(v, "lens-scope", scopeRows(v, t, tasks, cards, `${path.topic}:${path.space ?? ""}`), 820)];
}
