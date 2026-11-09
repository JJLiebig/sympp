import test from 'node:test';
import assert from 'node:assert/strict';
import * as J from './mods/sympp/job.js';
import { NOW } from './fixture.mjs';

test("an agent's report is its own OSC status, labelled as such, never terminal text", () => {
  const terminal = { address: 't8', status: 'blocked', status_ms: NOW - 4 * 60e3, report: { kind: 'permission', msg: ' Allow edit? ' }, title: 'I am done!' };
  const report = J.agentReport(terminal, NOW);
  assert.deepEqual(report, { status: 'blocked', kind: 'permission', msg: 'Allow edit?', age: '4m ago' });
  assert.equal(J.agentReport({ address: 't9', title: 'working hard' }, NOW), null, 'no OSC status means no report');
  const older = { address: 't7', status: 'idle', status_ms: NOW - 60 * 60e3 };
  assert.equal(J.reportFor([{ address: 't7' }, { address: 't8' }], [older, terminal], NOW).status, 'blocked', 'the freshest report wins');
});
