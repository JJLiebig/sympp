import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import * as M from './mods/sympp/model.js';
import * as C from './mods/sympp/controls.js';
// The sample board stands in for the factory: a send changes it the way the backend would; a read parses it.
import { applyDemo, variantPayload } from './fixture.mjs';

const prompt = {
  tl_dr: 'Choose the delivery order.', details: 'The API can ship independently.',
  options: [{ id: 'api_first', label: 'API first', answer: 'Ship the API first.', description: 'Unblock callers.', pros: ['Small scope'], cons: ['UI follows'] }],
  custom_redirect_label: 'A different order',
};
const detail = (id, repo, packages = []) => ({
  work_request: { id, title: id, repo, inserted_at: '2026-10-25T12:00:00Z' },
  work_packages: packages.map((pkg) => ({ id: pkg.id, title: pkg.id, repo: pkg.repo, ...pkg })),
});
const board = (details) => M.parseBoard({
  generated_at: '2026-10-25T13:00:00Z', work_request_details: details, extra: 'tolerated',
});

test('native origins reject embedded credentials and paths, while dashboard links may have a path', () => {
  assert.equal(M.normalizeEndpoint(' http://127.0.0.1:4000/ '), 'http://127.0.0.1:4000');
  assert.equal(M.normalizeEndpoint('http://[::1]:4000'), 'http://[::1]:4000');
  for (const invalid of ['http://user:private@localhost:4000', 'http://localhost:4000/sympp', 'http://localhost:4000?token=private', 'http://localhost:4000#private']) {
    assert.equal(M.normalizeEndpoint(invalid), null);
    assert.doesNotMatch(M.networkError(invalid, new Error(invalid)), /private|user/);
  }
  assert.equal(M.dashboardUrl('http://localhost:4000', 'http://localhost:4000/sympp?view=board'), 'http://localhost:4000/sympp?view=board');
  assert.equal(M.dashboardUrl('http://localhost:4000', 'http://user:private@localhost:4000/sympp'), 'http://localhost:4000/sympp');
});

const host = { node: 'C:\\Program Files\\nodejs\\node.exe', helper: 'C:\\Herdr Home\\tools\\sympp-herdr.js', session: 'scratch' };
const terminal = (remote = false) => ({ address: remote ? 'build/t8' : 't8', pid: 123, state: 'live', labels: {
  'sympp.launch_id': 'launch-1', 'sympp.core_id': 'core-1', 'sympp.receipt': remote ? '/home/me/launch.json' : 'C:\\receipt with spaces.json',
  'sympp.pid': '123', 'sympp.work_request_id': 'wr1', 'sympp.work_package_id': 'wp1', 'sympp.role': 'worker',
} });
const checked = (overrides = {}) => ({ code: 0, stdout: JSON.stringify({ state: 'live', core_id: 'core-1', terminal_id: 't8', pid: 123, launch_id: 'launch-1', work_request_id:'wr1', work_package_id:'wp1', ...overrides }) });

test('agent jumps require trusted host configuration, a live receipt and unchanged terminal identity', () => {
  for (const remote of [false, true]) {
    const term = terminal(remote);
    term.labels['sympp.helper'] = 'untrusted executable';
    const binding = M.discoverBindings({ [remote ? 'build' : 'local']: host }, [term])[0];
    assert.equal(binding.machine, remote ? 'build' : null);
    assert.deepEqual(M.bindingCheckArgs(binding), [host.helper, 'check', '--receipt', term.labels['sympp.receipt'], '--session', 'scratch', '--json']);
    assert.equal(M.checkedBinding(binding, checked(), [term]), true);
    for (const mismatch of [{ state: 'stale' }, { core_id: 'new-core' }, { terminal_id: 't9' }, { pid: 456 }, { launch_id: 'new-launch' },
      { work_request_id:'another-job' }, { work_package_id:'another-package' }]) {
      assert.equal(M.checkedBinding(binding, checked(mismatch), [term]), false);
    }
    assert.equal(M.checkedBinding(binding, checked(), [{ ...term, pid: 456 }]), false, 'recovered shells cannot be focused');
    assert.equal(M.checkedBinding(binding, checked(), [{ ...term, labels: { ...term.labels, 'sympp.launch_id': 'replacement' } }]), false);
    assert.equal(M.checkedBinding(binding, checked(), []), false);
    assert.equal(M.checkedBinding(binding, { code: 1, stdout: checked().stdout }, [term]), false);
    assert.equal(M.checkedBinding(binding, { code: 0, stdout: '{}' }, [term]), false);
    // Another machine without configured hosts uses the helper of the sympp skill installed there.
    const unconfigured = M.discoverBindings({}, [term])[0];
    assert.equal(unconfigured.available, remote);
    if (remote) assert.deepEqual([unconfigured.host.node, ...M.bindingCheckArgs(unconfigured)],
      ['node', '.agents/skills/sympp/scripts/sympp-herdr.js', 'check', '--receipt', '/home/me/launch.json', '--json']);
    assert.equal(M.discoverBindings({ [remote ? 'build' : 'local']: host }, [{ ...term, labels: { ...term.labels, 'sympp.receipt': 'relative.json' } }])[0].available, false);
  }
});

test('hand-started architects use an independent session binding and reject a replaced bridge', () => {
  const term = terminal();
  const labels = term.labels;
  Object.assign(labels, {
    'sympp.session_id': 'client-one', 'sympp.session_core_id': 'core-1',
    'sympp.session_pid': '123', 'sympp.session_process_id': '456',
    'sympp.session_receipt': 'C:\\private\\session.json', 'sympp.session_role': 'architect',
    'sympp.session_work_request_id': 'architect-job',
  });
  const bindings = M.discoverBindings({ local: host }, [term]);
  const architect = bindings.find(b => b.jobId === 'architect-job');
  assert.ok(architect?.available, 'a hand-started MCP session needs a native Open candidate');
  assert.equal(bindings.find(b => b.jobId === 'wr1').launchId, 'launch-1', 'the original worker receipt remains usable');
  assert.equal(architect.pkgId, null);
  assert.equal(architect.role, 'architect');
  const result = { code: 0, stdout: JSON.stringify({ kind:'session', state:'live', core_id:'core-1', terminal_id:'t8',
    pid:123, process_id:456, launch_id:'client-one', work_request_id:'architect-job', work_package_id:null, role:'architect' }) };
  assert.equal(M.checkedBinding(architect, result, [term]), true);
  assert.equal(M.checkedBinding(architect, result, [{ ...term, labels:{...labels, 'sympp.session_process_id':'789'} }]), false);
  assert.equal(M.checkedBinding(architect, result, [{ ...term, pid:789 }]), false);
  assert.equal(M.discoverBindings({}, [term]).find(b => b.kind === 'session').available, false);
});

test('package-only manual worker sessions match their canonical package without inventing a goal', () => {
  const term = terminal();
  Object.assign(term.labels, {
    'sympp.session_id':'worker-client', 'sympp.session_core_id':'core-1', 'sympp.session_pid':'123',
    'sympp.session_process_id':'456', 'sympp.session_receipt':'C:\\private\\worker.json',
    'sympp.session_work_package_id':'wp2', 'sympp.session_role':'worker',
  });
  const bindings = M.discoverBindings({ local:host }, [term]);
  const [worker] = M.bindingsFor(bindings, 'canonical-goal', 'wp2');
  assert.equal(worker.jobId, null);
  assert.equal(worker.pkgId, 'wp2');
  assert.equal(worker.role, 'worker');
  assert.equal(M.bindingsFor(bindings, 'canonical-goal', null).length, 0);
  assert.equal(M.bindingsFor(bindings, 'canonical-goal', 'other-package').length, 0);
  assert.equal(M.bindingsFor([{ ...worker, jobId:'another-goal' }], 'canonical-goal', 'wp2').length, 0);
  const result = { code:0, stdout:JSON.stringify({ kind:'session', state:'live', core_id:'core-1', terminal_id:'t8',
    pid:123, process_id:456, launch_id:'worker-client', work_request_id:null, work_package_id:'wp2', role:'worker' }) };
  assert.equal(M.checkedBinding(worker, result, [term]), true);
  assert.equal(M.checkedBinding(worker, result, [{ ...term, labels:{ ...term.labels, 'sympp.session_work_package_id':'other-package' } }]), false);
});

test('labelled chiefs match the chief session in their own terminal and keep verified focus checks', () => {
  const term = { address: 't8', pid: 123, state: 'live', labels: {
    'sympp.session_id': 'chief-client', 'sympp.session_core_id': 'core-1', 'sympp.session_pid': '123',
    'sympp.session_process_id': '456', 'sympp.session_receipt': 'C:\\private\\chief.json', 'sympp.session_role': 'chief',
  } };
  const chief = { terminal: 't8' };
  const bindings = M.discoverBindings({ local: host }, [term]);
  const [binding] = M.chiefBindings(bindings, chief);
  assert.ok(binding?.available);
  assert.equal(binding.jobId, null);
  assert.equal(binding.pkgId, null);
  assert.deepEqual(M.bindingsFor(bindings, 'unrelated-job'), []);
  assert.deepEqual(M.chiefBindings(bindings, { terminal: 't9' }), []);
  assert.deepEqual(M.chiefBindings(bindings, {}), []);
  const receipt = { kind: 'session', state: 'live', core_id: 'core-1', terminal_id: 't8',
    pid: 123, process_id: 456, launch_id: 'chief-client', role: 'chief', work_request_id: null, work_package_id: null };
  const result = { code: 0, stdout: JSON.stringify(receipt) };
  assert.equal(M.checkedBinding(binding, result, [term]), true);
  assert.equal(M.checkedBinding(binding, { ...result, code: 1 }, [term]), false);
  assert.equal(M.checkedBinding(binding, result, [{ ...term, labels: { ...term.labels, 'sympp.session_id': 'replacement' } }]), false);
  assert.equal(M.checkedBinding(binding, { code: 0, stdout: JSON.stringify({ ...receipt, role: 'architect' }) }, [term]), false);
  assert.equal(M.discoverBindings({}, [term])[0].available, false);
  for (const role of ['architect', 'coordinator', 'worker']) {
    assert.deepEqual(M.discoverBindings({ local: host }, [{ ...term, labels: { ...term.labels, 'sympp.session_role': role } }]), []);
  }
});

test('failed saves retain the draft and concurrent activations cannot submit it twice', async () => {
  const draft = { text: 'Keep my entered answer', pending: false, error: null };
  let release;
  const wait = new Promise((resolve) => { release = resolve; });
  let writes = 0;
  const submit = () => C.submitAction(draft, async () => { writes++; await wait; throw new Error('Ledger busy. Try again.'); }, () => { draft.text = ''; });
  const first = submit();
  await submit();
  assert.equal(writes, 1);
  assert.equal(draft.pending, true);
  release();
  await first;
  assert.equal(draft.text, 'Keep my entered answer');
  assert.equal(draft.pending, false);
  assert.equal(draft.error, 'Ledger busy. Try again.');
  await C.submitAction(draft, async () => 'saved', () => { draft.text = ''; });
  assert.equal(draft.text, '');
  assert.equal(draft.error, null);
  assert.throws(() => C.answerBody({ prompt }, '__custom_redirect__', '  '), /Describe/);
  assert.throws(() => C.answerBody({ prompt }, 'unknown', ''), /Choose/);
  assert.deepEqual(C.answerBody({ prompt }, '__custom_redirect__', ' UI first '), { answer_choice: '__custom_redirect__', answer_note: 'UI first' });
  assert.deepEqual(C.answerBody({}, null, ' plain answer '), { answer: 'plain answer' });
});

test('native actions send JSON-only requests and surface persisted success or actionable server errors', async (t) => {
  const received = [];
  const server = createServer(async (req, res) => {
    let raw = '';
    for await (const part of req) raw += part;
    received.push({ method: req.method, url: req.url, headers: req.headers, body: JSON.parse(raw) });
    res.setHeader('content-type', 'application/json');
    if (received.length === 1) { res.statusCode = 201; res.end(JSON.stringify({ work_request: { work_request: { id: 'new-job' } } })); }
    else if (received.length === 2) res.end(JSON.stringify({ ok: true, ask_id: 'ask 1', delivery: { state: 'delivered' } }));
    else if (received.length === 3) { res.statusCode = 409; res.end(JSON.stringify({ error: { code: 'ask_not_open', message: 'This ask is already answered' } })); }
    else { res.statusCode = 409; res.end(JSON.stringify({ error: { code: 'work_request_archived', message: 'WorkRequest is archived; restore it first', phase: 'archived', next_action: 'restore' } })); }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const endpoint = `http://127.0.0.1:${server.address().port}`;
  const payload = await C.postAction(endpoint, '/api/v1/sympp/herdr/work-requests', C.requestBody({ title: ' New job ', repo: 'owner/repo', base_branch: 'main', human_description: 'A bounded change' }));
  assert.equal(payload.work_request.work_request.id, 'new-job');
  const question = { route: '/api/v1/sympp/herdr/asks/q%201/answer', prompt };
  await C.postAction(endpoint, question.route, C.answerBody(question, 'api_first', 'Include docs'));
  await assert.rejects(C.postAction(endpoint, question.route, { answer: 'stale' }), { message: 'This ask is already answered.' });
  await assert.rejects(C.postAction(endpoint, '/api/v1/sympp/herdr/work-requests/wr1/complete', {}), { message: 'WorkRequest is archived. Restore the task, then try again.' }, 'the next step in words, not its code');
  assert.equal(C.undeliveredNote({ delivery: { state: 'not_delivered', reason: 'terminal_finished' } }), 'Answer saved, but the asking terminal has finished. The agent can still read it.');
  assert.equal(C.undeliveredNote({ delivery: { state: 'delivered' } }), null);
  assert.equal(received[0].body.title, 'New job');
  assert.equal(received[1].url, '/api/v1/sympp/herdr/asks/q%201/answer');
  assert.deepEqual(received[1].body, { answer_choice: 'api_first', answer_note: 'Include docs' });
  for (const req of received) {
    assert.equal(req.method, 'POST');
    assert.equal(req.headers['content-type'], 'application/json');
    assert.equal(req.headers.origin, undefined);
    assert.equal(req.headers['sec-fetch-site'], undefined);
    assert.equal(req.headers.forwarded, undefined);
  }
});

test('an offline copy with identical job IDs cannot authorize an agent jump', async (t) => {
  let mode = false;
  const server = createServer((_req, res) => {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ work_request_details: [detail('same-copied-id', 'owner/repo')],
      ...(mode === null ? {} : { runtime: { offline: mode } }) }));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const endpoint = `http://127.0.0.1:${server.address().port}`;
  await C.requireAgentAccess(endpoint);
  mode = true;
  await assert.rejects(C.requireAgentAccess(endpoint), /offline copy/);
  mode = null;
  await assert.rejects(C.requireAgentAccess(endpoint), /verify agent access/);
});

const H = '/api/v1/sympp/herdr';
const later = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const drawn = (payload, list) => M.parseBoard(C.project(payload, list));
const decisions = (board) => board.jobs.flatMap((job) => job.decisions).map((d) => d.id);
const asks = (board) => board.jobs.flatMap((job) => job.asks).map((ask) => ask.id);
const refused = (code, next = null) => Object.assign(new Error('Refused.'), { code, next });

test('an acked decision leaves at once, and a second click while it is sent sends nothing', async () => {
  const payload = variantPayload('busy');
  const list = [];
  const answer = later();
  let sends = 0;
  const send = () => { sends++; return answer.promise; };
  const ack = C.actionOf(`${H}/decisions/dec-toast/ack`);
  const first = C.take(list, ack, send);
  assert.equal(decisions(drawn(payload, list)).includes('dec-toast'), false);
  const second = C.take(list, ack, send);
  assert.equal(sends, 1);
  answer.resolve({ ok: true });
  assert.deepEqual(await first, { ok: true });
  assert.deepEqual(await second, { ok: true });
});

test('a refusal brings the item back as the factory has it and says why', async () => {
  const payload = variantPayload('busy');
  const list = [];
  const answer = later();
  const sent = C.take(list, C.actionOf(`${H}/decisions/dec-toast/feedback`, { text: 'Fade it after a minute.' }), () => answer.promise);
  const sending = drawn(payload, list).jobs.flatMap((job) => job.decisions).find((d) => d.id === 'dec-toast');
  assert.ok(sending.sending && sending.feedback === 'Fade it after a minute.', 'the feedback shows on its way');
  answer.reject(new Error('Ledger busy. Try again.'));
  await assert.rejects(sent, { message: 'Ledger busy. Try again.' });
  assert.deepEqual(drawn(payload, list), M.parseBoard(payload));
});

test('a refusal that says the outcome already holds counts as done, but never for what the person wrote', async () => {
  const stale = variantPayload('busy');
  const list = [];
  assert.equal(await C.take(list, C.actionOf(`${H}/decisions/dec-toast/ack`), async () => { throw refused('decision_transition_refused', 'none'); }), null);
  assert.equal(decisions(drawn(stale, list)).includes('dec-toast'), false, 'a read taken before the factory caught up does not bring it back');
  await assert.rejects(C.take(list, C.actionOf(`${H}/decisions/dec-order/feedback`, { text: 'Keep them listed.' }), async () => { throw refused('decision_transition_refused', 'none'); }));
  await assert.rejects(C.take(list, C.actionOf(`${H}/asks/q1/answer`, { answer: 'Levels first.' }), async () => { throw refused('ask_not_open'); }));
  assert.ok(decisions(drawn(stale, list)).includes('dec-order') && asks(drawn(stale, list)).includes('q1'));
});

test('a read taken before the factory caught up does not bring an answered question back', async () => {
  let payload = variantPayload('busy');
  const stale = payload;
  const list = [];
  const factory = (path, body) => async () => { payload = structuredClone(payload); applyDemo(payload, path, body); return { ok: true }; };
  await C.take(list, C.actionOf(`${H}/asks/q1/answer`, { answer: 'Levels first.' }), factory(`${H}/asks/q1/answer`, { answer: 'Levels first.' }));
  C.settle(list, stale, C.readStarts());
  assert.equal(asks(drawn(stale, list)).includes('q1'), false);
  C.settle(list, payload, C.readStarts());
  assert.equal(list.length, 0, 'a read that shows it answered ends it');
});

test("a task's steps go to the factory in the order taken, and a step undone before the next read does not stick", async () => {
  let payload = variantPayload('busy');
  const before = payload;
  const list = [];
  const sent = [];
  const completing = later();
  const early = C.readStarts();
  const step = (name) => C.take(list, C.actionOf(`${H}/work-requests/wr-recap/${name}`), async () => {
    sent.push(name);
    if (name === 'complete') await completing.promise;
    payload = structuredClone(payload);
    applyDemo(payload, `${H}/work-requests/wr-recap/${name}`);
    return { ok: true };
  });
  const complete = step('complete');
  const archive = step('archive');
  await Promise.resolve();
  assert.deepEqual(sent, ['complete']);
  assert.equal(drawn(payload, list).jobs.find((job) => job.id === 'wr-recap').phase, 'archived');
  completing.resolve();
  await Promise.all([complete, archive]);
  await step('restore');
  assert.deepEqual(sent, ['complete', 'archive', 'restore']);
  // A read begun before the factory agreed predates the steps, though it is not archived either.
  C.settle(list, before, early);
  assert.equal(drawn(before, list).jobs.find((job) => job.id === 'wr-recap').phase, 'done');
  C.settle(list, payload, C.readStarts());
  assert.equal(list.length, 0);
  assert.equal(drawn(payload, list).jobs.find((job) => job.id === 'wr-recap').phase, 'done');
  await step('archive');
  assert.deepEqual(sent.at(-1), 'archive', 'archiving again is a new step, not a second click');
});

test('a restored task shows the phase the factory reads off it', () => {
  const payload = variantPayload('busy');
  applyDemo(payload, `${H}/work-requests/wr-recap/archive`);
  const list = [];
  C.take(list, C.actionOf(`${H}/work-requests/wr-recap/restore`), () => new Promise(() => {}));
  assert.equal(drawn(payload, list).jobs.find((job) => job.id === 'wr-recap').phase, 'unresolved');
});
