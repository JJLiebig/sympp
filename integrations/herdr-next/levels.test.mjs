import test from 'node:test';
import assert from 'node:assert/strict';
import * as M from './mods/sympp/model.js';
import * as L from './mods/sympp/levels.js';
import { NOW, chiefTerminals } from './fixture.mjs';

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

test('a labelled chief and Start chief share one entry without bypassing verified liveness', () => {
  const term = { address: 'build/t9', state: 'live', program: { key: 'codex' }, labels: { 'sympp.role': 'chief', 'sympp.domain': 'Herdr' } };
  const [chief] = M.chiefsOf([term]);
  const topic = { name: chief.domain };
  const latest = { terminal: 'build/t9', agent: 'codex' };
  const unchecked = L.chiefAgent(chief, [], [term], {}, NOW);
  const entries = (list, last, c = chief, agent = unchecked) => L.chiefEntries(topic, [{ chief: c, agent }], last, list, NOW);
  const expected = [{ domain: chief.domain, terminal: 'build/t9' }];
  assert.deepEqual(entries([term]), [{ domain: chief.domain, terminal: null }], 'labels and a live terminal alone never prove a running chief');
  assert.deepEqual(entries([term], latest), expected, 'dedupe by terminal even without a helper result');
  assert.deepEqual(entries([term], latest, chief, { state: 'live', binding: { address: term.address } }), expected);
  assert.equal(entries([term], latest, { ...chief, terminal: 'other/t9' }).length, 2, 'another terminal is another chief');
  assert.deepEqual(entries([{ ...term, program: { key: 'shell' } }], latest),
    [{ domain: chief.domain, terminal: null }], 'a shell left behind is not a running chief');
});
