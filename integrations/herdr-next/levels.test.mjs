import test from 'node:test';
import assert from 'node:assert/strict';
import * as M from './mods/sympp/model.js';
import * as L from './mods/sympp/levels.js';
import { canResume, chiefSession, resumeArgv } from './mods/sympp/chief.js';
import { NOW, chiefTerminals, deskFixture } from './fixture.mjs';

test('a chief is Live only after a helper check of the chief session in its own terminal, else unknown', () => {
  const [herdr, live] = M.chiefsOf(chiefTerminals());
  const labels = {
    'sympp.session_id': 'chief-herdr', 'sympp.session_core_id': 'core-1', 'sympp.session_pid': '70', 'sympp.session_process_id': '71',
    'sympp.session_receipt': String.raw`C:\private\chief.json`, 'sympp.session_role': 'chief',
  };
  const terminal = { address: 't7', pid: 70, state: 'live', status: 'working', status_ms: NOW - 60e3, report: { msg: 'Slicing the board' }, labels };
  const other = { ...terminal, address: 't8' };
  const bindings = M.discoverBindings({ local: { node: 'node', helper: 'h' } }, [terminal, other]);
  assert.deepEqual(M.chiefBindings(bindings, herdr).map((b) => b.address), ['t7'], 'a chief session in another terminal is not this chief');
  const seen = L.chiefAgent(herdr, bindings, [terminal], {}, NOW);
  assert.equal(seen.state, 'unknown', 'its labels alone never make it live');
  assert.deepEqual([seen.role, seen.provider, seen.report.status, seen.report.msg], ['chief', null, 'working', 'Slicing the board']);
  const checks = { t7: { ok: true, at: NOW - 1000, launchId: 'chief-herdr', pid: 70 } };
  const checked = L.chiefAgent(herdr, bindings, [terminal], checks, NOW);
  assert.equal(checked.state, 'live');
  assert.equal(checked.binding.address, 't7', 'Open goes through the checked binding');
  assert.equal(L.chiefAgent(herdr, bindings, [terminal], { t7: { ...checks.t7, at: NOW - 10 * 60e3 } }, NOW).state, 'unknown', 'an old check has expired');
  assert.equal(L.chiefAgent(live, bindings, [terminal], checks, NOW).state, 'unknown', 'no chief session in its terminal is unknown');
});

test('a newly started chief has a 30-second grace while its terminal is live', () => {
  const term = { address: 'build/t9', state: 'live', program: { key: 'shell', agent: false }, labels: { 'sympp.role': 'chief', 'sympp.domain': 'Herdr' } };
  const [chief] = M.chiefsOf([term]);
  const topic = { name: chief.domain };
  const last = { terminal: term.address, agent: 'codex', started: NOW };
  assert.deepEqual(L.chiefEntries(topic, [chief], last, [term], NOW + 29_999), [{ domain: chief.domain, terminal: term.address }]);
  assert.deepEqual(L.chiefEntries(topic, [chief], last, [term], NOW + 30_000), [{ domain: chief.domain, terminal: null }]);
  assert.deepEqual(L.chiefEntries(topic, [], last, [{ ...term, state: 'finished' }], NOW), []);
});

for (const [name, domain, recorded, running] of [
  ['an agent switches in the recorded terminal', 'Nextide-Kraken', 'build/t1', 'build/t1'],
  ['a different labelled terminal is running the chief', 'Tools', 'build/t2', 'build/t3'],
]) {
  test(`the topic mark and resume command follow the chief when ${name}`, () => {
    const topic = { id: 'topic', name: domain, kind: 'topic' };
    const labels = { 'sympp.role': 'chief', 'sympp.domain': domain };
    const oldSession = '11111111-1111-4111-8111-111111111111';
    const currentSession = '22222222-2222-4222-8222-222222222222';
    const last = { terminal: recorded, agent: 'codex', session: oldSession };
    const live = { address: running, state: 'live', labels, program: { key: 'claude', agent: true },
      argv: ['codex', 'resume', oldSession], foreground: { pid: 20, argv: ['claude', '--model', 'opus', '--resume', currentSession], cwd: '/src' } };
    const list = [{ ...live, address: 'build/t4', labels: { ...labels, 'sympp.domain': 'Other' } }, live];
    if (recorded !== running) list.push({ address: recorded, state: 'finished', labels });
    const chiefs = L.chiefsFor(topic, M.chiefsOf(list), [topic]);
    const entries = L.chiefEntries(topic, chiefs, last, list, NOW);
    assert.deepEqual(entries, [{ domain, terminal: running }]);

    const saved = chiefSession(list.find((t) => t.address === entries[0].terminal), last);
    assert.deepEqual([saved.terminal, saved.agent, saved.session, saved.cwd], [running, 'claude', currentSession, '/src']);
    assert.equal(canResume(saved), true);
    assert.deepEqual(resumeArgv({ run: ['claude'] }, saved, domain).slice(0, 3), ['claude', '--resume', currentSession]);
  });
}

// Tasks as the board sends them: each with its repository, its owner (worked_on) and the chief it was
// created under (dispatched_by), when either is recorded.
const boardJobs = (requests) => M.parseBoard({ generated_at: new Date(NOW).toISOString(),
  work_request_details: requests.map((r) => ({ work_request: { phase: 'active', title: r.id, ...r }, work_packages: [] })) }).jobs;

test("a task's area is the operator's when set, else its repository's GitHub owner, else Unfiled", () => {
  const areas = Object.fromEntries(boardJobs([
    { id: 'wr-org', repo: 'nextidemedia/live-chat' },
    // A display name can be bare; the remote still names the owner.
    { id: 'wr-bare', repo_display: 'sympp', repo_remote: 'JJLiebig/sympp' },
    { id: 'wr-ruled', repo: 'nextidemedia/live-chat', area_path: ['Nextide', 'Live'] },
    { id: 'wr-local', repo: 'notes' },
  ]).map((job) => [job.id, job.area]));
  assert.deepEqual(areas, { 'wr-org': ['nextidemedia', 'live-chat'], 'wr-bare': ['JJLiebig', 'sympp'], 'wr-ruled': ['Nextide', 'Live'], 'wr-local': ['Unfiled', 'notes'] });
});

test("a task sits under its owning chief's topic, even with no space for its repository here; else its repository's", () => {
  const { topics, spaces } = deskFixture();
  const desk = L.deskOf({ ...topics, groups: [...topics.groups, { id: 't-misc', name: 'Nextide-Misc', spaces: [] }] }, spaces);
  const jobs = boardJobs([
    // An architect the chief started owns it; only Herdr's labels on its terminal name the chief.
    { id: 'wr-campaign', repo: 'nextidemedia/daedalus', worked_on: { address: 'core-1/t290', role: 'architect', liveness: 'live' } },
    { id: 'wr-startup', repo: 'herdrdev/herdr-core', dispatched_by: { kind: 'chief', domain: 'Herdr' } },
    { id: 'wr-chief', repo: 'nextidemedia/live-api', worked_on: { address: 'core-1/t81', role: 'chief', domain: 'Nextide-Misc', liveness: 'live' } },
    { id: 'wr-web', repo: 'owner/web' },
    { id: 'wr-lost', repo: 'nextidemedia/live-triggers', worked_on: { address: 'core-1/t300', role: 'architect', liveness: 'live' } },
  ]);
  const terminals = [
    { address: 'jjdev/t290', state: 'live', labels: { 'sympp.role': 'architect', 'sympp.domain': 'Nextide-Misc', 'sympp.session_work_request_id': 'wr-campaign' } },
    // The same terminal id bound to another task names no chief for this one.
    { address: 'jjdev/t300', state: 'live', labels: { 'sympp.domain': 'Nextide-Misc', 'sympp.session_work_request_id': 'wr-other' } },
  ];
  const place = L.placeJobs(jobs, desk, null, { terminals, chiefs: { 't-misc': [{ domain: 'Nextide-Misc', terminal: 'jjdev/t81' }] } });
  const home = (id) => place.home(jobs.find((j) => j.id === id));
  assert.deepEqual(['wr-campaign', 'wr-startup', 'wr-chief', 'wr-web', 'wr-lost'].map(home), ['t-misc', 't-herdr', 't-misc', 't-herdr', L.NOWHERE]);
  const rows = L.factoryRows(jobs, desk, place);
  assert.deepEqual(rows.find((r) => r.id === 't-misc').repos, ['daedalus', 'live-api'], 'its repositories stay the topic subtitle');
  assert.deepEqual(rows.find((r) => r.id === L.NOWHERE).jobs.map((j) => j.id), ['wr-lost']);
  const mapped = L.placeJobs(jobs, desk, { 'nextidemedia/live-triggers': 'Personal Tools' }, { terminals });
  assert.equal(mapped.home(jobs.at(-1)), 't-tools', 'then the configured repository topics');
});

test("a tab's task binding holds only while the tab shows that task: never a chief's tab, an archived or missing task, or a tab without sympp", () => {
  const { topics, spaces } = deskFixture();
  const desk = L.deskOf(topics, spaces);
  const jobs = boardJobs([{ id: 'wr-open', repo: 'owner/web' }, { id: 'wr-old', repo: 'owner/web', phase: 'archived' }]);
  const chiefs = L.chiefTopics({ 't-herdr': [{ domain: 'Herdr', terminal: 'core/t81' }] },
    { 't-tools': { terminal: 'core/t9', agent: 'codex' } }, [{ domain: 'Personal Tools', terminal: 'core/t9' }], desk,
    [{ address: 'core/t9', state: 'live', program: { key: 'shell' } }], NOW);
  assert.equal(chiefs.has('core/t9'), false, 'a chief whose agent stopped, its labelled terminal left open, is no chief');
  const panes = [
    { pane: 'p1', tab: 'tab-job', mod: 'sympp', terminal: null },
    { pane: 'p2', tab: 'tab-old', mod: 'sympp', terminal: null },
    { pane: 'p3', tab: 'tab-gone', mod: 'sympp', terminal: null },
    { pane: 'p4', tab: 'tab-scope', mod: 'sympp', terminal: null },
    // A task tab that came to hold the chief beside it, and one left with only a terminal.
    { pane: 'p5', tab: 'tab-chief', mod: 'sympp', terminal: null }, { pane: 'p6', tab: 'tab-chief', terminal: 'core/t81' },
    { pane: 'p7', tab: 'tab-bare', terminal: 'core/t9' },
    { pane: 'p8', tab: 'tab-other', mod: 'sympp', terminal: null },
  ];
  const here = 'http://127.0.0.1:4000', bound = (shows, endpoint = here) => ({ shows, endpoint });
  const stored = { 'tab-job': bound('wr-open'), 'tab-old': bound('wr-old'), 'tab-gone': bound('wr-deleted'), 'tab-scope': bound('scope:t-herdr:'),
    'tab-chief': bound('wr-open'), 'tab-bare': bound('wr-open'), 'tab-other': bound('wr-elsewhere', 'http://other:4000') };
  assert.deepEqual(Object.keys(L.liveTabs(stored, jobs, panes, chiefs, here)), ['tab-job', 'tab-scope', 'tab-other'],
    "another factory's task tab is not this board's to drop");
  const focus = (tab, terminal = null) => L.followPath(L.focusTarget({ space: 's-web', tab, pane: 'p', terminal }, [], stored, panes, chiefs), jobs, desk, L.placeJobs(jobs, desk, null));
  assert.deepEqual(focus('tab-chief'), { topic: 't-herdr', space: null, job: null }, "the chief's tab is its topic, whatever it was bound to");
  assert.deepEqual(focus('tab-x', 'core/t81'), { topic: 't-herdr', space: null, job: null }, 'so is the chief itself, wherever it shows');
  assert.equal(focus('tab-job').job, 'wr-open');
});
