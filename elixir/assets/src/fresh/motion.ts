// Motion has one job here: make a change noticeable. Nothing moves on the first paint or a view switch,
// and a reread of the ledger moves only what changed, because every list is diffed by key.
import { Component, useCallback, useLayoutEffect, useRef, useState, type ReactNode } from "react";

export const EASE = "cubic-bezier(0.2, 0, 0, 1)";
export const POP: Keyframe[] = [{ transform: "scale(2.6)", filter: "brightness(1.6)" }, { transform: "scale(1)", filter: "brightness(1)" }];
export const GLOW: Keyframe[] = [{ backgroundColor: "rgb(255 255 255 / 0.16)" }, {}];
const SPOTLIGHT: Keyframe[] = [{ backgroundColor: "rgb(255 122 69 / 0.18)", boxShadow: "0 0 0 1px rgb(255 122 69 / 0.9)" }, { backgroundColor: "rgb(255 122 69 / 0.1)", boxShadow: "0 0 0 1px rgb(255 122 69 / 0.6)", offset: 0.6 }, {}];

export function calm() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// The parts of a box that keep it open: collapsing to zero takes all of them, or padding and margins would jump at the end.
const BOX = ["height", "paddingTop", "paddingBottom", "marginTop", "marginBottom", "borderTopWidth", "borderBottomWidth"] as const;

function boxOf(node: HTMLElement): Keyframe {
  const style = getComputedStyle(node);
  return Object.fromEntries(BOX.map((key) => [key, key === "height" ? `${node.offsetHeight}px` : style[key]]));
}

const FLAT: Keyframe = Object.fromEntries(BOX.map((key) => [key, "0px"]));

function clipped(node: HTMLElement, animation: Animation) {
  node.style.overflow = "clip";
  const release = () => (node.style.overflow = "");
  animation.finished.then(release, release);
  return animation;
}

// A new row opens from nothing and pushes what is below it down; its content settles in a moment later.
export function growIn(node: HTMLElement) {
  if (calm()) return void node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150 });
  clipped(node, node.animate([FLAT, boxOf(node)], { duration: 280, easing: EASE }));
  node.animate([{ opacity: 0, transform: "translateY(-8px)" }, { opacity: 1, transform: "none" }], { duration: 300, delay: 60, easing: EASE, fill: "backwards" });
}

// A row that left closes up, and what is below it moves up into its place.
export function collapseOut(node: HTMLElement) {
  if (calm()) return node.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, fill: "forwards" }).finished;
  return clipped(node, node.animate([{ ...boxOf(node), opacity: 1 }, { ...FLAT, opacity: 0 }], { duration: 200, easing: EASE, fill: "forwards" })).finished;
}

// A row that changed places glides from where it was.
function glide(node: HTMLElement, dy: number) {
  if (calm() || Math.abs(dy) < 1) return;
  node.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], { duration: 260, easing: EASE });
}

type Entry<T> = { key: string; item: T; leaving: boolean; fresh: boolean };
export type Present<T> = { key: string; item: T; leaving: boolean; ref: (node: HTMLElement | null) => void };
// `holdsOf` names the rows inside an item whose exits it waits for before it closes up; by default, only its own.
type PresenceProps<T> = { children: (entry: Present<T>) => ReactNode; holdsOf?: (item: T) => string[]; items: readonly T[]; keyOf: (item: T) => string };
type PresenceState<T> = { items: readonly T[]; entries: Array<Entry<T>> };

// Rows that must finish something before they close up, such as a goal playing its exit.
const holds = new Map<string, Promise<unknown>>();
export function holdLeave(key: string, until: Promise<unknown>) {
  holds.set(key, until);
  void until.finally(() => holds.get(key) === until && holds.delete(key));
}

// The new list, with rows that left kept in place after whatever came before them.
function merge<T>(was: Array<Entry<T>>, items: readonly T[], keyOf: (item: T) => string): Array<Entry<T>> {
  const old = new Map(was.map((entry) => [entry.key, entry]));
  const entries = items.map((item) => {
    const key = keyOf(item);
    return { key, item, leaving: false, fresh: !old.has(key) };
  });
  const listed = new Set(entries.map((entry) => entry.key));
  was.forEach((entry, index) => {
    if (listed.has(entry.key)) return;
    let at = 0;
    for (let back = index - 1; back >= 0; back -= 1) {
      const found = entries.findIndex((other) => other.key === was[back].key);
      if (found >= 0) {
        at = found + 1;
        break;
      }
    }
    entries.splice(at, 0, { ...entry, leaving: true, fresh: false });
  });
  return entries;
}

const stays = <T,>(entries: Array<Entry<T>>) => entries.filter((entry) => !entry.leaving).map((entry) => entry.key);

// A keyed list that animates its changes: new rows grow in, rows that left close up after any exit they play,
// and rows that changed order glide to their new place. Nothing animates on the list's first render.
// Every row's root element takes the entry's `ref`; a row that left is still rendered, marked `leaving`, until it has closed up.
export class Presence<T> extends Component<PresenceProps<T>, PresenceState<T>> {
  private nodes = new Map<string, HTMLElement>();
  private handles = new Map<string, (node: HTMLElement | null) => void>();
  private closing = new Set<string>();
  private grown = new WeakSet<Entry<T>>();

  constructor(props: PresenceProps<T>) {
    super(props);
    this.state = { items: props.items, entries: props.items.map((item) => ({ key: props.keyOf(item), item, leaving: false, fresh: false })) };
  }

  static getDerivedStateFromProps<T>(props: PresenceProps<T>, state: PresenceState<T>): Partial<PresenceState<T>> | null {
    return props.items === state.items ? null : { items: props.items, entries: merge(state.entries, props.items, props.keyOf) };
  }

  // Rows that change order are measured before the DOM moves them.
  getSnapshotBeforeUpdate(_: PresenceProps<T>, before: PresenceState<T>) {
    const now = stays(this.state.entries);
    const stayed = stays(before.entries).filter((key) => now.includes(key));
    const order = now.filter((key) => stayed.includes(key));
    if (order.join() === stayed.join()) return null;
    return new Map(order.map((key) => [key, this.nodes.get(key)?.getBoundingClientRect().top ?? 0]));
  }

  componentDidUpdate(_: PresenceProps<T>, __: PresenceState<T>, tops: Map<string, number> | null) {
    for (const entry of this.state.entries) this.settle(entry, this.nodes.get(entry.key));
    for (const [key, top] of tops ?? []) {
      const node = this.nodes.get(key);
      if (node) glide(node, top - node.getBoundingClientRect().top);
    }
  }

  // A row that left closes up; one that came back before it had closed stays; a new one grows in, once.
  private settle(entry: Entry<T>, node: HTMLElement | undefined) {
    if (entry.leaving) return this.close(entry.key, node, this.props.holdsOf?.(entry.item) ?? [entry.key]);
    if (this.closing.delete(entry.key)) return node?.getAnimations().forEach((animation) => animation.cancel());
    if (!entry.fresh || !node || this.grown.has(entry)) return;
    this.grown.add(entry);
    growIn(node);
  }

  private close(key: string, node: HTMLElement | undefined, waits: string[]) {
    if (this.closing.has(key)) return;
    this.closing.add(key);
    void Promise.all(waits.map((wait) => holds.get(wait)))
      .catch(() => undefined)
      .then(() => (node && this.closing.has(key) ? collapseOut(node) : undefined))
      .then(() => {
        if (!this.closing.delete(key)) return;
        this.setState((state) => ({ entries: state.entries.filter((entry) => !(entry.key === key && entry.leaving)) }));
      });
  }

  private refOf(key: string) {
    let ref = this.handles.get(key);
    if (!ref) {
      ref = (node) => (node ? this.nodes.set(key, node) : this.nodes.delete(key));
      this.handles.set(key, ref);
    }
    return ref;
  }

  render() {
    return this.state.entries.map((entry) => this.props.children({ key: entry.key, item: entry.item, leaving: entry.leaving, ref: this.refOf(entry.key) }));
  }
}

// Plays once when a value changes after the first render, so the eye lands on what just moved.
// Returns a callback ref for the element that plays.
export function useFlash(value: string, frames: Keyframe[], duration: number) {
  const node = useRef<HTMLElement | null>(null);
  const seen = useRef(value);

  useLayoutEffect(() => {
    if (seen.current === value) return;
    seen.current = value;
    if (!calm()) node.current?.animate(frames, { duration, easing: "ease-out" });
  }, [duration, frames, value]);
  return useCallback((element: HTMLElement | null) => {
    node.current = element;
  }, []);
}

// A number that rolls to its new value: up when it grows, down when it shrinks. The element shows only text this hook writes.
export function useRoll(value: number) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useRef<number | null>(null);

  useLayoutEffect(() => {
    const node = ref.current;
    const old = seen.current;
    seen.current = value;
    if (!node) return;
    if (old === null || old === value || calm()) return void (node.textContent = String(value));
    const up = value > old;
    const column = document.createElement("span");
    column.style.cssText = "display:flex;flex-direction:column";
    for (const shown of up ? [old, value] : [value, old]) column.append(Object.assign(document.createElement("span"), { textContent: String(shown) }));
    node.replaceChildren(column);
    const roll = column.animate(up ? [{ transform: "translateY(0)" }, { transform: "translateY(-50%)" }] : [{ transform: "translateY(-50%)" }, { transform: "translateY(0)" }], { duration: 280, easing: EASE });
    roll.finished.then(() => seen.current === value && (node.textContent = String(value)), () => undefined);
  }, [value]);
  return ref;
}

const GLYPHS = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz0123456789";

// New text arrives letter by letter: each character churns briefly, then settles, left to right.
// The element shows only text this hook writes.
export function useScramble(text: string, duration = 650) {
  const ref = useRef<HTMLSpanElement>(null);
  const seen = useRef<string | null>(null);

  useLayoutEffect(() => {
    const node = ref.current;
    const old = seen.current;
    seen.current = text;
    if (!node) return;
    if (old === null || old === text) return void (node.textContent = text);
    if (calm()) {
      node.textContent = text;
      return void node.animate([{ opacity: 0.2 }, { opacity: 1 }], { duration: 150 });
    }
    // The box takes the new text's height up front, so the scramble itself never changes the layout.
    const box = node.parentElement;
    if (box) {
      const from = box.offsetHeight;
      node.textContent = text;
      const to = box.offsetHeight;
      if (from !== to) clipped(box, box.animate([{ height: `${from}px` }, { height: `${to}px` }], { duration: 300, easing: EASE }));
    }
    const length = text.length;
    const settle = Array.from({ length }, (_, index) => (index / length) * 0.7 + Math.random() * 0.25);
    const start = performance.now();
    let frame = 0;
    const step = (now: number) => {
      const progress = Math.min(1, (now - start) / duration);
      let out = "";
      for (let index = 0; index < length; index += 1) {
        const target = text[index] ?? "";
        out += progress >= settle[index] || target === " " ? target : GLYPHS[(Math.random() * GLYPHS.length) | 0];
      }
      node.textContent = progress < 1 ? out : text;
      if (progress < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => {
      cancelAnimationFrame(frame);
      node.textContent = text;
    };
  }, [duration, text]);
  return ref;
}

// A label that crossfades when it changes: the old one fades out, the new one fades in while the width glides between them.
export function useSwap<T>(value: T, key: string) {
  const ref = useRef<HTMLSpanElement>(null);
  const [shown, setShown] = useState({ key, value });
  const width = useRef(0);

  useLayoutEffect(() => {
    const node = ref.current;
    if (shown.key === key || !node) return;
    if (calm()) return;
    const out = node.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 110, fill: "forwards" });
    out.finished.then(() => {
      width.current = node.offsetWidth;
      setShown({ key, value });
    }, () => undefined);
    return () => out.cancel();
  }, [key, shown.key, value]);

  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !width.current) return;
    const from = width.current;
    width.current = 0;
    node.getAnimations().forEach((animation) => animation.cancel());
    node.animate([{ width: `${from}px` }, { width: `${node.offsetWidth}px` }], { duration: 200, easing: EASE });
    node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160 });
  }, [shown.key]);

  return { ref, shown: shown.key === key || calm() ? value : shown.value };
}

// Bring one goal under the header and light it up. A goal on a closed shelf opens its shelf first.
export function focusGoal(id: string) {
  spotlight(`[data-goal="${CSS.escape(id)}"]`);
}

export function spotlight(selector: string) {
  const node = document.querySelector<HTMLElement>(selector);
  if (!node) return;
  const shelf = node.closest("details");
  if (shelf) shelf.open = true;
  node.scrollIntoView({ behavior: calm() ? "auto" : "smooth", block: "start" });
  node.animate(SPOTLIGHT, { duration: 2600, easing: "ease-out" });
}
