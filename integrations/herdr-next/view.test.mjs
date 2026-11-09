// Structural checks of the drawn view: Herdr's own `check --print-spec` builds the real view with
// fixture data at a chosen width. This proves element structure and copy, not paint or input.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { previewFiles, previewMain } from './preview.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const app = process.env.HERDR_APP || 'herdr-app';
const available = !spawnSync(app, ['--version'], { encoding: 'utf8', windowsHide: true }).error;

async function render(t, spec, main = null) {
  const dir = await mkdtemp(join(tmpdir(), 'sympp spec '));
  t.after(() => rm(dir, { recursive: true, force: true }));
  for (const [name, body] of await previewFiles('sympp-dev-spec', join(here, '..', '..'), spec)) await writeFile(join(dir, name), body);
  if (main) await writeFile(join(dir, 'main.js'), main);
  const result = spawnSync(app, ['check', dir, '--print-spec'], { encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const out = result.stdout;
  return { out, has: (id) => out.includes(`:id[Str("${id}")]`) || out.includes(`Button "${id}"`), text: (value) => out.includes(`text "${value}"`) };
}

const skip = { skip: !available && 'herdr-app is not installed' };

// Herdr's runtime parses some code a standard engine refuses, so every view module must also parse
// as a strict ES module here, with or without herdr-app.
test('every view module parses as a standard ES module', async () => {
  const { readdir } = await import('node:fs/promises');
  for (const mod of ['sympp', 'sympp-lab']) {
    for (const name of (await readdir(join(here, 'mods', mod))).filter((n) => n.endsWith('.js'))) {
      const result = spawnSync(process.execPath, ['--check', join(here, 'mods', mod, name)], { encoding: 'utf8', windowsHide: true });
      assert.equal(result.status, 0, `${mod}/${name}: ${result.stderr}`);
    }
  }
});

test('the factory lists every ask with its answer in place, the decisions to review, and one row per Herdr topic', skip, async (t) => {
  const view = await render(t, { props: {}, width: 1400 });
  for (const id of ['lens-overview', 'breadcrumb', 'crumb-factory', 'factory-main', 'factory-aside', 'needs-queue', 'topic-rows',
    'topic-t-herdr', 'topic-t-tools', 'topic-t-live', 'topic-unsorted', 'ask-ask:esc-1', 'answer-ask:esc-1', 'owner-ask-ask:q1'])
    assert.ok(view.has(id), id);
  assert.equal(view.has('owner-ask-ask:esc-1'), false, 'an ask with no asking terminal names none');
  assert.ok(view.text('Shared tokens · Personal Tools · unblocks 2') && view.text('web · shares 1 job with Personal Tools') && view.text('Quiet'));
  assert.ok(view.text("You're needed in 2"));
  assert.equal(view.has('decision-queue'), false, 'no decisions, no list');
  assert.equal(view.has('topic-nowhere'), false, 'no row for an empty catch-all');
  const busy = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy' });
  assert.ok(busy.has('factory') && busy.has('pin') && !busy.has('factory-aside'), 'the panel stacks and can be pinned');
  for (const id of ['ask-ask:ask-flicker', 'decision-queue', 'decision-dec-toast', 'ack-dec-toast', 'feedback-dec-toast', 'decision-dec-share', 'dismiss-feedback-dec-share'])
    assert.ok(busy.has(id), id);
  assert.ok(busy.text("You're needed in 3") && busy.text('2 need you') && busy.text('Undelivered'), "a card's ask counts too, in its topic as well");
  assert.equal(busy.has('ack-dec-share'), false, 'undelivered feedback has only its dismiss');
  const at = (id) => busy.out.indexOf(`:id[Str("${id}")]`);
  assert.ok(at('decision-dec-share') < at('decision-dec-order') && at('decision-dec-order') < at('decision-dec-toast'), 'oldest decision first');
});

test("a factory topic opens in place to its tasks, each a compact line, while the row itself still opens the topic", skip, async (t) => {
  const closed = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy' });
  assert.ok(closed.has('topic-toggle-t-herdr') && closed.has('topic-toggle-t-tools') && !closed.has('topic-toggle-t-live'), 'a topic without tasks has no chevron');
  assert.equal(closed.out.includes(':id[Str("ftask-'), false, 'closed until opened');
  const open = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', openTopics: ['t-herdr'] });
  for (const id of ['ftask-wr-pr', 'fneeds-wr-pr', 'fstrip-wr-restore', 'ftask-wr-restore', 'phase-f-wr-recap', 'phase-f-wr-docs'])
    assert.ok(open.has(id), id);
  assert.equal(open.has('ftask-wr-cross') || open.has('ftask-wr-badges') || open.has('ftask-wr-old'), false, "other topics' work and settled work stay out");
  assert.equal(open.has('phase-f-wr-restore'), false, 'an active task names no phase');
  const at = (id) => open.out.indexOf(`:id[Str("${id}")]`);
  assert.ok(at('topic-t-herdr') < at('ftask-wr-pr') && at('ftask-wr-pr') < at('ftask-wr-restore') && at('ftask-wr-restore') < at('topic-t-tools'), 'asking tasks first, under their topic');
});

test('a topic puts each ask first; tasks carry their name, phase and strip, with their decisions, then the small work', skip, async (t) => {
  const view = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr' } });
  const at = (id) => view.out.indexOf(`:id[Str("${id}")]`);
  assert.ok(at('group-wr-pr') < at('group-wr-docs') && at('group-wr-cross') < at('group-wr-restore'), 'what asks the person comes first');
  assert.ok(view.has('answer-ask:q1') && view.has('answer-ask:esc-1'), 'every ask is answered here');
  assert.ok(view.has('decision-dec-toast') && at('group-wr-restore') < at('decision-dec-toast'), "a decision sits under its task");
  assert.ok(view.has('phase-wr-recap') && view.has('phase-wr-docs') && !view.has('phase-wr-restore'), 'only a task that is not simply active names its phase');
  assert.ok(view.has('strip-wr-restore-2') && !view.has('strip-wr-restore-3'), 'the strip runs once per phase');
  for (const id of ['card-card-tokens', 'card-card-flicker', 'card-card-typos', 'ask-ask:ask-flicker', 'dismiss-card-card-flicker', 'owner-card-card-flicker'])
    assert.ok(view.has(id), id);
  assert.equal(view.has('card-card-ocr'), false, "another topic's small work stays there");
  assert.ok(view.has('later-t-herdr:') && view.has('later-archived:t-herdr:') && !view.has('task-wr-badges') && !view.has('task-wr-old'), 'planned, landed and archived work stay folded');
  assert.ok(view.has('filter-all') && view.has('filter-s-web'), "the topic's spaces are one click away");
  const quiet = await render(t, { props: { role: 'panel' }, width: 1400, board: 'quiet', path: { topic: 't-herdr' } });
  assert.equal(quiet.out.includes(':id[Str("ask-') || quiet.out.includes(':id[Str("decision-'), false, 'nothing is said while all is well');
  assert.doesNotMatch(quiet.out, /text "\d+\/\d+/, 'no counts');
});

test('a space shows only the tasks on its repository, drawn as its topic draws them', skip, async (t) => {
  const space = await render(t, { props: {}, width: 700, board: 'busy', path: { topic: 't-tools', space: 'vps/s-api' } });
  assert.ok(space.text('api') && space.has('task-wr-cross') && space.has('task-wr-restore') && space.has('card-card-ocr'));
  assert.ok(space.has('filter-all') && space.has('filter-vps/s-api'), 'back to the whole topic, or on to another space');
  assert.equal(space.has('task-wr-pr') || space.has('task-wr-theme') || space.has('card-card-flicker'), false);
  const empty = await render(t, { props: {}, width: 1400, path: { topic: 'unsorted', space: 's-home' } });
  assert.ok(empty.text('Nothing running here'));
});

test('a task shows its phase and owner, its packages at work under their groups with their progress, and folds ended and planned work', skip, async (t) => {
  for (const width of [1400, 700]) {
    const view = await render(t, { props: {}, width, board: 'busy', path: { topic: 't-herdr', job: 'wr-restore' }, pkg: 'r-4' });
    for (const id of ['task-head', 'phase-wr-restore', 'owner-job-wr-restore', 'complete-wr-restore', 'delete-wr-restore', 'strip-wr-restore',
      'group-wr-restore-0-Recovery', 'group-wr-restore-1-Shell', 'group-wr-restore-0-Polish', 'pkg-r-4', 'pkg-r-5', 'pkg-r-6', 'pkg-r-7',
      'owner-pkg-r-4', 'fold-Landed:wr-restore', 'fold-Up next:wr-restore', 'pr-step-r-4', 'review-r-4'])
      assert.ok(view.has(id), `${id} at ${width}`);
    assert.equal(view.has('pkg-r-1') || view.has('pkg-r-9'), false, 'ended and planned packages are folded');
    assert.ok(view.text('Build') && view.text('Review') && view.text('Merge') && view.text('deep r3 · 50m') && view.text('r2 · findings'));
    assert.equal(view.text('Checks'), width === 1400, 'narrow, a package shows only its current stage');
    assert.equal(view.has('finish-r-4') || view.has('restore-wr-restore') || view.has('archive-wr-restore'), false, 'no Finish for a PR into its own repository; no Archive or Restore while open');
    const at = (id) => view.out.indexOf(`:id[Str("${id}")]`);
    assert.ok(at('group-wr-restore-0-Recovery') < at('pkg-r-4') && at('pkg-r-4') < at('group-wr-restore-1-Shell') && at('group-wr-restore-1-Shell') < at('pkg-r-5')
      && at('pkg-r-6') < at('group-wr-restore-0-Polish') && at('group-wr-restore-0-Polish') < at('pkg-r-7'), 'groups nest in planned order');
  }
  const open = await render(t, { props: {}, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-restore' }, expanded: ['Landed:wr-restore'] });
  assert.ok(open.has('pkg-r-1') && open.text('Merged') && !open.has('pkg-r-9'), 'a fold opens on request and says how each package ended');
});

test('Finish and Release appear only where they apply; an unresolved task names what did not land; an archived one can be restored', skip, async (t) => {
  const upstream = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-upstream' } });
  assert.ok(upstream.has('finish-u-2') && upstream.text('core#97'), 'an open PR into another repository');
  assert.ok(upstream.has('release-job-wr-upstream') && !upstream.has('release-pkg-u-2'), 'Release only for an owner that stopped answering');
  const recap = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-recap' } });
  assert.ok(recap.has('unresolved') && recap.text('XLSX export') && recap.text('abandoned') && recap.text('skipped'));
  assert.ok(recap.has('complete-wr-recap') && recap.has('archive-wr-recap') && recap.has('dismiss-feedback-dec-share'));
  const old = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-old' } });
  assert.ok(old.has('restore-wr-old') && old.has('delete-wr-old') && !old.has('archive-wr-old') && !old.has('complete-wr-old'));
});

test('an ask opens its answer form with the decision prompt, and a decision opens its feedback form', skip, async (t) => {
  const view = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-pr' },
    answer: ['ask:q1'], choice: 'board_first', feedback: ['decision:dec-order'] });
  for (const id of ['choice-ask:q1-board_first', 'choice-ask:q1-lens_first', 'choice-ask:q1-__custom_redirect__', 'save-ask:q1', 'send-feedback-dec-order', 'focus-feedback-dec-order', 'cancel-feedback-dec-order'])
    assert.ok(view.has(id), id);
  assert.equal(view.out.split('text "Which order should the levels land in?"').length - 1, 1, 'the question shows once');
  assert.equal(view.has('ack-dec-order'), false, 'Ack waits while the feedback form is open');
});

test('an ask tops its task, and the review opens under its package', skip, async (t) => {
  const view = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr', job: 'wr-pr' }, pkg: 'wp-review', review: { jobId: 'wr-pr', pkgId: 'wp-review', round: null } });
  const at = (id) => view.out.indexOf(`:id[Str("${id}")]`);
  assert.ok(at('ask-ask:q1') < at('pkg-wp-build') && at('pkg-wp-build') < at('pkg-wp-review'));
  assert.ok(view.has('answer-ask:q1') && view.has('review-wp-review') && view.has('review-rounds'), 'the review opens under its package');
});
test('the panel opens what it shows as a big tab, which draws the same scope wide', skip, async (t) => {
  const panel = await render(t, { props: { role: 'panel' }, width: 1400, board: 'busy', path: { topic: 't-herdr' } });
  assert.ok(panel.has('open-big') && panel.has('ci-wr-restore') && panel.has('ci-wr-cross'));
  const tab = await render(t, { props: { scope: { topic: 't-herdr', space: null } }, width: 1400, board: 'busy' });
  assert.ok(tab.has('task-wr-restore') && tab.has('task-wr-status') && !tab.has('open-big'));
});

test("a task's own tab has no way back, and missing or unreadable tasks say so", skip, async (t) => {
  const tab = await render(t, { props: { job: 'wr-pr' }, width: 1400 });
  assert.ok(tab.has('lens-bar') && tab.has('pkg-wp-review') && !tab.has('lens-back') && !tab.has('new-job'));
  const missing = await render(t, { props: { job: 'wr-gone' }, width: 1400 });
  assert.ok(missing.text("This job isn't here"));
  const shaping = await render(t, { props: { job: 'wr-shaping' }, width: 1400 });
  assert.ok(shaping.text('Not sliced into packages yet'));
  const stale = await render(t, { props: { job: 'wr-pr' }, width: 1400, error: "Can't reach sympp at 127.0.0.1:4000. Check the connection and retry." });
  assert.ok(stale.has('pkg-wp-review') && stale.has('read-status'), 'the last good read stays, with a status mark');
});

// Herdr runs every mod in one runtime, so a preview that replaced Date.now would stop every mod's clock.
test("the preview draws at the sample's moment without touching the app's clock", skip, async (t) => {
  const main = `${previewMain({ props: { job: 'wr-pr' }, width: 1400 }).replace('export default class Preview', 'class Preview')}
const REAL = Date.now;
export default class ClockCase extends Preview {
  init(p, cx) {
    super.init(p, cx);
    if (Date.now !== REAL) throw new Error("the preview replaced Date.now");
  }
}
`;
  const view = await render(t, {}, main);
  assert.ok(view.has('pkg-wp-review'));
  assert.equal(view.out.includes('Last read'), false, "the sample's read is fresh at the sample's moment");
});

test('a selected UI package offers its studio; other packages do not', skip, async (t) => {
  for (const width of [1400, 700]) {
    const ui = await render(t, { props: { job: 'wr-cross' }, width, pkg: 'x-web', expanded: ['Up next:wr-cross'] });
    assert.ok(ui.has('studio-x-web'), `Token UI at ${width}`);
    const other = await render(t, { props: { job: 'wr-pr' }, width, pkg: 'wp-build' });
    assert.equal(other.has('studio-wp-build'), false, `Stage board at ${width}`);
  }
});

// The studio's own pane in each state, drawn from studioview.js with fixed inputs.
const studioCase = (s) => `import { View } from "gpui-kit";
import { theme } from "herdr";
import { studioView } from "./studioview.js";
const CASE = ${JSON.stringify(s)};
const v = { workerChecking: false, moveWorker() {}, goToWorker() {}, openPreview() {}, retry() {}, showPreview() {} };
export default class StudioCase extends View {
  render() { return studioView(v, theme(), CASE); }
}
`;

test('a studio shows a published preview with Open, says when there is none, and shrinks over a native one', skip, async (t) => {
  const base = { pkg: { title: 'Token UI' }, worker: { state: 'live' }, place: { step: null }, kind: 'none', url: null, native: { state: 'idle', error: null, builtAt: null }, landed: false, strip: false };
  const draw = (s) => render(t, {}, studioCase({ ...base, ...s }));
  const web = await draw({ kind: 'web', url: 'http://127.0.0.1:5173/' });
  assert.ok(web.has('studio-head') && web.has('studio-card') && web.has('studio-open'));
  assert.ok(web.text('Token UI') && web.text('Worker · Live') && web.text('http://127.0.0.1:5173/') && web.text('Preview'));
  const none = await draw({});
  assert.ok(none.text("The agent hasn't published a preview yet"));
  assert.equal(none.has('studio-card') || none.has('studio-open'), false);
  const strip = await draw({ kind: 'native', native: { state: 'ready', error: null, builtAt: Date.now() }, strip: true });
  assert.ok(strip.has('studio-head') && strip.text('Sample data · updated just now'));
  assert.equal(strip.has('studio-card') || strip.out.includes('text "Building the preview'), false, 'over a native preview only the header is drawn');
  const failed = await draw({ kind: 'native', native: { state: 'error', error: 'SyntaxError: Unexpected token', builtAt: null } });
  assert.ok(failed.text("The preview didn't build") && failed.text('SyntaxError: Unexpected token'));
  const elsewhere = await draw({ place: { step: 'elsewhere', pane: 'p7', tab: 'tb5' } });
  assert.ok(elsewhere.has('studio-move') && elsewhere.has('studio-go') && elsewhere.text('Worker · in another tab'));
  const waiting = await draw({ worker: { state: 'gone' } });
  assert.ok(waiting.text('Waiting for the worker') && waiting.has('studio-retry') && waiting.text("The worker isn't running"));
  const landed = await draw({ landed: true });
  assert.ok(landed.text('Landed'));
  assert.equal(landed.has('studio-retry'), false);
});
