import { expect } from 'e2e';
import { contract, herdr, nextTerminal, test, type Client } from '../support/factory.js';
import { age, test as coreTest } from '../support/herdr-core.js';

async function packageState(architect: Client, request: string, wp: string) {
  const board = await architect.call('read_work_request', { view: 'board', detail: 'full', work_request_id: request });
  return board.delivery_board.work_packages.find((entry: any) => entry.work_package.id === wp).work_package;
}

test('a conversational answer records its decision atomically and a resolved ask stays resolved', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Human decision');
  const ask = (await chief.call('ask', {
    work_request_id: id, question: 'Ship the bounded option?',
    decision_prompt: { tl_dr: 'Choose scope', details: 'Keep this delivery bounded.',
      options: [{ id: 'bounded', label: 'Bounded option', answer: 'Ship the bounded option.' }] },
  })).ask;
  expect(ask.state).toBe('open');
  expect(ask.asked_by).toBe(chief.address);
  const args = {
    ask_id: ask.id, to: 'answered', answer: 'Ship the bounded option.',
    decision: { source_type: 'human', decision: 'Ship the bounded option.', rationale: 'It meets the agreed need.', scope_impact: 'Defer adjacent behavior.' },
  };
  const answer = await architect.call('resolve_ask', args);
  expect(answer.ask.state).toBe('answered');
  await architect.reject('resolve_ask', args, 'ask_not_open');
  const observer = await factory.client();
  const read = await observer.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(read.decision_log_entries).toHaveLength(1);
  const decision = read.decision_log_entries[0];
  expect(decision.id).toBe(answer.decision_log_entry.id);
  expect(decision.source_type).toBe('human');
  expect(decision.source_id).toBe(ask.id);
  expect(decision.created_by).toBe(architect.address);
  expect(decision.decision).toBe(args.decision.decision);
  expect(decision.rationale).toBe(args.decision.rationale);
  expect(decision.scope_impact).toBe(args.decision.scope_impact);
  expect(read.asks[0].answer).toBe(args.answer);
  expect(read.work_request.phase).toBe('intake');
  expect((await architect.addPackages([contract('Approved outcome', { goal: `Implement decision ${decision.id}` })]))).toHaveLength(1);
});

test('asks and operator reports leave explicit package blockers and sibling state alone', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Decision versus blocker');
  const [affected, sibling] = await architect.addPackages([contract('Affected work'), contract('Sibling work')]);
  await architect.call('dispatch_work_package', { work_package_id: affected });
  await architect.call('dispatch_work_package', { work_package_id: sibling });
  const initial = await packageState(architect, id, affected);
  const siblingBefore = await packageState(architect, id, sibling);
  expect(initial.blocker_state['active?']).toBe(false);
  const ask = (await chief.call('ask', {
    work_request_id: id, work_package_id: affected, question: 'Should we change the optional detail?',
  })).ask.id;
  await architect.call('set_report', { brief: 'Waiting for a human scope choice.', parking: { reason: 'Should the optional detail ship?' } });
  const parked = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(parked.work_request.operator_report.parking.reason).toBe('Should the optional detail ship?');
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(false);

  const declaration = { work_package_id: affected, blocker_id: 'schema', active: true, summary: 'Required schema is unavailable.' };
  expect((await architect.call('set_blocker', declaration)).changed).toBe(true);
  expect((await architect.call('set_blocker', declaration)).changed).toBe(false);
  const reworded = await architect.call('set_blocker', { ...declaration, summary: 'Required schema is still unavailable.' });
  expect([reworded.changed, reworded.blocker.summary]).toEqual([true, 'Required schema is still unavailable.']);
  await architect.reject('set_blocker', { work_package_id: affected, blocker_id: 'schema-typo', active: false }, 'blocker_not_found');
  await architect.call('set_blocker', { work_package_id: affected, blocker_id: 'access', active: true, summary: 'Required access is unavailable.' });
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(true);
  await architect.call('resolve_ask', {
    ask_id: ask, to: 'answered', answer: 'Keep the optional detail deferred.',
    decision: { source_type: 'human', decision: 'Defer the optional detail.', rationale: 'The current scope is sufficient.', scope_impact: 'No package changes.' },
  });
  await architect.call('set_report', { parking: null });
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(true);

  const cleared = await architect.call('set_blocker', { work_package_id: affected, blocker_id: 'schema', active: false });
  expect(cleared.blocker).toMatchObject({ id: 'schema', active: false });
  expect((await architect.call('set_blocker', { work_package_id: affected, blocker_id: 'schema', active: false })).changed).toBe(false);
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(true);
  await architect.call('set_blocker', { work_package_id: affected, blocker_id: 'access', active: false, summary: 'Access prerequisite available.' });
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(false);
  expect(await packageState(architect, id, sibling)).toEqual(siblingBefore);
  const report = (await architect.call('read_work_request', { detail: 'full', work_request_id: id })).work_request.operator_report;
  expect(report.brief.text).toBe('Waiting for a human scope choice.');
  expect(report.parking.reason).toBe('Should the optional detail ship?');
  expect(report.parking.resumed_at).toBeTruthy();
});

test('an ask on a package is withdrawn when the package ends, and only the asker or owner resolves an ask', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Package asks');
  const [wp] = await architect.addPackages([contract('Package with a question')]);
  const chief = await factory.client(nextTerminal(), { 'sympp.role': 'chief', 'sympp.domain': 'product' });
  const onPackage = (await chief.call('ask', { work_request_id: id, work_package_id: wp, question: 'Is this package still wanted?' })).ask;
  const onRequest = (await chief.call('ask', { work_request_id: id, question: 'Who signs off the release?' })).ask;
  const [sibling] = await architect.addPackages([contract('Sibling with a question')]);
  const onSibling = (await chief.call('ask', { work_request_id: id, work_package_id: sibling, question: 'And this one?' })).ask;
  const stranger = await factory.client();
  await stranger.reject('resolve_ask', { ask_id: onRequest.id, to: 'withdrawn' }, 'not_asker_or_owner');
  expect((await architect.call('resolve_ask', { ask_id: onRequest.id, to: 'withdrawn' })).ask.state).toBe('withdrawn');
  await architect.call('close_work_package', { work_package_id: wp, outcome: 'skipped' });
  const read = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(read.asks.find((entry: any) => entry.id === onPackage.id)).toMatchObject({ state: 'withdrawn', answered_by: 'subject_ended' });
  expect(read.asks.find((entry: any) => entry.id === onSibling.id).state).toBe('open');
  await chief.reject('ask', { work_request_id: id, work_package_id: wp, question: 'Too late?' }, 'work_package_ended');
});

test('human choice submission rejects unknown or empty redirects and preserves the selected answer', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Structured human choices');
  const refused = await architect.reject('ask', {
    work_request_id: id, question: 'May this PR exceed the size guide?',
  }, 'chief_only');
  expect(refused.next_action).toBe('Only the chief asks the human owner. Send your chief one line instead.');
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).asks).toEqual([]);
  const prompt = {
    tl_dr: 'Choose the bounded path.', details: 'The operator decides the product outcome.',
    options: [{ id: 'continue', label: 'Continue', answer: 'Continue with the bounded path.' }],
  };
  for (const malformed of [
    { tl_dr: 'Missing options', details: 'A choice is required.' },
    { ...prompt, options: [{ id: '__custom_redirect__', label: 'Reserved id', answer: 'Invalid choice.' }] },
  ]) {
    const response = await chief.rpc('tools/call', chief.toolParams('ask', { work_request_id: id, question: 'Invalid question', decision_prompt: malformed }));
    expect(response.error.code).toBe(-32602);
  }
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).asks).toEqual([]);
  const ask = async (decision_prompt?: object) => (await chief.call('ask', {
    work_request_id: id, question: 'Which path should ship?', ...(decision_prompt ? { decision_prompt } : {}),
  })).ask.id;
  const first = await ask(prompt);
  expect((await nativeBoard(chief, id)).asks).toEqual([
    expect.objectContaining({ id: first, kind: 'ask', text: 'Which path should ship?' }),
  ]);
  const path = `/api/v1/sympp/operator/asks/${first}/answer`;
  for (const invalid of [
    { answer_choice: 'unknown' }, { answer_choice: '__custom_redirect__' }, { answer: 'Stale autofilled answer.' },
  ]) {
    const rejected = await architect.operator(path, invalid);
    expect(rejected.status).toBe(422);
    expect((await architect.raw(invalid, {}, 'POST', path.replace('/operator/', '/herdr/'))).status).toBe(422);
    const current = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
    expect(current.asks[0].state).toBe('open');
    expect(current.decision_log_entries).toEqual([]);
  }
  const answered = await architect.operator(path, { answer_choice: 'continue', answer_note: 'Keep the detail deferred.', answer: 'Stale autofilled answer.' });
  expect(answered.status).toBe(200);
  // The answer is kept whether or not the asking terminal could be reached.
  expect(answered.body.delivery.state).toMatch(/^(delivered|not_delivered)$/);
  const read = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(read.asks[0].answer).toBe('Continue with the bounded path. Keep the detail deferred.');
  expect(read.asks[0].answered_by).toBe('operator');

  const cases = [
    { prompt, input: { answer_choice: '__custom_redirect__', answer_note: 'Use a smaller path.' }, answer: 'Use a smaller path.' },
    { prompt: { ...prompt, custom_redirect_label: 'Choose a different path' }, input: { answer_choice: '__custom_redirect__', answer_note: 'Use the scoped alternative.' }, answer: 'Use the scoped alternative.' },
    { prompt: { ...prompt, options: [{ id: 'redirect', label: 'Internal redirect', answer: 'Use the structured redirect option.' }] }, input: { answer_choice: 'redirect' }, answer: 'Use the structured redirect option.' },
    { prompt: undefined, input: { answer_choice: 'narrow', answer_note: 'Keep it scoped.' }, answer: 'Narrow the scope before continuing. Keep it scoped.' },
  ];
  for (const choice of cases) {
    const q = await ask(choice.prompt);
    const endpoint = `/api/v1/sympp/herdr/asks/${q}/answer`;
    if (!choice.prompt) expect((await architect.raw({ answer_choice: 'redirect' }, {}, 'POST', endpoint)).status).toBe(422);
    expect((await architect.raw(choice.input, {}, 'POST', endpoint.replace(q, 'missing-ask'))).status).toBe(404);
    expect((await architect.raw(choice.input, {}, 'POST', endpoint)).status).toBe(200);
    expect((await architect.raw(choice.input, {}, 'POST', endpoint)).status).toBe(409);
    const result = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
    expect(result.asks.find((entry: any) => entry.id === q).answer).toBe(choice.answer);
    expect(result.work_request.phase).toBe('intake');
  }
  const withdrawn = await ask();
  await architect.call('resolve_ask', { ask_id: withdrawn, to: 'withdrawn' });
  expect((await architect.raw({ answer: 'Too late.' }, {}, 'POST', `/api/v1/sympp/herdr/asks/${withdrawn}/answer`)).status).toBe(409);
  await architect.reject('resolve_ask', { ask_id: withdrawn, to: 'answered', answer: 'Too late.' }, 'ask_not_open');
  const final = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(final.asks.find((entry: any) => entry.id === withdrawn).answer).toBeUndefined();
  expect(final.decision_log_entries).toEqual([]);
});

const description = 'Synthetic acceptance request; no external work is executed.';
const nativeBoard = async (client: Client, request: string) =>
  (await client.raw(null, {}, 'GET', '/api/v1/sympp/herdr/dashboard')).body.work_request_details.find((detail: any) => detail.work_request.id === request);

coreTest('asks go open to answered or withdrawn, take no ownership, and an answer reaches only a live asker on this core', async ({ core }) => {
  const architect = await core.client();
  const id = await architect.request('Ask transitions');
  await (await core.factory.client(null)).reject('ask', { work_request_id: id, question: 'Anyone?' }, 'read_only_outside_herdr');
  await (await core.client({ 'sympp.role': 'chief' })).reject('ask', { work_request_id: 'missing-request', question: 'Where?' }, 'not_found');
  const asker = await core.client({ 'sympp.role': 'chief' });
  const prompt = { tl_dr: 'Pick a region', details: 'Pricing differs by region.',
    options: [{ id: 'eu', label: 'Europe', answer: 'Ship to Europe first.' }, { id: 'us', label: 'US', answer: 'Ship to the US first.' }] };
  const ask = (await asker.call('ask', { work_request_id: id, question: 'Which region first?', decision_prompt: prompt })).ask;
  expect(ask).toMatchObject({ state: 'open', asked_by: asker.address, decision_prompt: { tl_dr: 'Pick a region' } });
  // Asking takes no ownership.
  expect((await asker.call('sympp.health')).caller.owns).toEqual([]);
  const decision = { source_type: 'bot', decision: 'Europe', rationale: 'Cheaper', scope_impact: 'None' };
  await asker.reject('resolve_ask', { ask_id: ask.id, to: 'answered', answer: 'Europe', decision }, 'invalid_decision');
  const rolledBack = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(rolledBack.asks[0]).toMatchObject({ state: 'open' });
  expect(rolledBack.asks[0].answer).toBeUndefined();
  expect(rolledBack.decision_log_entries).toEqual([]);
  const answered = await asker.call('resolve_ask', { ask_id: ask.id, to: 'answered', answer: 'Europe, said in chat.', decision: { ...decision, source_type: 'human' } });
  expect(answered.ask).toMatchObject({ state: 'answered', answer: 'Europe, said in chat.', answered_by: asker.address });
  expect(answered.decision_log_entry).toMatchObject({ source_id: ask.id, decision: 'Europe' });
  expect((await architect.reject('resolve_ask', { ask_id: ask.id, to: 'withdrawn' }, 'ask_not_open')).state).toBe('answered');
  const other = (await asker.call('ask', { work_request_id: id, question: 'Need a staging key?' })).ask.id;
  expect((await architect.call('resolve_ask', { ask_id: other, to: 'withdrawn' })).ask).toMatchObject({ state: 'withdrawn', answered_by: architect.address });
  // The summary read lists only open asks.
  expect((await architect.call('read_work_request', { work_request_id: id })).asks).toEqual([]);

  // The person answers on the native board; the answer is typed, unsubmitted, into the asking terminal.
  const live = (await asker.call('ask', { work_request_id: id, question: 'Ship today?' })).ask.id;
  const listed = (await nativeBoard(architect, id)).asks;
  expect(listed).toEqual([expect.objectContaining({ id: live, kind: 'ask', text: 'Ship today?', asked_by: asker.address, answer_route: `/api/v1/sympp/herdr/asks/${live}/answer` })]);
  const delivered = await architect.raw({ answer: 'Yes' }, {}, 'POST', listed[0].answer_route);
  expect(delivered.body.delivery).toEqual({ state: 'delivered', to: asker.address });
  expect(core.host.sends).toEqual([{ target: asker.terminal, text: 'Answer: Yes', submit: false }]);
  expect((await nativeBoard(architect, id)).asks).toEqual([]);
  const stored = (await architect.call('read_work_request', { detail: 'full', work_request_id: id })).asks.find((entry: any) => entry.id === live);
  expect(stored).toMatchObject({ state: 'answered', answer: 'Yes', answered_by: 'operator' });

  // Machine names are local aliases: a terminal on another core is never addressed, even under a local address.
  const remote = await asker.rpc('tools/call', { name: 'ask', arguments: { work_request_id: id, question: 'Remote?' },
    _meta: { herdr: { ...herdr(asker.terminal!, { 'sympp.role': 'chief' }), core_id: 'other-core', core_name: 'elsewhere' } } });
  const remoteAnswer = await architect.operator(`/api/v1/sympp/operator/asks/${remote.result.structuredContent.ask.id}/answer`, { answer: 'Yes' });
  expect(remoteAnswer.body.delivery).toEqual({ state: 'not_delivered', reason: 'terminal_unreachable' });
  // An asker whose terminal has since finished keeps the answer undelivered.
  const leaving = await core.client({ 'sympp.role': 'chief' });
  const late = (await leaving.call('ask', { work_request_id: id, question: 'Which region?', decision_prompt: prompt })).ask.id;
  core.host.terminals.get(leaving.terminal!)!.state = 'finished';
  await core.restart();
  const operator = await core.factory.client(architect.terminal, { 'sympp.role': 'chief' });
  const path = `/api/v1/sympp/operator/asks/${late}/answer`;
  expect((await operator.operator(path, { answer_choice: 'mars' })).body.error.code).toBe('invalid_answer_choice');
  const undelivered = await operator.operator(path, { answer_choice: 'eu' });
  expect(undelivered.body.delivery).toEqual({ state: 'not_delivered', reason: 'terminal_finished' });
  expect((await operator.operator(path, { answer_choice: 'eu' })).body.error.code).toBe('ask_not_open');
  expect(core.host.sends).toHaveLength(1);

  // Completing the request withdraws its open asks and takes no new ones; archiving refuses ask writes until restore.
  const pending = (await operator.call('ask', { work_request_id: id, question: 'Still needed?' })).ask.id;
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${id}/complete`, {})).status).toBe(200);
  expect((await operator.call('read_work_request', { detail: 'full', work_request_id: id })).asks.find((entry: any) => entry.id === pending).state).toBe('withdrawn');
  expect((await operator.reject('ask', { work_request_id: id, question: 'After completion?' }, 'work_request_completed')).state).toBe('done');
  const reopened = await operator.request('Archived asks');
  const open = (await operator.call('ask', { work_request_id: reopened, question: 'Before archive?' })).ask.id;
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${reopened}/complete`, {})).status).toBe(200);
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${reopened}/archive`, {})).status).toBe(200);
  for (const [name, args] of [['ask', { work_request_id: reopened, question: 'After archive?' }], ['resolve_ask', { ask_id: open, to: 'withdrawn' }]] as const) {
    expect((await operator.reject(name, args, 'work_request_archived')).next_action).toBe('restore');
  }
});

coreTest('a flagged decision notifies the live chief once, and its feedback is typed into the recorder, acknowledged or dismissed when undelivered', async ({ core }) => {
  const chiefLabels = { 'sympp.role': 'chief', 'sympp.domain': 'Pricing' };
  const create = async (client: Client, title: string) => (await client.call('create_work_request', {
    repo: 'example/service', base_branch: 'beta', title, description, work_type: 'feature', own: false,
  })).work_request.id as string;
  const chief = await core.client(chiefLabels);
  const byChief = await create(chief, 'Pricing\npage');
  const architect = await core.client();
  const byArchitect = await create(architect, 'Search');
  const reviewed = await create(architect, 'Reviewed decisions');
  const leavingChief = await core.client(chiefLabels);
  const byLeavingChief = await create(leavingChief, 'Billing');
  // A chief on another core with the same address is a different terminal.
  const elsewhere = (await chief.rpc('tools/call', { name: 'create_work_request',
    arguments: { repo: 'example/service', base_branch: 'beta', title: 'Elsewhere', description, work_type: 'feature', own: false },
    _meta: { herdr: { ...herdr(chief.terminal!, chiefLabels), core_id: 'other-core', core_name: 'elsewhere' } } })).result.structuredContent.work_request.id;
  let recorder = await core.client();
  const leavingRecorder = await core.client();
  const record = async (client: Client, work_request_id: string, decision: string, flag: boolean) =>
    (await client.call('record_decision', { work_request_id, decision, rationale: 'Why', scope_impact: 'None', source_type: 'architect', flag })).decision_log_entry.id as string;

  await record(recorder, byChief, `Use monthly prices\nfirst. ${'x'.repeat(200)}`, true);
  expect(core.host.sends).toHaveLength(1);
  const [notice] = core.host.sends;
  const prefix = `Product call on Pricing page by ${recorder.address}: `;
  expect(notice).toMatchObject({ target: chief.terminal, submit: true });
  expect(notice.text.startsWith(`${prefix}Use monthly prices first. `)).toBe(true);
  expect(notice.text).toHaveLength(prefix.length + 160);
  expect(notice.text.endsWith('x…')).toBe(true);
  await record(recorder, byChief, 'Unflagged', false);
  await record(recorder, byArchitect, 'No chief', true);
  await record(chief, byChief, "The chief's own call", true);
  await record(recorder, elsewhere, "Another core's chief", true);
  const flagged = await Promise.all(['Keep the EU default.', 'Acknowledge me', 'Typed before a crash'].map((text) => record(recorder, reviewed, text, true)));
  const gone = await record(leavingRecorder, reviewed, 'Recorded before leaving', true);
  const plain = await record(recorder, reviewed, 'Plain note', false);
  expect(core.host.sends).toHaveLength(1);
  for (const leaving of [leavingChief, leavingRecorder]) core.host.terminals.get(leaving.terminal!)!.state = 'finished';
  await core.restart();
  recorder = await core.factory.client(recorder.terminal);
  await record(recorder, byLeavingChief, 'Chief finished', true);
  expect(core.host.sends).toHaveLength(1);

  const toReview = async () => Object.fromEntries((await nativeBoard(recorder, reviewed)).decisions_to_review.map((entry: any) => [entry.id, entry]));
  const review = await toReview();
  expect(Object.keys(review).sort()).toEqual([...flagged, gone].sort());
  expect(review[flagged[0]]).toMatchObject({ review_state: 'recorded', recorded_by: recorder.address, next_action: 'ack or feedback' });
  const route = review[flagged[0]].feedback_route;
  expect((await recorder.raw({ text: '  ' }, {}, 'POST', route)).body.error.code).toBe('missing_feedback');
  const delivered = await recorder.raw({ text: 'Keep the EU default.' }, {}, 'POST', route);
  expect(delivered.body).toMatchObject({ review_state: 'feedback', delivery: { state: 'delivered', to: recorder.address } });
  expect(core.host.sends.at(-1)).toEqual({ target: recorder.terminal, text: 'Decision feedback: Keep the EU default.', submit: false });
  const decision = (id: string, action: string, body: object = {}) => recorder.operator(`/api/v1/sympp/operator/decisions/${id}/${action}`, body);
  expect((await decision(flagged[1], 'ack')).body.review_state).toBe('acknowledged');
  const undelivered = await decision(gone, 'feedback', { text: 'Use the cheaper plan.' });
  expect(undelivered.body.delivery).toEqual({ state: 'not_delivered', reason: 'terminal_finished' });
  expect(core.host.sends).toHaveLength(2);
  const refused = async (id: string, action: string) => {
    const response = await decision(id, action, { text: 'Again' });
    expect(response.status).toBe(409);
    const { code, state, next_action } = response.body.error;
    return { code, state, next_action };
  };
  expect(await refused(flagged[1], 'ack')).toEqual({ code: 'decision_transition_refused', state: 'acknowledged', next_action: 'none' });
  expect(await refused(gone, 'feedback')).toEqual({ code: 'decision_transition_refused', state: 'feedback', next_action: 'dismiss' });
  expect(await refused(plain, 'ack')).toEqual({ code: 'decision_transition_refused', state: 'not_flagged', next_action: 'none: only flagged decisions are reviewed' });
  expect(await refused(flagged[0], 'dismiss')).toEqual({ code: 'decision_transition_refused', state: 'feedback', next_action: 'none' });
  const pending = await toReview();
  expect(Object.keys(pending).sort()).toEqual([flagged[2], gone].sort());
  expect(pending[gone]).toMatchObject({ review_state: 'feedback', feedback: 'Use the cheaper plan.', undelivered_reason: 'terminal_finished', next_action: 'dismiss' });
  expect((await recorder.raw({}, {}, 'POST', pending[gone].dismiss_route)).body.ok).toBe(true);

  // Feedback still being typed cannot be dismissed; if the factory dies mid-send, it reads as interrupted.
  let release!: () => void;
  core.host.hold = new Promise((resolve) => { release = resolve; });
  const typing = recorder.raw({ text: 'Typed while the factory stops.' }, {}, 'POST', pending[flagged[2]].feedback_route).catch(() => null);
  await expect.poll(() => core.host.sends.length).toBe(3);
  const sending = (await toReview())[flagged[2]];
  expect(sending).toMatchObject({ undelivered_reason: 'delivering', next_action: 'wait: the feedback is being typed' });
  expect(sending.dismiss_route).toBeUndefined();
  expect((await refused(flagged[2], 'dismiss')).next_action).toBe('wait: the feedback is being typed');
  await core.restart({ crash: true, stopped: (database) => age(database, 'sympp_work_request_decision_logs', flagged[2], 'reviewed_at', 120) });
  release();
  await typing;
  recorder = await core.factory.client(recorder.terminal);
  const interrupted = (await toReview())[flagged[2]];
  expect(interrupted.undelivered_reason).toBe('delivery_interrupted');
  expect((await recorder.raw({}, {}, 'POST', interrupted.dismiss_route)).body.ok).toBe(true);
  expect(await toReview()).toEqual({});
});
