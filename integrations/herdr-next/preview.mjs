#!/usr/bin/env node
// Builds this checkout's sympp view as a preview copy for a UI studio: mods/sympp drawn on the sample
// board in fixture.mjs, with no sympp reads or writes, as its own mod; its actions change the sample
// in memory only. The studio runs it from the worker's worktree and again on every save, so the
// copy follows the work in progress.
//   node integrations/herdr-next/preview.mjs --to <herdr home>/mods/sympp-dev-<name> [--base <ref>] [--board busy|quiet] [--panel]
// With --base the first copy waits until the view differs from that ref (committed or not), exiting
// 3 until then; an existing copy is always rebuilt, so reverted edits show too. It writes only into a mods/sympp-dev-* folder and only files whose contents changed.
import { mkdir, readFile, readdir, writeFile, rm } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

export const PREFIX = 'sympp-dev-';
const here = dirname(fileURLToPath(import.meta.url));
const VIEW = 'integrations/herdr-next/mods';

// The copy's entry: the view with the sample board already read and its timer and new tabs
// stubbed. Its operator actions play on the sample board in memory (fixture.js applyDemo), so the
// preview can be clicked through; a reload starts over. It never focuses or types into a terminal.
// The drawn-structure tests use it too, with a case that pins width and place.
export function previewMain(spec = {}) {
  return `import Lens from "./lens.js";
import * as M from "./model.js";
import { NOW, boardPayload, variantPayload, deskFixture, applyDemo } from "./fixture.js";
const CASE = ${JSON.stringify(spec)};
const answer = (status, body) => ({ ok: status < 300, status, json: async () => body });
export default class Preview extends Lens {
  init(_p, cx) {
    super.init({ endpoint: "http://127.0.0.1:4000", ...CASE.props }, cx);
    this.sample = CASE.board ? variantPayload(CASE.board) : boardPayload();
    this.request = async (url, init = {}) => {
      const done = applyDemo(this.sample, url, JSON.parse(init.body ?? "{}"));
      return done ? answer(200, done) : answer(404, { error: { message: "The sample board has no such action." } });
    };
    const now = Date.now();
    this.net = M.fetchSucceeded(this.net, M.parseBoard(this.sample), now);
    if (CASE.error) this.net = M.fetchFailed(this.net, CASE.error, now);
    if (CASE.path) this.path = { topic: null, space: null, job: null, ...CASE.path };
    if (CASE.pin) this.pin = true;
    if (CASE.pkg) this.pkgSel = CASE.pkg;
    if (CASE.review) this.review = CASE.review;
    if (CASE.expanded) this.expanded = new Set(CASE.expanded);
    if (CASE.feedback) for (const key of CASE.feedback) this.feedback[key] = { input: this.input("What should change, and why?", true), open: true, pending: false, error: null };
    if (CASE.answer) for (const key of CASE.answer) this.answers[key] = { input: this.input("Optional note", true), open: true, choice: CASE.choice ?? null, pending: false, error: null };
  }
  // Ages and timings are drawn at the sample's moment. Herdr runs every mod in one runtime, so the
  // app's clock (Date.now) stays untouched.
  now() { return NOW; }
  tick() {}
  // A read only redraws the sample; it shares nothing with other mods.
  read(cx) {
    this.net = M.fetchSucceeded(this.net, M.parseBoard(this.sample), Date.now());
    cx.notify();
  }
  openInTab() {}
  openStudio() {}
  focusTerminal(address, cx) {
    this.ops["focus:" + address] = { error: "Sample data: this would open " + address + "." };
    cx.notify();
  }
  async prefill() {}
  // Every sample terminal counts as running, so Focus shows where it would.
  running() { return true; }
  viewportWidth() { return CASE.width ?? super.viewportWidth(); }
  deskTopics() { return deskFixture().topics; }
  spaceList() { return deskFixture().spaces; }
}
`;
}

// The copy's files: the view's modules (main.js as lens.js) with its own asset paths pointing at the
// copy, its pictures, its manifest titled for the pane header, the sample board and the entry above.
export async function previewFiles(name, root = resolve(here, '../..'), spec = {}) {
  const source = join(root, VIEW, 'sympp');
  const files = new Map();
  for (const file of await readdir(source)) {
    const body = await readFile(join(source, file));
    if (file.endsWith('.js')) files.set(file === 'main.js' ? 'lens.js' : file, Buffer.from(body.toString('utf8').replaceAll('mods/sympp/', `mods/${name}/`)));
    else if (file === 'mod.json') files.set(file, Buffer.from(`${JSON.stringify({ ...JSON.parse(body.toString('utf8')), title: 'sympp preview · sample data' })}\n`));
    else if (file.endsWith('.svg') || file.endsWith('.png')) files.set(file, body);
  }
  files.set('fixture.js', await readFile(join(root, 'integrations/herdr-next/fixture.mjs')));
  files.set('main.js', Buffer.from(previewMain(spec)));
  return files;
}

// Whether the Herdr view differs from `base`: committed since their merge base, edited or new.
export function viewChanged(root, base) {
  const git = (...args) => spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', windowsHide: true });
  const merge = git('merge-base', base, 'HEAD');
  if (merge.status !== 0) return true;
  const diff = git('diff', '--name-only', merge.stdout.trim(), '--', VIEW);
  const fresh = git('ls-files', '--others', '--exclude-standard', '--', VIEW);
  return diff.status !== 0 || fresh.status !== 0 || Boolean(diff.stdout.trim() || fresh.stdout.trim());
}

// Writes the copy into `to`, changing only what differs, and removes files the view no longer has.
// --board picks a fuller sample board, and --panel draws it as the narrow panel does.
export async function buildPreview(to, root = resolve(here, '../..'), spec = {}) {
  const name = basename(to);
  if (!name.startsWith(PREFIX)) throw new Error(`The preview folder must be named ${PREFIX}<name>.`);
  const files = await previewFiles(name, root, spec);
  await mkdir(to, { recursive: true });
  const before = await readdir(to);
  let written = 0;
  for (const [file, body] of files) {
    const current = before.includes(file) ? await readFile(join(to, file)) : null;
    if (current?.equals(body)) continue;
    await writeFile(join(to, file), body);
    written += 1;
  }
  for (const file of before) if (!files.has(file)) await rm(join(to, file), { force: true });
  return { files: files.size, written };
}

async function main() {
  const { values } = parseArgs({ options: { to: { type: 'string' }, base: { type: 'string' }, board: { type: 'string' }, panel: { type: 'boolean' } } });
  if (!values.to) throw new Error('--to <herdr home>/mods/sympp-dev-<name> is required');
  const root = resolve(here, '../..');
  const to = resolve(values.to);
  if (values.base && !existsSync(to) && !viewChanged(root, values.base)) {
    process.stdout.write(`${JSON.stringify({ state: 'unchanged' })}\n`);
    return 3;
  }
  const spec = { ...(values.board ? { board: values.board } : {}), ...(values.panel ? { props: { role: 'panel' } } : {}) };
  const built = await buildPreview(to, root, spec);
  process.stdout.write(`${JSON.stringify({ state: 'built', ...built })}\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = await main(); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
