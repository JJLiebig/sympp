import { createServer } from 'node:http';
import { once } from 'node:events';
import { appendFile, chmod, copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { expect, test as base } from 'e2e';
import { Factory, nextTerminal, type Client } from './factory.js';

type Terminal = { state: 'live' | 'finished'; status?: string; labels?: Record<string, string> };
type Reply = { stdout: string; exitCode: number };

// The factory host's herdr-core as its `hc` CLI reports it. Only the external
// protocol is synthetic: the candidate runs `hc` as a subprocess, unchanged.
// It qualifies sympp's liveness and delivery decisions, not a live Herdr.
export class HerdrCore {
  readonly id = 'acceptance-core';
  readonly terminals = new Map<string, Terminal>();
  readonly sends: { target: string; text: string; submit: boolean }[] = [];
  // While set, `hc send` waits for it, as a terminal that is still typing would.
  hold?: Promise<void>;
  readonly server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    const { argv, rpc } = JSON.parse(body);
    const reply = await this.reply(argv, rpc);
    await appendFile(this.receipt, `${JSON.stringify({ argv, rpc, reply })}\n`);
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify(reply));
  });
  constructor(private receipt: string) {}

  private async reply(argv: string[], rpc?: { id: number; method: string }): Promise<Reply> {
    const json = (value: object) => ({ stdout: JSON.stringify(value), exitCode: 0 });
    const record = (address: string, terminal: Terminal) =>
      ({ address, state: terminal.state, ...(terminal.status ? { status: { state: terminal.status } } : {}) });
    const [command, ...rest] = argv;
    if (command === 'server' && rest.join(' ') === 'status --json') return json({ core: { id: this.id, name: 'acceptance' } });
    if (command === 'connect' && rpc?.method === 'terminal.list') {
      const terminals = [...this.terminals].map(([address, terminal]) => ({ ...record(address, terminal), labels: terminal.labels ?? {} }));
      return { stdout: JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result: { terminals } }) + '\n', exitCode: 0 };
    }
    if (command === 'ls' && rest[0] === '--all' && rest[1] === '--json') {
      const [key, value] = rest[2] === '--label' ? rest[3].split('=') : [];
      const listed = [...this.terminals].filter(([, terminal]) => !key || terminal.labels?.[key] === value);
      return json({ terminals: listed.map(([address, terminal]) => record(address, terminal)) });
    }
    if (command === 'get' && rest[1] === '--json' && this.terminals.has(rest[0])) {
      const terminal = this.terminals.get(rest[0])!;
      return json({ ...record(rest[0], terminal), labels: terminal.labels ?? {} });
    }
    if (command === 'send') {
      const submit = rest[0] !== '--no-submit';
      const [raw, target, text] = submit ? rest : rest.slice(1);
      if (raw !== '--raw' || !this.terminals.has(target)) return { stdout: '', exitCode: 1 };
      this.sends.push({ target, text, submit });
      await this.hold;
      return { stdout: '', exitCode: 0 };
    }
    return { stdout: 'Unexpected synthetic hc command', exitCode: 1 };
  }

  async start(root: string) {
    this.server.listen(0, '127.0.0.1');
    await once(this.server, 'listening');
    const bin = join(root, 'herdr-bin');
    await mkdir(bin);
    await copyFile(resolve('tests/support/provider-cli.mjs'), join(bin, 'hc'));
    await chmod(join(bin, 'hc'), 0o755);
    return { bin, endpoint: `http://127.0.0.1:${(this.server.address() as { port: number }).port}` };
  }

  async stop() {
    const closed = once(this.server, 'close');
    this.server.close();
    this.server.closeAllConnections();
    await closed;
  }
}

export type Core = {
  host: HerdrCore;
  root: string;
  factory: Factory;
  // A Herdr terminal on the factory's core, live unless told otherwise.
  client: (labels?: Record<string, string>, terminal?: Partial<Terminal>) => Promise<Client>;
  // Stops the factory (SIGKILL when it crashes) and starts it on the same ledger.
  restart: (options?: { crash?: boolean; stopped?: (database: string) => void }) => Promise<Factory>;
};

export const test = base.extend<{ core: Core }>({
  core: async ({}, use) => {
    const root = await mkdtemp(join(tmpdir(), 'sympp-core-'));
    await mkdir('.e2e', { recursive: true });
    const host = new HerdrCore(join('.e2e', `${basename(root)}-hc.jsonl`));
    const provider = await host.start(root);
    const core: Core = {
      host, root, factory: new Factory(root, provider),
      client: async (labels = {}, terminal = {}) => {
        const address = nextTerminal();
        host.terminals.set(address, { state: 'live', labels, ...terminal });
        return core.factory.client(address, labels);
      },
      restart: async ({ crash = false, stopped } = {}) => {
        if (crash) core.factory.process.kill('SIGKILL');
        await core.factory.stop();
        stopped?.(core.factory.database);
        core.factory = new Factory(root, provider);
        await core.factory.endpoint;
        return core.factory;
      },
    };
    try { await use(core); } finally {
      await core.factory.stop();
      await host.stop();
      await rm(root, { recursive: true, force: true });
    }
  },
});

// Moves one stored time back while the candidate is stopped; every lifecycle
// action itself still goes through the public API.
export function age(database: string, table: string, id: string, column: string, seconds: number) {
  const stamp = new Date(Date.now() - seconds * 1000).toISOString().replace('T', ' ').replace('Z', '000');
  const db = new DatabaseSync(database, { timeout: 5000 });
  try {
    expect(db.prepare(`UPDATE ${table} SET ${column} = ? WHERE id = ?`).run(stamp, id).changes).toBe(1);
  } finally { db.close(); }
}
