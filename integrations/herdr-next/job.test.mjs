import test from 'node:test';
import assert from 'node:assert/strict';
import * as M from './mods/sympp/model.js';
import * as J from './mods/sympp/job.js';
import { NOW, boardPayload } from './fixture.mjs';

const jobs = () => M.parseBoard(boardPayload()).jobs;
const jobOf = (id) => jobs().find((job) => job.id === id);

test("an agent's report is its own OSC status, labelled as such, never terminal text", () => {
  const terminal = { address: 't8', status: 'blocked', status_ms: NOW - 4 * 60e3, report: { kind: 'permission', msg: ' Allow edit? ' }, title: 'I am done!' };
  const report = J.agentReport(terminal, NOW);
  assert.deepEqual(report, { status: 'blocked', kind: 'permission', msg: 'Allow edit?', age: '4m ago' });
  assert.equal(J.agentReport({ address: 't9', title: 'working hard' }, NOW), null, 'no OSC status means no report');
  const older = { address: 't7', status: 'idle', status_ms: NOW - 60 * 60e3 };
  assert.equal(J.reportFor([{ address: 't7' }, { address: 't8' }], [older, terminal], NOW).status, 'blocked', 'the freshest report wins');
});

test("open in tab targets the job's local space and carries this copy's props", () => {
  const job = jobOf('wr-pr');
  const spaces = [
    { id: 'remote', machine: 'build', folder: '/src/web', active: false },
    { id: 'notes', machine: null, folder: 'C:\\code\\notes', active: true },
    { id: 'web', machine: null, folder: 'C:\\code\\owner\\web\\', active: false },
  ];
  const given = { endpoint: 'http://127.0.0.1:4000', role: 'panel', hosts: { local: { node: 'node', helper: 'h' } } };
  assert.deepEqual(J.jobTabArgs(given, job, spaces), {
    name: 'Native job tab', space: 'web', mod: 'sympp',
    props: { endpoint: 'http://127.0.0.1:4000', hosts: { local: { node: 'node', helper: 'h' } }, job: 'wr-pr' },
  });
  assert.equal(J.jobSpace(job, spaces.slice(0, 2)).id, 'notes', 'no local match: the shown space');
  assert.equal(J.jobSpace({ ...job, repos: ['C:/code/owner/web'] }, spaces).id, 'web');
  assert.equal(J.jobTabArgs({}, { ...job, title: 'x'.repeat(40) }, []).name.length, 32);
});

test('migrated endings read their recorded legacy status', () => {
  const board = boardPayload();
  const detail = board.work_request_details[0];
  const ended = (id, legacy_status) => ({
    id, work_package_id: id, title: id, sequence: 9, repo: 'owner/web', status: 'ended', inserted_at: detail.work_request.inserted_at,
    dispatched_at: detail.work_request.inserted_at,
    delivery: { outcome: 'legacy', legacy_status },
  });
  detail.work_packages.push(ended('wp-legacy-abandoned', 'abandoned'), ended('wp-legacy-merged', 'merged'));
  const job = M.parseBoard(board).jobs.find((entry) => entry.id === detail.work_request.id);
  const outcomeOf = (id) => job.packages.find((p) => p.id === id).outcome;
  assert.equal(outcomeOf('wp-legacy-abandoned'), 'dropped');
  assert.equal(outcomeOf('wp-legacy-merged'), 'merged');
});
