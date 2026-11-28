import { expect } from 'e2e';
import { blockerActive, close, row, test as deliveryTest } from '../support/delivery.js';
import { contract, herdr, nextTerminal, test, type Client } from '../support/factory.js';
import { age, test as coreTest } from '../support/herdr-core.js';

async function packageState(architect: Client, request: string, wp: string) {
  return row(architect, request, wp);
}

test('a conversational answer records its decision atomically and a resolved ask stays resolved', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Human decision');
  await architect.call('set_report', { brief: 'Reviewing the scope.' });
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
  const repeated = await architect.call('resolve_ask', { ...args, answer: 'Change the answer.' });
  expect(repeated.ask).toEqual(answer.ask);
  expect(repeated.decision_log_entry).toBeUndefined();
  const observer = await factory.client();
  const read = await observer.call('read_work_request', { work_request_id: id });
  expect(read.decisions).toHaveLength(1);
  const decision = await observer.readDecision(id, answer.decision_log_entry.id);
  expect(decision.id).toBe(answer.decision_log_entry.id);
  expect(decision.source_type).toBe('human');
  expect(decision.source_id).toBe(ask.id);
  expect(decision.created_by).toBe(architect.address);
  expect(decision.decision).toBe(args.decision.decision);
  expect(decision.rationale).toBe(args.decision.rationale);
  expect(decision.scope_impact).toBe(args.decision.scope_impact);
  expect((await observer.readAsk(id, ask.id)).answer).toBe(args.answer);
  expect(read.work_request.phase).toBe('intake');
  expect((await architect.addPackages([contract('Approved outcome', { goal: `Implement decision ${decision.id}` })]))).toHaveLength(1);
});

deliveryTest('answering or withdrawing an ask changes only the blockers that name it', async ({ watched: { factory } }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Decision versus blocker');
  const [affected, sibling] = await architect.addPackages([contract('Affected work'), contract('Sibling work')]);
  await architect.call('dispatch_work_package', { work_package_id: affected });
  await architect.call('dispatch_work_package', { work_package_id: sibling });
  const siblingBefore = await packageState(architect, id, sibling);
  expect(await blockerActive(architect, affected)).toBe(false);
  const ask = (await chief.call('ask', {
    work_request_id: id, work_package_id: affected, question: 'Should we change the optional detail?',
  })).ask.id;
  const withdrawn = (await chief.call('ask', { work_request_id: id, question: 'Is the old approval still needed?' })).ask.id;
  const target = { kind: 'ask', id: ask };
  await architect.call('set_report', { brief: 'Waiting for a human scope choice.', parking: { targets: [target, { kind: 'ask', id: withdrawn }] } });
  expect((await architect.board(id)).blockers).toMatchObject([{ target, state: 'waiting' }, { target: { id: withdrawn }, state: 'waiting' }]);
  expect(await blockerActive(architect, affected)).toBe(false);

  const declaration = { work_package_id: affected, target, active: true, summary: 'Confirm the optional detail.' };
  expect((await architect.call('set_blocker', declaration)).blocker).toMatchObject({ id: `ask:${ask}`, state: 'waiting' });
  expect(await blockerActive(architect, affected)).toBe(true);
  await architect.call('resolve_ask', {
    ask_id: ask, to: 'answered', answer: 'Keep the optional detail deferred.',
    decision: { source_type: 'human', decision: 'Defer the optional detail.', rationale: 'The current scope is sufficient.', scope_impact: 'No package changes.' },
  });
  await architect.call('resolve_ask', { ask_id: withdrawn, to: 'withdrawn' });
  await factory.tick('sweep');
  expect(await blockerActive(architect, affected)).toBe(false);
  const read = await architect.call('read_work_request', { work_request_id: id });
  expect((await architect.board(id)).blockers).toMatchObject([
    { target, state: 'cleared', next_action: 'dispatch' },
    { target: { id: withdrawn }, state: 'impossible', next_action: 'replan' },
    { target, work_package_id: affected, summary: declaration.summary, state: 'cleared', next_action: 'dispatch' },
  ]);
  expect(read.work_request.next_action).toBe('replan');
  expect(read.work_request.operator_report.brief.text).toBe('Waiting for a human scope choice.');
  expect((await packageState(architect, id, sibling)).merge_eligibility).toEqual(siblingBefore.merge_eligibility);

  const parking = { hold: 'The operator paused this goal.' };
  await architect.reject('set_report', { parking }, 'hold_requires_chief');
  await chief.call('set_report', { work_request_id: id, parking });
  await factory.tick('sweep');
  expect((await architect.board(id)).blockers[0]).toMatchObject({ hold: 'operator', summary: parking.hold, state: 'waiting' });
  await architect.call('set_report', { parking: null });
  expect((await architect.call('read_work_request', { work_request_id: id })).work_request.operator_report.parking.resumed_at).toBeTruthy();
});

deliveryTest('typed dependencies reuse plan edges and reject cycles across packages and requests', async ({ watched: { factory } }) => {
  const architect = await factory.client();
  const other = await factory.client();
  const request = await architect.request('Product delivery');
  const otherId = await other.request('Prerequisite delivery');
  const [first, second] = await architect.addPackages([contract('Prerequisite'), contract('Dependent')]);
  const [foreign] = await other.addPackages([contract('Shared prerequisite')]);
  const packageTarget = (id: string) => ({ kind: 'work_package', id });
  const requestTarget = (id: string) => ({ kind: 'work_request', id });
  const declare = (work_package_id: string, target: object) => ({ work_package_id, target, active: true, summary: 'Required before this can ship.' });

  await architect.reject('set_blocker', declare(first, packageTarget(first)), 'blocker_cycle');
  expect((await architect.call('set_blocker', declare(second, packageTarget(first)))).blocker.state).toBe('waiting');
  await architect.reject('set_blocker', declare(first, packageTarget(second)), 'blocker_cycle');
  const plan = (await architect.call('read_work_request', { work_request_id: request, view: 'plan' })).plan;
  expect(plan.dependencies).toMatchObject([{ from: second, to: first, reason: 'Required before this can ship.' }]);
  await architect.reject('dispatch_work_package', { work_package_id: second }, 'unmet_work_package_dependencies');

  await architect.reject('set_report', { parking: { targets: [requestTarget(request)] } }, 'blocker_cycle');
  await architect.call('set_report', { parking: { targets: [requestTarget(otherId), packageTarget(first)] } });
  expect((await architect.call('read_work_request', { work_request_id: request })).work_request.next_action).toBe('dispatch_work_package');
  await other.reject('set_blocker', declare(foreign, requestTarget(request)), 'blocker_cycle');
  await other.reject('set_report', { parking: { targets: [requestTarget(request)] } }, 'blocker_cycle');
  await close(architect, first);
  await close(other, foreign);
  await factory.tick('sweep');
  expect((await architect.board(request)).blockers).toMatchObject([
    { target: requestTarget(otherId), state: 'cleared' },
    { target: packageTarget(first), state: 'cleared' },
    { target: packageTarget(first), work_package_id: second, state: 'cleared' },
  ]);
  expect((await architect.call('dispatch_work_package', { work_package_id: second })).work_package.id).toBe(second);
});

test('package endings withdraw their asks, and chiefs and the owner can resolve WorkRequest asks', async ({ factory }) => {
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
  expect(await architect.readAsk(id, onPackage.id)).toMatchObject({ state: 'withdrawn', answered_by: 'subject_ended' });
  expect((await architect.readAsk(id, onSibling.id)).state).toBe('open');
  const anotherChief = await factory.client(nextTerminal(), { 'sympp.role': 'chief' });
  expect((await anotherChief.call('resolve_ask', { ask_id: onSibling.id, to: 'withdrawn' })).ask).toMatchObject({ state: 'withdrawn', answered_by: anotherChief.address });
  await chief.reject('ask', { work_request_id: id, work_package_id: wp, question: 'Too late?' }, 'work_package_ended');
});

test('a chief recommends one choice, persists it for both interfaces, and cannot recommend two', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const owner = await factory.client();
  const id = await owner.request('Recommended choice');
  const options = [
    { id: 'small', label: 'Small scope', answer: 'Ship the small scope.', recommended: true },
    { id: 'wide', label: 'Wide scope', answer: 'Ship the wide scope.', recommended: false },
    { id: 'later', label: 'Defer', answer: 'Defer delivery.' },
  ];
  const params = { work_request_id: id, question: 'Which scope?', decision_prompt: {
    tl_dr: 'Choose scope', details: 'The operator chooses what ships.', options,
  } };
  const ask = (await chief.call('ask', params)).ask;
  expect(ask.decision_prompt.options).toEqual(options);
  expect((await owner.readAsk(id, ask.id)).decision_prompt.options).toEqual(options);
  for (const route of ['/api/v1/sympp/operator/work-requests/' + id, '/api/v1/sympp/herdr/dashboard']) {
    const response = await owner.raw(null, { origin: new URL(await factory.endpoint).origin }, 'GET', route);
    expect(response.status).toBe(200);
    const detail = route.endsWith('dashboard') ? response.body.work_request_details.find((entry: any) => entry.work_request.id === id) : response.body;
    expect(detail.asks[0].decision_prompt.options).toEqual(options);
  }
  const rejected = await chief.rpc('tools/call', chief.toolParams('ask', {
    ...params, decision_prompt: { ...params.decision_prompt, options: [options[0], { ...options[1], recommended: true }, options[2]] },
  }));
  expect(rejected.error.code).toBe(-32602);
  expect(rejected.error.data).toMatchObject({ code: 'invalid_decision_prompt', message: 'at most one option may be recommended' });
  expect((await owner.call('read_work_request', { work_request_id: id })).asks).toHaveLength(1);
});

test('human choice submission rejects unknown or empty redirects and preserves the selected answer', async ({ factory }) => {
  const chief = await factory.client(undefined, { 'sympp.role': 'chief' });
  const architect = await factory.client();
  const id = await architect.request('Structured human choices');
  await architect.call('set_report', { brief: 'Reviewing choices.' });
  const refused = await architect.reject('ask', {
    work_request_id: id, question: 'May this PR exceed the size guide?',
  }, 'chief_only');
  expect(refused.next_action).toBe('Only the chief asks the human owner. Send your chief one line instead.');
  expect((await architect.call('read_work_request', { work_request_id: id })).asks).toEqual([]);
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
  expect((await architect.call('read_work_request', { work_request_id: id })).asks).toEqual([]);
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
    const current = await architect.call('read_work_request', { work_request_id: id });
    expect((await architect.readAsk(id, first)).state).toBe('open');
    expect(current.decisions).toEqual([]);
  }
  const answered = await architect.operator(path, { answer_choice: 'continue', answer_note: 'Keep the detail deferred.', answer: 'Stale autofilled answer.' });
  expect(answered.status).toBe(200);
  // The answer is kept whether or not the asking terminal could be reached.
  expect(answered.body.delivery.state).toMatch(/^(pending|delivered|not_delivered)$/);
  expect(await architect.readAsk(id, first)).toMatchObject({
    answer: 'Continue with the bounded path. Keep the detail deferred.', answered_by: 'operator',
  });

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
    const result = await architect.call('read_work_request', { work_request_id: id });
    expect((await architect.readAsk(id, q)).answer).toBe(choice.answer);
    expect(result.work_request.phase).toBe('intake');
  }
  const withdrawn = await ask();
  await architect.call('resolve_ask', { ask_id: withdrawn, to: 'withdrawn' });
  expect((await architect.raw({ answer: 'Too late.' }, {}, 'POST', `/api/v1/sympp/herdr/asks/${withdrawn}/answer`)).status).toBe(409);
  await architect.reject('resolve_ask', { ask_id: withdrawn, to: 'answered', answer: 'Too late.' }, 'ask_not_open');
  const final = await architect.call('read_work_request', { work_request_id: id });
  expect((await architect.readAsk(id, withdrawn)).answer).toBeUndefined();
  expect(final.decisions).toEqual([]);
});

const description = 'Synthetic acceptance request; no external work is executed.';
const nativeBoard = async (client: Client, request: string) =>
  (await client.raw(null, {}, 'GET', '/api/v1/sympp/herdr/dashboard')).body.work_request_details.find((detail: any) => detail.work_request.id === request);

coreTest('asks go open to answered or withdrawn, take no ownership, and an answer reaches only a live asker on this core', async ({ core }) => {
  const architect = await core.client();
  const id = await architect.request('Ship "EU" &\n<US>');
  await architect.call('set_report', { brief: 'Checking regions.' });
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
  const rolledBack = await architect.call('read_work_request', { work_request_id: id });
  const unresolved = await architect.readAsk(id, ask.id);
  expect(unresolved.state).toBe('open');
  expect(unresolved.answer).toBeUndefined();
  expect(rolledBack.decisions).toEqual([]);
  const answered = await asker.call('resolve_ask', { ask_id: ask.id, to: 'answered', answer: 'Europe, said in chat.', decision: { ...decision, source_type: 'human' } });
  expect(answered.ask).toMatchObject({ state: 'answered', answer: 'Europe, said in chat.', answered_by: asker.address });
  expect(answered.decision_log_entry).toMatchObject({ source_id: ask.id, decision: 'Europe' });
  expect((await architect.reject('resolve_ask', { ask_id: ask.id, to: 'withdrawn' }, 'ask_not_open')).state).toBe('answered');
  const other = (await asker.call('ask', { work_request_id: id, question: 'Need a staging key?' })).ask.id;
  expect((await architect.call('resolve_ask', { ask_id: other, to: 'withdrawn' })).ask).toMatchObject({ state: 'withdrawn', answered_by: architect.address });
  // The summary read lists only open asks.
  expect((await architect.call('read_work_request', { work_request_id: id })).asks).toEqual([]);

  // The person answers on the native board; the answer is typed, unsubmitted, into the asking terminal.
  const question = 'Ship <EU> & US today?\nKeep the "preview" open?';
  const answer = 'Yes, ship <EU> & US.\nKeep </sympp> as text.';
  const live = (await asker.call('ask', { work_request_id: id, question })).ask.id;
  const listed = (await nativeBoard(architect, id)).asks;
  expect(listed).toEqual([expect.objectContaining({ id: live, kind: 'ask', text: question, asked_by: asker.address, answer_route: `/api/v1/sympp/herdr/asks/${live}/answer` })]);
  let releaseAnswer!: () => void;
  core.host.hold = new Promise((resolve) => { releaseAnswer = resolve; });
  const delivered = await architect.raw({ answer }, {}, 'POST', listed[0].answer_route);
  expect(delivered.body.delivery).toEqual({ state: 'pending' });
  await expect.poll(() => core.host.sends.length).toBe(1);
  expect((await architect.raw(undefined, {}, 'GET', delivered.body.delivery_route)).body.delivery.state).toBe('pending');
  releaseAnswer();
  core.host.hold = undefined;
  await expect.poll(async () => (await architect.raw(undefined, {}, 'GET', delivered.body.delivery_route)).body.delivery.state).toBe('delivered');
  expect(core.host.sends).toEqual([{
    target: asker.terminal,
    submit: true,
    text: [
      `<sympp from="operator" ask="${live}" work_request="${id}" title="Ship &quot;EU&quot; &amp;&#10;&lt;US&gt;">`,
      'Question: Ship &lt;EU&gt; &amp; US today?',
      'Keep the "preview" open?',
      'Answer: Yes, ship &lt;EU&gt; &amp; US.',
      'Keep &lt;/sympp&gt; as text.',
      'Status: Already answered and resolved. No resolve_ask is needed.',
      '</sympp>',
    ].join('\n'),
  }]);
  expect((await nativeBoard(architect, id)).asks).toEqual([]);
  const repeated = { ask_id: live, to: 'answered' };
  await (await core.client()).reject('resolve_ask', repeated, 'not_asker_or_owner');
  const stored = await architect.readAsk(id, live);
  expect(stored).toMatchObject({ state: 'answered', answer, answered_by: 'operator' });
  expect((await asker.call('resolve_ask', repeated)).ask).toEqual(stored);

  // Machine names are local aliases: a terminal on another core is never addressed, even under a local address.
  const remote = await asker.rpc('tools/call', { name: 'ask', arguments: { work_request_id: id, question: 'Remote?' },
    _meta: { herdr: { ...herdr(asker.terminal!, { 'sympp.role': 'chief' }), core_id: 'other-core', core_name: 'elsewhere' } } });
  const remoteAnswer = await architect.operator(`/api/v1/sympp/operator/asks/${remote.result.structuredContent.ask.id}/answer`, { answer: 'Yes' });
  expect(remoteAnswer.body.delivery).toEqual({ state: 'pending' });
  const askDelivery = async (client: typeof architect, askId: string) =>
    (await client.readAsk(id, askId)).delivery;
  await expect.poll(() => askDelivery(architect, remote.result.structuredContent.ask.id))
    .toEqual({ state: 'not_delivered', reason: 'terminal_unreachable' });
  // An asker whose terminal has since finished keeps the answer undelivered.
  const leaving = await core.client({ 'sympp.role': 'chief' });
  const late = (await leaving.call('ask', { work_request_id: id, question: 'Which region?', decision_prompt: prompt })).ask.id;
  core.host.terminals.get(leaving.terminal!)!.state = 'finished';
  await core.restart();
  const operator = await core.factory.client(architect.terminal, { 'sympp.role': 'chief' });
  const path = `/api/v1/sympp/operator/asks/${late}/answer`;
  expect((await operator.operator(path, { answer_choice: 'mars' })).body.error.code).toBe('invalid_answer_choice');
  const undelivered = await operator.operator(path, { answer_choice: 'eu' });
  expect(undelivered.body.delivery).toEqual({ state: 'pending' });
  await expect.poll(() => askDelivery(operator, late)).toEqual({ state: 'not_delivered', reason: 'terminal_finished' });
  expect((await operator.operator(path, { answer_choice: 'eu' })).body.error.code).toBe('ask_not_open');
  expect(core.host.sends).toHaveLength(1);

  // Completing the request withdraws its open asks and takes no new ones; archiving refuses ask writes until restore.
  const pending = (await operator.call('ask', { work_request_id: id, question: 'Still needed?' })).ask.id;
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${id}/complete`, {})).status).toBe(200);
  expect((await operator.readAsk(id, pending)).state).toBe('withdrawn');
  expect((await operator.reject('ask', { work_request_id: id, question: 'After completion?' }, 'work_request_completed')).state).toBe('done');
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${id}/archive`, {})).status).toBe(200);
  const originalAsker = await core.factory.client(asker.terminal, { 'sympp.role': 'chief' });
  expect((await originalAsker.call('resolve_ask', repeated)).ask).toEqual(stored);
  const reopened = await operator.request('Archived asks');
  const open = (await operator.call('ask', { work_request_id: reopened, question: 'Before archive?' })).ask.id;
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${reopened}/complete`, {})).status).toBe(200);
  expect((await operator.operator(`/api/v1/sympp/operator/work-requests/${reopened}/archive`, {})).status).toBe(200);
  for (const [name, args] of [['ask', { work_request_id: reopened, question: 'After archive?' }], ['resolve_ask', { ask_id: open, to: 'withdrawn' }]] as const) {
    expect((await operator.reject(name, args, 'work_request_archived')).next_action).toBe('restore');
  }
});

test('flagged decisions reject long text while unflagged evidence stays unrestricted', async ({ factory }) => {
  const recorder = await factory.client();
  const work_request_id = await recorder.request('Readable product calls');
  const args = { work_request_id, source_type: 'architect', scope_impact: 'None' };
  const guidance = 'Flagged decisions are read by the owner: one short sentence each (decision up to 160 characters, rationale up to 240); put evidence in the report.';
  const accepted: { id: string; decision: string; rationale: string }[] = [];

  for (const text of [
    { decision: 'é'.repeat(161), rationale: 'Why' },
    { decision: 'Keep the default.', rationale: 'é'.repeat(241) },
  ]) {
    const refused = await recorder.tool('record_decision', { ...args, ...text, flag: true });
    expect(refused.error).toMatchObject({ code: -32602, data: { code: 'flagged_decision_too_long', message: guidance } });
    const plain = await recorder.call('record_decision', { ...args, ...text, flag: false });
    accepted.push({ id: plain.decision_log_entry.id, ...text });
  }

  const limit = { decision: 'é'.repeat(160), rationale: 'é'.repeat(240) };
  const flagged = await recorder.call('record_decision', { ...args, ...limit, flag: true });
  expect(flagged.decision_log_entry.flagged).toBe(true);
  accepted.push({ id: flagged.decision_log_entry.id, ...limit });
  const stored = await recorder.call('read_work_request', { work_request_id });
  expect(stored.decisions.length + stored.older_decision_count).toBe(accepted.length);
  for (const entry of accepted) {
    expect(await recorder.readDecision(work_request_id, entry.id)).toMatchObject(entry);
  }
});

coreTest('flagged decisions stay visible for review, with feedback submitted to the recorder or dismissed when undelivered', async ({ core }) => {
  const architect = await core.client();
  const reviewed = (await architect.call('create_work_request', {
    repo: 'example/service', base_branch: 'beta', title: 'Reviewed decisions', description, work_type: 'feature',
  })).work_request.id as string;
  let recorder = await core.client();
  const leavingRecorder = await core.client();
  const record = async (client: Client, work_request_id: string, decision: string, flag: boolean) =>
    (await client.call('record_decision', { work_request_id, decision, rationale: 'Why', scope_impact: 'None', source_type: 'architect', flag })).decision_log_entry.id as string;

  const flagged = await Promise.all(['Keep <EU> & US defaults.', 'Acknowledge me', 'Typed before a crash'].map((text) => record(recorder, reviewed, text, true)));
  const gone = await record(leavingRecorder, reviewed, 'Recorded before leaving', true);
  const plain = await record(recorder, reviewed, 'Plain note', false);
  core.host.terminals.get(leavingRecorder.terminal!)!.state = 'finished';
  await core.restart();
  recorder = await core.factory.client(recorder.terminal);

  const toReview = async () => Object.fromEntries((await nativeBoard(recorder, reviewed)).decisions_to_review.map((entry: any) => [entry.id, entry]));
  const review = await toReview();
  expect(Object.keys(review).sort()).toEqual([...flagged, gone].sort());
  expect(review[flagged[0]]).toMatchObject({ review_state: 'recorded', recorded_by: recorder.address, next_action: 'ack or feedback' });
  const route = review[flagged[0]].feedback_route;
  expect((await recorder.raw({ text: '  ' }, {}, 'POST', route)).body.error.code).toBe('missing_feedback');
  const delivered = await recorder.raw({ text: 'Use <EU> & keep the "US" option.' }, {}, 'POST', route);
  expect(delivered.body).toMatchObject({ review_state: 'feedback', delivery: { state: 'pending' } });
  await expect.poll(() => core.host.sends.length).toBe(1);
  await expect.poll(async () => (await toReview())[flagged[0]]).toBeUndefined();
  expect(core.host.sends.at(-1)).toEqual({
    target: recorder.terminal,
    submit: true,
    text: [
      `<sympp from="operator" decision="${flagged[0]}" work_request="${reviewed}" title="Reviewed decisions">`,
      'Decision: Keep &lt;EU&gt; &amp; US defaults.',
      'Feedback: Use &lt;EU&gt; &amp; keep the "US" option.',
      '</sympp>',
    ].join('\n'),
  });
  const decision = (id: string, action: string, body: object = {}) => recorder.operator(`/api/v1/sympp/operator/decisions/${id}/${action}`, body);
  expect((await decision(flagged[1], 'ack')).body.review_state).toBe('acknowledged');
  const undelivered = await decision(gone, 'feedback', { text: 'Use the cheaper plan.' });
  expect(undelivered.body.delivery).toEqual({ state: 'pending' });
  await expect.poll(async () => (await toReview())[gone]?.undelivered_reason).toBe('terminal_finished');
  expect(core.host.sends).toHaveLength(1);
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
  await expect.poll(() => core.host.sends.length).toBe(2);
  const sending = (await toReview())[flagged[2]];
  expect(sending).toMatchObject({ undelivered_reason: 'delivering', next_action: 'wait: the feedback is being typed' });
  expect(sending.dismiss_route).toBeUndefined();
  expect((await refused(flagged[2], 'dismiss')).next_action).toBe('wait: the feedback is being typed');
  await core.restart({ crash: true, stopped: (database) => age(database, 'sympp_work_request_decision_logs', flagged[2], 'reviewed_at', 75) });
  release();
  await typing;
  recorder = await core.factory.client(recorder.terminal);
  expect((await toReview())[flagged[2]].undelivered_reason).toBe('delivering');

  await core.restart({ stopped: (database) => age(database, 'sympp_work_request_decision_logs', flagged[2], 'reviewed_at', 120) });
  recorder = await core.factory.client(recorder.terminal);
  const interrupted = (await toReview())[flagged[2]];
  expect(interrupted.undelivered_reason).toBe('delivery_interrupted');
  expect((await recorder.raw({}, {}, 'POST', interrupted.dismiss_route)).body.ok).toBe(true);
  expect(await toReview()).toEqual({});
});
