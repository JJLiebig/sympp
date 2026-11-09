#!/usr/bin/env node
// A machine's herdr-core as its `hc` CLI serves sympp's installed bridge and
// task launcher (`hc connect`) and a pasted dispatch launch line (`hc run`).
// Only the core is synthetic: terminals live in the JSON file HC_SOCKET names.
// It qualifies sympp's use of the protocol, not a live Herdr.
import { readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const file = process.env.HC_SOCKET;
const load = () => JSON.parse(readFileSync(file, 'utf8'));
const save = (state) => writeFileSync(file, JSON.stringify(state, null, 2));
const [command, ...rest] = process.argv.slice(2);

if (command === 'connect') {
  createInterface({ input: process.stdin }).on('line', (line) => {
    const { id, method, params } = JSON.parse(line);
    const state = load();
    state.calls.push({ method, params });
    // A connect may start a long-lived core, so it must never inherit a provider credential.
    if (process.env.OPENAI_API_KEY) state.transport_secret_present = true;
    const terminal = state.terminals[params?.terminal];
    let reply;
    if (method === 'hello') reply = { result: { generation: 1, core: state.core } };
    else if (method === 'terminal.run') {
      if (Object.values(state.terminals).some((other) => other.state === 'live' && other.name === params.name)) reply = { error: { data: { kind: 'name_taken' } } };
      else {
        const address = `t${Object.keys(state.terminals).length + 1}`;
        const started = { ...params, state: 'live', pid: 7000 + Object.keys(state.terminals).length, labels: params.labels ?? {}, status: { state: 'idle', app: params.argv[0] } };
        state.terminals[address] = started;
        // A core that started the terminal but whose reply was lost.
        if (state.lose_reply) { save(state); process.exit(0); }
        reply = { result: { address, ...started } };
      }
    } else if (method === 'terminal.send' && terminal) {
      // The agent exits and its shell takes the terminal just before the text arrives.
      if (state.recover_before_send) { terminal.pid += 1; terminal.status = null; delete state.recover_before_send; }
      if (params.if !== terminal.status?.state) reply = { error: { data: { kind: 'status_mismatch' } } };
      else { (terminal.sent ??= []).push(params.text); reply = { result: { started: true, turn: terminal.sent.length } }; }
    } else if (method === 'terminal.get' && terminal) reply = { result: { address: params.terminal, ...terminal } };
    else if (method === 'terminal.label' && terminal) {
      // A core that applied nothing because the launcher lost it mid-call.
      if (state.lose_label_reply) { save(state); process.exit(0); }
      for (const [key, value] of Object.entries(params.labels)) {
        if (value) terminal.labels[key] = value; else delete terminal.labels[key];
      }
      reply = { result: { address: params.terminal, ...terminal } };
    } else reply = { error: { data: { kind: terminal ? 'unknown_method' : 'not_found' } } };
    save(state);
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, ...reply })}\n`);
  });
} else if (command === 'run') {
  const state = load();
  const separator = rest.indexOf('--');
  const flags = rest.slice(0, separator);
  const terminal = { state: 'live', pid: 7000 + Object.keys(state.terminals).length, labels: {}, argv: rest.slice(separator + 1) };
  for (let index = 0; index < flags.length; index++) {
    const flag = flags[index];
    if (flag === '--bg') continue;
    const value = flags[++index];
    if (flag === '--label') {
      const [key, ...text] = value.split('=');
      terminal.labels[key] = text.join('=');
    } else terminal[flag.slice(2)] = value;
  }
  const address = `t${Object.keys(state.terminals).length + 1}`;
  state.terminals[address] = terminal;
  state.calls.push({ method: 'run', params: { address, ...terminal } });
  save(state);
  process.stdout.write(`${address}\n`);
} else {
  process.stderr.write('Unexpected synthetic hc command\n');
  process.exitCode = 1;
}
