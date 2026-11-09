import { expect } from 'e2e';
import { contract, nextTerminal, test, type Client } from '../support/factory.js';

async function packageState(architect: Client, request: string, wp: string) {
  const board = await architect.call('read_work_request', { view: 'board', detail: 'full', work_request_id: request });
  return board.delivery_board.work_packages.find((entry: any) => entry.work_package.id === wp).work_package;
}

test('a conversational answer records its decision atomically and a resolved ask stays resolved', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Human decision');
  const ask = (await architect.call('ask', {
    work_request_id: id, question: 'Ship the bounded option?',
    decision_prompt: { tl_dr: 'Choose scope', details: 'Keep this delivery bounded.',
      options: [{ id: 'bounded', label: 'Bounded option', answer: 'Ship the bounded option.' }] },
  })).ask;
  expect(ask.state).toBe('open');
  expect(ask.asked_by).toBe(architect.address);
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
  const architect = await factory.client();
  const id = await architect.request('Decision versus blocker');
  const [affected, sibling] = await architect.addPackages([contract('Affected work'), contract('Sibling work')]);
  await architect.call('dispatch_work_package', { work_package_id: affected });
  await architect.call('dispatch_work_package', { work_package_id: sibling });
  const initial = await packageState(architect, id, affected);
  const siblingBefore = await packageState(architect, id, sibling);
  expect(initial.blocker_state['active?']).toBe(false);
  const ask = (await architect.call('ask', {
    work_request_id: id, work_package_id: affected, question: 'Should we change the optional detail?',
  })).ask.id;
  await architect.call('set_report', { brief: 'Waiting for a human scope choice.', parking: { reason: 'Should the optional detail ship?' } });
  const parked = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(parked.work_request.operator_report.parking.reason).toBe('Should the optional detail ship?');
  expect((await packageState(architect, id, affected)).blocker_state['active?']).toBe(false);

  const declaration = { work_package_id: affected, blocker_id: 'schema', active: true, summary: 'Required schema is unavailable.' };
  expect((await architect.call('set_blocker', declaration)).changed).toBe(true);
  expect((await architect.call('set_blocker', declaration)).changed).toBe(false);
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
  const stranger = await factory.client();
  await stranger.reject('resolve_ask', { ask_id: onRequest.id, to: 'withdrawn' }, 'not_asker_or_owner');
  expect((await architect.call('resolve_ask', { ask_id: onRequest.id, to: 'withdrawn' })).ask.state).toBe('withdrawn');
  await architect.call('skip_work_package', { work_package_id: wp });
  const read = await architect.call('read_work_request', { detail: 'full', work_request_id: id });
  expect(read.asks.find((entry: any) => entry.id === onPackage.id).state).toBe('withdrawn');
  await chief.reject('ask', { work_request_id: id, work_package_id: wp, question: 'Too late?' }, 'work_package_ended');
});

test('human choice submission rejects unknown or empty redirects and preserves the selected answer', async ({ factory }) => {
  const architect = await factory.client();
  const id = await architect.request('Structured human choices');
  const prompt = {
    tl_dr: 'Choose the bounded path.', details: 'The operator decides the product outcome.',
    options: [{ id: 'continue', label: 'Continue', answer: 'Continue with the bounded path.' }],
  };
  for (const malformed of [
    { tl_dr: 'Missing options', details: 'A choice is required.' },
    { ...prompt, options: [{ id: '__custom_redirect__', label: 'Reserved id', answer: 'Invalid choice.' }] },
  ]) {
    const response = await architect.rpc('tools/call', architect.toolParams('ask', { work_request_id: id, question: 'Invalid question', decision_prompt: malformed }));
    expect(response.error.code).toBe(-32602);
  }
  expect((await architect.call('read_work_request', { detail: 'full', work_request_id: id })).asks).toEqual([]);
  const ask = async (decision_prompt?: object) => (await architect.call('ask', {
    work_request_id: id, question: 'Which path should ship?', ...(decision_prompt ? { decision_prompt } : {}),
  })).ask.id;
  const first = await ask(prompt);
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
