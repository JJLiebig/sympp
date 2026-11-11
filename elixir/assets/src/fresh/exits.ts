// How a goal leaves the board when the operator completes or deletes it. The goal turns into a canvas of pips:
// on Complete they swirl into a checkmark that pops into sparks, on Delete the goal blows away like dust.
// The effect holds part way until the factory answers; a refusal plays it back and the goal returns.
import { useSyncExternalStore } from "react";

import { calm, collapseOut, holdLeave } from "./motion";

const PITCH = 7;
const SIZE = 5;
// The point an exit waits at for the factory's answer, and turns back from on a refusal.
const HOLD = 0.42;
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

type Cell = { cx: number; cy: number; color: string; weight: number; seed: number };
type Map2 = { width: number; height: number; cells: Cell[] };
type Draw = (progress: number, ctx: CanvasRenderingContext2D, ox: number, oy: number) => void;
type Style = { duration: number; pad: [top: number, side: number, bottom: number]; make: (node: HTMLElement, map: Map2) => Draw };

function hash(index: number) {
  let x = Math.imul(index ^ 0x9e3779b9, 0x85ebca6b);
  x ^= x >>> 13;
  x = Math.imul(x, 0xc2b2ae35);
  x ^= x >>> 16;
  return (x >>> 0) / 4294967295;
}

const clamp01 = (value: number) => Math.max(0, Math.min(1, value));
const mix = (from: number, to: number, t: number) => from + (to - from) * t;
const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

const rgbOf = (() => {
  const ctx = document.createElement("canvas").getContext("2d")!;
  const memo = new Map<string, number[]>();
  return (color: string) => {
    let rgb = memo.get(color);
    if (!rgb) {
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = color;
      ctx.fillRect(0, 0, 1, 1);
      rgb = [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3);
      memo.set(color, rgb);
    }
    return rgb;
  };
})();

function lerpColor(from: string, to: string, t: number) {
  const [a, b] = [rgbOf(from), rgbOf(to)];
  return `rgb(${mix(a[0], b[0], t) | 0},${mix(a[1], b[1], t) | 0},${mix(a[2], b[2], t) | 0})`;
}

function pip(ctx: CanvasRenderingContext2D, x: number, y: number, size: number, color: string, alpha: number) {
  ctx.globalAlpha = clamp01(alpha);
  ctx.fillStyle = color;
  ctx.fillRect(x, y, size, size);
}

// The goal's real layout as pips: words become dithered bars, package dots stay dots, package rows thin out.
function pipMap(node: HTMLElement): Map2 {
  const box = node.getBoundingClientRect();
  const cols = Math.ceil(box.width / PITCH);
  const rows = Math.ceil(box.height / PITCH);
  const cells = new Map<number, Omit<Cell, "seed">>();
  const put = (cx: number, cy: number, color: string, weight: number) => {
    if (cx < 0 || cy < 0 || cx >= cols || cy >= rows) return;
    const key = cy * cols + cx;
    const prev = cells.get(key);
    if (!prev || prev.weight < weight) cells.set(key, { cx, cy, color, weight });
  };
  const fill = (rect: { left: number; right: number; top: number; bottom: number }, color: string, density: number, weight: number) => {
    const [x0, x1] = [Math.floor((rect.left - box.left) / PITCH), Math.ceil((rect.right - box.left) / PITCH)];
    const [y0, y1] = [Math.floor((rect.top - box.top) / PITCH), Math.ceil((rect.bottom - box.top) / PITCH)];
    for (let cy = y0; cy < y1; cy += 1) for (let cx = x0; cx < x1; cx += 1) if (BAYER[cy & 3][cx & 3] / 16 < density) put(cx, cy, color, weight);
  };
  const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  for (let text = walker.nextNode(); text; text = walker.nextNode()) {
    const parent = text.parentElement;
    if (!parent || parent.closest(".sr-only, [data-menu]")) continue;
    const style = getComputedStyle(parent);
    const size = parseFloat(style.fontSize);
    const density = size >= 16 ? 0.75 : size <= 12 ? 0.35 : 0.5;
    const words = /\S+/g;
    for (let match = words.exec(text.textContent ?? ""); match; match = words.exec(text.textContent ?? "")) {
      range.setStart(text, match.index);
      range.setEnd(text, match.index + match[0].length);
      for (const rect of range.getClientRects()) {
        const pad = rect.height * 0.22;
        fill({ left: rect.left, right: rect.right, top: rect.top + pad, bottom: rect.bottom - pad }, style.color, density, 2);
      }
    }
  }
  node.querySelectorAll<HTMLElement>("[data-pip]").forEach((dot) => {
    const rect = dot.getBoundingClientRect();
    const style = getComputedStyle(dot);
    const color = style.backgroundColor !== "rgba(0, 0, 0, 0)" ? style.backgroundColor : style.borderTopColor;
    put(Math.floor((rect.left + rect.width / 2 - box.left) / PITCH), Math.floor((rect.top + rect.height / 2 - box.top) / PITCH), color, 3);
  });
  node.querySelectorAll<HTMLElement>("[data-pkg-row]").forEach((row) => fill(row.getBoundingClientRect(), "#14161b", 0.55, 1));
  for (let cx = 0; cx < cols; cx += 1) if (BAYER[0][cx & 3] < 10) put(cx, 0, "#22252d", 1);
  return { width: box.width, height: box.height, cells: [...cells.values()].map((cell) => ({ ...cell, seed: hash(cell.cy * 9973 + cell.cx) })) };
}

// A short scanline pass, then the goal is handed to the canvas. Returns progress after the hand-off, or -1 before it.
function scanPrelude(node: HTMLElement, progress: number, until: number) {
  node.classList.toggle("exit-scan", progress > 0);
  node.style.setProperty("--scan", clamp01(progress / until).toFixed(3));
  node.style.visibility = progress >= until ? "hidden" : "";
  return progress >= until ? (progress - until) / (1 - until) : -1;
}

// Keeps only the part of the goal to the right of a ragged front.
function frontClip(node: HTMLElement, height: number, rows: number, front: (row: number) => number, on: boolean) {
  if (!on) return void (node.style.clipPath = "");
  const points: string[] = [];
  for (let row = 0; row <= rows; row += 1) {
    const x = Math.max(0, front(row));
    points.push(`${x}px ${row * PITCH}px`, `${x}px ${(row + 1) * PITCH}px`);
  }
  node.style.clipPath = `polygon(${points.join(",")}, 100% ${height}px, 100% 0)`;
}

const GREEN = "#7bd88f";

const STYLES: Record<"check" | "wind", Style> = {
  // Every pip swirls into a pixel checkmark, which holds for a beat and pops into sparks.
  check: {
    duration: 1500,
    // The checkmark keeps its size on a short goal and spills over its neighbours rather than shrinking.
    pad: [110, 60, 110],
    make(node, map) {
      const [cx, cy] = [map.width / 2, map.height / 2];
      const size = Math.min(Math.max(map.height * 0.8, 96), 130);
      const corners = [[-0.48, 0.02], [-0.12, 0.38], [0.5, -0.42]].map(([x, y]) => [cx + x * size, cy + y * size]);
      const seen = new Set<string>();
      const targets: Array<[number, number]> = [];
      for (let leg = 0; leg < 2; leg += 1) {
        const [a, b] = [corners[leg], corners[leg + 1]];
        const steps = Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / PITCH);
        for (let i = 0; i <= steps; i += 1) {
          for (const off of [0, 1]) {
            const tx = Math.round(mix(a[0], b[0], i / steps) / PITCH) * PITCH;
            const ty = (Math.round(mix(a[1], b[1], i / steps) / PITCH) + off) * PITCH;
            if (!seen.has(`${tx},${ty}`)) {
              seen.add(`${tx},${ty}`);
              targets.push([tx, ty]);
            }
          }
        }
      }
      const sources = map.cells
        .map((cell) => ({ cell, sx: cell.cx * PITCH, sy: cell.cy * PITCH, tx: 0, ty: 0, kx: 0, ky: 0, order: 0 }))
        .sort((a, b) => Math.atan2(a.sy - cy, a.sx - cx) - Math.atan2(b.sy - cy, b.sx - cx));
      sources.forEach((source, index) => {
        [source.tx, source.ty] = targets[Math.floor((index * targets.length) / sources.length)];
        const [mx, my] = [(source.sx + source.tx) / 2, (source.sy + source.ty) / 2];
        const [dx, dy] = [source.tx - source.sx, source.ty - source.sy];
        const distance = Math.hypot(dx, dy) || 1;
        source.kx = mx - (dy / distance) * (source.cell.seed - 0.5) * size * 1.4;
        source.ky = my + (dx / distance) * (source.cell.seed - 0.5) * size * 1.4;
        source.order = index / sources.length;
      });
      return (progress, ctx, ox, oy) => {
        const q = scanPrelude(node, progress, 0.1);
        if (q < 0) return;
        if (q > 0.62 && q < 0.86) for (const [tx, ty] of targets) pip(ctx, ox + tx - 2, oy + ty - 2, SIZE + 4, GREEN, 0.22 * Math.sin(((q - 0.62) / 0.24) * Math.PI));
        for (const source of sources) {
          const travel = clamp01((q - source.cell.seed * 0.18 - source.order * 0.08) / 0.48);
          const e = easeInOut(travel);
          let x = (1 - e) ** 2 * source.sx + 2 * (1 - e) * e * source.kx + e * e * source.tx;
          let y = (1 - e) ** 2 * source.sy + 2 * (1 - e) * e * source.ky + e * e * source.ty;
          let color = lerpColor(source.cell.color, GREEN, clamp01(travel * 1.4));
          let alpha = 1;
          let size2 = SIZE;
          if (q > 0.8) {
            const k = (q - 0.8) / 0.2;
            const [dx, dy] = [source.tx - cx, source.ty - cy];
            const distance = Math.hypot(dx, dy) || 1;
            const push = k * (16 + source.cell.seed * 46);
            x += (dx / distance) * push;
            y += (dy / distance) * push - k * 12;
            alpha = 1 - k;
            size2 = SIZE * (1 + 0.5 * Math.sin(k * Math.PI));
            color = k < 0.25 ? "#e3ffe8" : color;
          } else if (travel >= 1) color = "#a8f0b8";
          pip(ctx, ox + x, oy + y, size2, color, alpha);
        }
      };
    },
  },
  // The goal comes apart from the left and blows off to the right like dust.
  wind: {
    duration: 1300,
    pad: [60, 300, 24],
    make(node, map) {
      const rows = Math.ceil(map.height / PITCH);
      const band = 150;
      const span = map.width + band + 40;
      const jag = Array.from({ length: rows + 1 }, (_, i) => (hash(i * 17 + 3) - 0.5) * 22 - i * 2.5);
      return (progress, ctx, ox, oy) => {
        const front = (row: number) => -30 + progress * span + jag[Math.max(0, Math.min(rows, row))];
        frontClip(node, map.height, rows, front, progress > 0);
        if (progress <= 0) return;
        for (const cell of map.cells) {
          const [x0, y0] = [cell.cx * PITCH, cell.cy * PITCH];
          const a = (front(cell.cy) - x0) / band;
          if (a < 0 || a >= 1) continue;
          const e = a ** 1.5;
          pip(ctx, ox + x0 + e * (180 + cell.seed * 280), oy + y0 + Math.sin(cell.seed * 9 + a * 7) * 16 * e - e * (10 + cell.seed * 34), SIZE * (1 - 0.5 * e), lerpColor(cell.color, "#9092a0", clamp01(a * 1.6)), 1 - a);
        }
      };
    },
  },
};

// Runs an effect whose every frame depends only on progress. It waits at HOLD for the verdict, then
// finishes, or on a refusal plays back to the start. Resolves with the verdict.
function run(draw: (progress: number) => void, duration: number, verdict: Promise<boolean>) {
  let known: boolean | null = null;
  void verdict.then((ok) => (known = ok));
  return new Promise<boolean>((resolve) => {
    let start = performance.now();
    let last = start;
    let back: { at: number; from: number } | null = null;
    const frame = (now: number) => {
      let progress: number;
      if (back) {
        const t = Math.max(0, (now - back.at) / 380);
        progress = back.from * (1 - Math.min(1, t) ** 0.8);
        if (t >= 1) {
          draw(0);
          return resolve(false);
        }
      } else {
        progress = Math.min(1, (now - start) / duration);
        if (progress >= HOLD && known !== true) {
          // Waiting for the factory moves the start along, so the effect resumes where it paused.
          start += now - last;
          progress = HOLD;
          if (known === false) back = { at: now + 180, from: HOLD };
        }
      }
      last = now;
      draw(progress);
      if (!back && progress >= 1) return resolve(true);
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  });
}

// The canvas floats over the page and follows the goal, so it stays on it when something above moves.
async function play(node: HTMLElement, style: Style, verdict: Promise<boolean>) {
  const map = pipMap(node);
  const [padTop, padSide, padBottom] = style.pad;
  const ratio = window.devicePixelRatio || 1;
  const canvas = document.createElement("canvas");
  const [width, height] = [map.width + padSide * 2, map.height + padTop + padBottom];
  canvas.width = Math.ceil(width * ratio);
  canvas.height = Math.ceil(height * ratio);
  Object.assign(canvas.style, { position: "fixed", zIndex: "40", pointerEvents: "none", width: `${width}px`, height: `${height}px`, left: "0", top: "0" });
  document.body.append(canvas);
  const ctx = canvas.getContext("2d")!;
  ctx.scale(ratio, ratio);
  const draw = style.make(node, map);
  let box = node.getBoundingClientRect();
  const ok = await run((progress) => {
    // A row removed mid-exit keeps its last place, so the effect does not jump to the corner.
    if (node.isConnected) box = node.getBoundingClientRect();
    canvas.style.transform = `translate(${box.left - padSide}px, ${box.top - padTop}px)`;
    ctx.clearRect(0, 0, width, height);
    draw(progress, ctx, padSide, padTop);
    ctx.globalAlpha = 1;
  }, style.duration, verdict);
  canvas.remove();
  node.classList.remove("exit-scan");
  node.style.removeProperty("--scan");
  node.style.clipPath = "";
  // A finished exit stays gone until the goal leaves the list; a refusal brings it back.
  node.style.visibility = ok ? "hidden" : "";
  return ok;
}

async function fade(node: HTMLElement, verdict: Promise<boolean>) {
  await node.animate([{ opacity: 1 }, { opacity: 0.4 }], { duration: 150, fill: "forwards" }).finished;
  const ok = await verdict;
  node.getAnimations().forEach((animation) => animation.cancel());
  if (ok) node.style.visibility = "hidden";
  else node.animate([{ opacity: 0.4 }, { opacity: 1 }], { duration: 150 });
  return ok;
}

// Why the last exit of each goal did not go through, until the next attempt.
const refusals = new Map<string, string>();
const listeners = new Set<() => void>();
function refuse(goalId: string, text: string | null) {
  if (text === null) refusals.delete(goalId);
  else refusals.set(goalId, text);
  listeners.forEach((listener) => listener());
}

export function useRefusal(goalId: string) {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => refusals.get(goalId) ?? null,
  );
}

export type Leave = "complete" | "delete" | "archive" | "restore";

// Asks the factory while the row plays its exit, if it has one. A row that `closes` closes its gap once the factory
// agrees; its list drops it only after that. Resolves with why the factory refused, or null once it agreed.
async function exitWhile(key: string, node: HTMLElement | null, style: Style | null, send: () => Promise<void>, closes = style !== null): Promise<string | null> {
  let reason: string | null = null;
  const verdict = send().then(
    () => true,
    (caught: unknown) => {
      reason = caught instanceof Error ? caught.message : "The backend refused this.";
      return false;
    },
  );
  // A finished exit closes its gap at once instead of waiting for the next read to drop the row.
  const exit = (node && style ? (calm() ? fade(node, verdict) : play(node, style, verdict)) : verdict).then(async (ok) => {
    // With reduced motion the gap closes without a close-up.
    if (ok && node && closes) await (calm() ? void (node.style.display = "none") : collapseOut(node));
    return ok;
  });
  holdLeave(key, exit);
  // A row that stays listed after its exit, because the next read still shows it, opens and comes back into view.
  if ((await exit) && node && closes)
    setTimeout(() => {
      if (!node.isConnected) return;
      node.getAnimations().forEach((animation) => animation.cancel());
      node.style.display = "";
      node.style.visibility = "";
    }, 8000);
  return reason;
}

// Completes, deletes, archives or restores a goal. Complete plays the checkmark, Delete blows the goal away.
export async function leaveGoal(goalId: string, step: Leave, node: HTMLElement | null, send: () => Promise<void>) {
  refuse(goalId, null);
  const reason = await exitWhile(goalId, node, step === "complete" ? STYLES.check : step === "delete" ? STYLES.wind : null, send);
  if (reason !== null) refuse(goalId, `Couldn't ${step} it. ${reason}`);
  return reason === null;
}

// Finishes a package. Its row has no exit to play; it closes up as soon as the factory agrees.
export function finishPkg(pkgId: string, node: HTMLElement | null, send: () => Promise<void>): Promise<string | null> {
  return exitWhile(pkgId, node, null, send, true);
}

// Sends an answer while the question plays the checkmark. Resolves with why it was refused, or null.
export function answerAsk(askId: string, node: HTMLElement | null, send: () => Promise<void>): Promise<string | null> {
  return exitWhile(askId, node, STYLES.check, send);
}
