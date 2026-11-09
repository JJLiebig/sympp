// The sympp visual language shared by every level: theme tokens only (light and dark alike), quiet
// by default, loud only for what needs the person. Shapes carry meaning as much as color.

import { div, svg } from "gpui-kit";
import { v_flex, h_flex, Button, Input, Textarea } from "gpui-base";
import { settings } from "herdr";

export const CLEAR = "#00000000";
export const MONO = "Geist Mono";
export const icon = (name) => (name.includes("/") ? name : `mods/workspace-chrome/${name}.svg`);
// Opens what the panel shows as a tab.
export const EXPAND = "mods/sympp/expand.svg";
export const tint = (color, alpha) => (/^#[0-9a-f]{6}$/i.test(color ?? "") ? color + alpha : color);

export function cap(text) {
  const value = String(text);
  return value.charAt(0).toUpperCase() + value.slice(1);
}

export function button(t, id, label, action, { strong = false, glyph = null, tip = null, disabled = false } = {}) {
  return Button.new(id).flex().flex_none().items_center().gap(6).h(26).px(9).rounded(6).text_size(12).cursor_pointer()
    .border(1).border_color(strong ? t.input : CLEAR)
    .text_color(strong ? t.foreground : t.muted)
    .hover((s) => s.bg(t.hover).text_color(t.foreground))
    .focus((s) => s.border_color(t.accent))
    .disabled(disabled).when(disabled, (el) => el.opacity(0.5))
    .accessibility_label(tip ?? label)
    .when(Boolean(tip), (el) => el.tooltip(tip))
    .on_click((_e, cx) => {
      cx.stop_propagation();
      action(cx);
    })
    .when(Boolean(glyph), (el) => el.child(svg(icon(glyph)).size(13).flex_none()))
    .when(Boolean(label), (el) => el.child(label));
}

// A square icon button for the panel's narrow bar; the tip names it.
export function iconButton(t, id, glyph, tip, action, { strong = false } = {}) {
  return Button.new(id).flex().flex_none().items_center().justify_center().size(24).rounded(6).cursor_pointer()
    .border(1).border_color(strong ? t.input : CLEAR)
    .text_color(strong ? t.foreground : t.muted)
    .hover((s) => s.bg(t.hover).text_color(t.foreground))
    .focus((s) => s.border_color(t.accent))
    .accessibility_label(tip).tooltip(tip)
    .on_click((_e, cx) => {
      cx.stop_propagation();
      action(cx);
    })
    .child(svg(icon(glyph)).size(13).flex_none());
}

export function field(t, label, state, multiline = false) {
  return v_flex().gap(6).min_w(0)
    .child(div().text_size(12).text_color(t.muted).child(label))
    .child(div().min_w(0).on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .child((multiline ? Textarea.new(state).h(110) : Input.new(state).h(34))
        .w_full().px(10).py(7).rounded(6).border(1).border_color(t.input).bg(t.background)
        .text_size(13).text_color(t.foreground).accessibility_label(label)));
}

// A job verdict's mark.
export function mark(t, verdict) {
  if (verdict === "needs_you") return div().size(8).flex_none().rounded(4).bg(t.blocked);
  if (verdict === "bump" || verdict === "stalled") return div().size(8).flex_none().rounded(2).bg(t.working);
  if (verdict === "on_track") return div().size(8).flex_none().rounded(4).bg(t.ansi2);
  if (verdict === "parked") return div().w(8).h(2).flex_none().rounded(1).bg(t.dim);
  if (verdict === "settled") return svg(icon("check")).size(11).flex_none().text_color(t.ansi2);
  return div().size(8).flex_none().rounded(4).border(1.5).border_color(t.dim);
}


// An agent's liveness: a filled dot only after a verified check, a ring for a last sighting.
export function presence(t, state) {
  if (state === "live") return div().size(7).flex_none().rounded(4).bg(t.ansi2);
  if (state === "seen") return div().size(7).flex_none().rounded(4).border(1.5).border_color(t.muted);
  if (state === "provider") return div().size(7).flex_none().rounded(1.5).border(1.5).border_color(t.muted);
  return div().w(7).h(1.5).flex_none().bg(t.dim);
}

export function section(t, label, count = null, tone = t.dim) {
  return h_flex().pt(18).pb(6).px(4).gap(6).items_center().flex_none()
    .child(div().text_size(11.5).font_medium().text_color(tone).child(label))
    .when(count !== null, (el) => el.child(div().text_size(11.5).text_color(t.muted).child(String(count))));
}


export function message(t, title, body, actions = []) {
  return v_flex().size_full().items_center().justify_center().gap(10).p(24)
    .child(div().text_size(15).font_semibold().text_color(t.foreground).child(title))
    .when(Boolean(body), (el) => el.child(div().max_w(460).text_size(12.5).text_color(t.muted).child(body)))
    .when(actions.length > 0, (el) => el.child(h_flex().gap(8).pt(4).children(actions)));
}

// ---------- The dashboard's language ----------

export const SANS = "Geist";

// The dashboard's signal colours (elixir/assets/src/fresh/fresh.css), with deeper twins for light themes.
const DARK = { build: "#6ea8fe", checks: "#e5b454", review: "#b794f6", merge: "#7bd88f", you: "#ff7a45", fail: "#ff5c6c" };
const LIGHT = { build: "#2563eb", checks: "#b7791f", review: "#7c3aed", merge: "#15803d", you: "#ea580c", fail: "#dc2626" };
export const signal = () => (settings()?.dark === false ? LIGHT : DARK);

// GPUI has no letter-spacing; the dashboard's tracked capitals are set with hair spaces instead.
const tracked = (text) => text.toUpperCase().split("").join(" ");

export function micro(t, text, color) {
  return div().flex_none().text_size(10).font_family(SANS).font_semibold().text_color(color).accessibility_label(text).child(tracked(text));
}

export const mono = (size, color) => div().flex_none().font_family(MONO).text_size(size).text_color(color);

// The dashboard's quiet buttons: no border, dim until hovered.
export function ghost(t, id, label, action, { glyph = null, tip = null, strong = false, disabled = false } = {}) {
  return Button.new(id).flex().flex_none().items_center().gap(6).h(24).px(8).rounded(5).cursor_pointer()
    .font_family(SANS).text_size(12).font_medium()
    .bg(strong ? tint(t.foreground, "14") : CLEAR).text_color(strong ? t.foreground : t.muted)
    .hover((s) => s.bg(tint(t.foreground, "1a")).text_color(t.foreground))
    .focus((s) => s.border(1).border_color(t.accent))
    .disabled(disabled).when(disabled, (el) => el.opacity(0.45))
    .accessibility_label(tip ?? label).when(Boolean(tip), (el) => el.tooltip(tip))
    .on_click((_e, cx) => { cx.stop_propagation(); action(cx); })
    .when(Boolean(glyph), (el) => el.child(svg(icon(glyph)).size(12).flex_none()))
    .when(Boolean(label), (el) => el.child(label));
}

// The person's action on a question, in their colour, tinted so it reads as theirs without shouting.
export function youButton(t, id, label, action, tip) {
  const you = signal().you;
  return Button.new(id).flex().flex_none().items_center().h(24).px(10).rounded(5).cursor_pointer()
    .font_family(SANS).text_size(12).font_semibold().text_color(you).bg(tint(you, "1f"))
    .hover((s) => s.bg(tint(you, "33")))
    .focus((s) => s.border(1).border_color(you))
    .accessibility_label(tip).tooltip(tip)
    .on_click((_e, cx) => { cx.stop_propagation(); action(cx); })
    .child(label);
}
