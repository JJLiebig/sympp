import { createInterface } from 'node:readline';
import { request as httpRequest } from 'node:http';
import { appendFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { expect, test as base } from 'e2e';
import { Candidate, type CandidateOptions } from './candidate.js';

// The public cockpit owns trusted local HTTP initialization, sessions and SQLite.
// The dashboard origin skips UI asset construction; no browser is opened or used.
export class Factory extends Candidate {
  readonly endpoint: Promise<string>;
  readonly receipt: string;

  constructor(readonly root: string, provider?: { bin: string; endpoint: string }, options: CandidateOptions & { name?: string } = {}) {
    super(root, options.name ?? 'factory', 'http', provider, options);
    this.receipt = join('.e2e', `${basename(root)}-mcp.jsonl`);
    this.endpoint = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Candidate cockpit startup timed out')), 30_000);
      const lines = createInterface({ input: this.process.stdout });
      lines.on('line', (line) => {
        const match = line.match(/sympp API bridge: (http:\/\/127\.0\.0\.1:\d+)/);
        if (match) {
          clearTimeout(timer);
          resolve(`${match[1]}/mcp`);
          lines.close();
          // Closing this startup reader pauses the shared stream; keep the
          // candidate's permanent process-log reader receiving later output.
          this.process.stdout.resume();
        }
      });
      this.process.once('exit', (code) => { clearTimeout(timer); reject(new Error(`Cockpit exited: ${code}`)); });
      this.process.once('error', (error) => { clearTimeout(timer); reject(error); });
    });
  }

  // Each client is its own Herdr terminal unless told otherwise; `null` is a
  // caller outside Herdr, which can only read.
  async client(terminal: string | null = nextTerminal(), labels: Record<string, string> = {}) {
    const client = new Client(await this.endpoint, this.receipt, terminal, labels);
    const initialized = await client.rpc('initialize', {
      protocolVersion: '2025-03-26', capabilities: {},
      clientInfo: { name: 'factory-acceptance', version: '1.0.0' },
    });
    expect(initialized.result.protocolVersion).toBe('2025-03-26');
    const health = await client.call('sympp.health');
    expect(health.status).toBe('ok');
    expect(health.source.revision).toBe(process.env.ACCEPTANCE_CHECKOUT_SHA);
    expect(health.ledger.identity.default_home).toBe(false);
    return client;
  }
}

let terminalCount = 0;
export const nextTerminal = () => `t${++terminalCount}`;

// The identity a verified sympp bridge sends for its Herdr terminal.
export const herdr = (terminal: string, labels: Record<string, string> = {}) => ({
  core_id: 'acceptance-core', core_name: 'acceptance', terminal_id: terminal, labels,
});

// Writes that name only a WorkRequest; the client passes the request it works on.
const requestScoped = new Set(['edit_plan', 'set_report']);

export class Client {
  private sequence = 0;
  private session?: string;
  workRequest?: string;

  constructor(private endpoint: string, private receipt?: string, readonly terminal: string | null = null, readonly labels: Record<string, string> = {}) {}

  get address() { return this.terminal ? `acceptance/${this.terminal}` : null; }

  // Reconnecting (for example after a restart) keeps the same terminal.
  reconnect(endpoint: string) {
    const client = new Client(endpoint, this.receipt, this.terminal, this.labels);
    client.session = this.session;
    client.workRequest = this.workRequest;
    return client;
  }

  toolParams(name: string, args: object) {
    let scoped = requestScoped.has(name) && this.workRequest && !('work_request_id' in args) && !('work_package_id' in args)
      ? { work_request_id: this.workRequest, ...args } : args;
    // Journeys that only need a dispatched package dispatch without a review step.
    if (name === 'dispatch_work_package' && !('review_mode' in scoped)) scoped = { review_mode: 'none', ...scoped };
    return { name, arguments: scoped, ...(this.terminal ? { _meta: { herdr: herdr(this.terminal, this.labels) } } : {}) };
  }

  private async record(entry: object) {
    // Assertions inspect the actual response. Evidence never persists proof or
    // synthetic secret values deliberately submitted by the redaction journeys.
    const text = (value: string) => value.replace(/Bearer\s+[^\s"\\]+/gi, 'Bearer [REDACTED]').replace(/sk-[a-zA-Z0-9_-]+/g, '[REDACTED]');
    const redact = (value: any): any => {
      if (typeof value === 'string') return text(value);
      if (Array.isArray(value)) return value.map(redact);
      if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [
        text(key), /^(secret|secret_hash|proof_hash|token|authorization|work_key|apiKey|accessKey|grant_verifier|private_payload)$/i.test(key) ? '[REDACTED]' : redact(item),
      ]));
      return value;
    };
    if (this.receipt) await appendFile(this.receipt, `${JSON.stringify(redact(entry))}\n`);
  }

  private async exchange(url: string | URL, init: RequestInit, receipt: object) {
    await this.record({ ...receipt, phase: 'request' });
    let status: number | undefined;
    let rawBody: string | undefined;
    try {
      // Node's native HTTP transport preserves explicit Host headers, which
      // Fetch can replace. Origin/forwarding denial proof needs actual wire input.
      const response = await new Promise<Response>((resolve, reject) => {
        const request = httpRequest(url, {
          method: init.method, headers: Object.fromEntries(new Headers(init.headers)), signal: init.signal ?? undefined,
        }, (incoming) => {
          const chunks: Buffer[] = [];
          incoming.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
          incoming.on('error', reject);
          incoming.on('end', () => {
            const headers = new Headers();
            for (const [name, value] of Object.entries(incoming.headers)) {
              if (value !== undefined) headers.set(name, Array.isArray(value) ? value.join(', ') : value);
            }
            resolve(new Response(Buffer.concat(chunks), { status: incoming.statusCode, headers }));
          });
        });
        request.on('error', reject);
        request.end(init.body);
      });
      status = response.status;
      rawBody = await response.text();
      const body = rawBody === '' ? null : JSON.parse(rawBody);
      await this.record({ ...receipt, phase: 'response', status, response: body });
      return { response, body };
    } catch (error) {
      try {
        await this.record({ ...receipt, phase: 'failure', status, rawBody, error: String(error) });
      } finally {
        throw error;
      }
    }
  }

  async rpc(method: string, params: any = {}) {
    if (method === 'tools/call' && this.terminal && !params._meta) params = { ...params, _meta: { herdr: herdr(this.terminal, this.labels) } };
    const { status, body } = await this.raw({ jsonrpc: '2.0', id: ++this.sequence, method, params });
    expect(status).toBe(200);
    return body;
  }

  async raw(payload: unknown, headers: Record<string, string> = {}, method = 'POST', path = '/mcp') {
    const { response, body } = await this.exchange(new URL(path, this.endpoint), {
      method,
      headers: { 'content-type': 'application/json', accept: 'application/json', ...(this.session ? { 'mcp-session-id': this.session } : {}), ...headers },
      ...(method === 'POST' ? { body: typeof payload === 'string' ? payload : JSON.stringify(payload) } : {}),
      signal: AbortSignal.timeout(30_000),
    }, { method: typeof payload === 'object' && payload !== null && 'method' in payload ? payload.method : method,
      payload, headerNames: Object.keys(headers) });
    this.session = response.headers.get('mcp-session-id') ?? this.session;
    return { status: response.status, body, sessionId: response.headers.get('mcp-session-id'), binding: response.headers.get('sympp-herdr-binding') };
  }

  async call(name: string, args: object = {}) {
    const response = await this.rpc('tools/call', this.toolParams(name, args));
    expect(response.error, `${name}: ${JSON.stringify(response.error)}`).toBeUndefined();
    expect(response.result.isError).not.toBe(true);
    return response.result.structuredContent;
  }

  // Adds packages with one edit_plan call and returns their ids in order.
  async addPackages(contracts: object[], args: object = {}): Promise<string[]> {
    const edited = await this.call('edit_plan', { ...args, ops: contracts.map((contract) => ({ op: 'add_package', ...contract })) });
    return edited.applied.map((op: any) => op.work_package_id);
  }

  async board(workRequest = this.workRequest, detail = 'summary') {
    return (await this.call('read_work_request', { work_request_id: workRequest, view: 'board', detail })).delivery_board;
  }

  async tool(name: string, args: object = {}) {
    return this.rpc('tools/call', this.toolParams(name, args));
  }

  async reject(name: string, args: object, reason: string) {
    const response = await this.tool(name, args);
    expect(response.error?.data?.code).toBe(reason);
    return response.error.data;
  }

  async operator(path: string, args: object) {
    const { response, body } = await this.exchange(new URL(path, this.endpoint), {
      method: 'POST', headers: { 'content-type': 'application/json', origin: new URL(this.endpoint).origin },
      body: JSON.stringify(args), signal: AbortSignal.timeout(30_000),
    }, { method: 'POST', path, args });
    return { status: response.status, body };
  }

  async inspect(path: string) {
    const { response, body } = await this.exchange(new URL(path, this.endpoint), {
      headers: { origin: new URL(this.endpoint).origin }, signal: AbortSignal.timeout(30_000),
    }, { method: 'GET', path });
    expect(response.status).toBe(200);
    return body;
  }

  async request(title: string, baseBranch = 'beta', repo = 'example/service') {
    const created = await this.call('create_work_request', {
      repo, base_branch: baseBranch, title,
      description: 'Synthetic acceptance request; no external work is executed.',
      work_type: 'feature',
    });
    expect(created.status).toBe('created');
    // Creating a WorkRequest makes this terminal its owner and its creator.
    expect(created.worked_on.address).toBe(this.address);
    const id = created.work_request.id;
    const read = await this.call('read_work_request', { detail: 'full', work_request_id: id });
    expect(read.work_request.phase).toBe('intake');
    expect(read.work_request.creator).toEqual({ kind: 'agent', name: this.address, via: 'mcp' });
    this.workRequest = id;
    return id;
  }
}

export function contract(title: string, patch: object = {}) {
  return {
    title, goal: `Deliver ${title}`, allowed_file_globs: ['src/**'],
    forbidden_file_globs: ['secrets/**'], acceptance_criteria: ['The agreed behavior is available.'],
    validation_steps: ['Run relevant hosted checks.'], stop_conditions: ['Return material scope changes to the architect.'],
    ...patch,
  };
}

export const test = base.extend<{ factory: Factory }>({
  factory: async ({}, use) => {
    const root = await mkdtemp(join(tmpdir(), 'sympp-factory-'));
    await mkdir('.e2e', { recursive: true });
    const factory = new Factory(root);
    try { await use(factory); } finally {
      await factory.stop();
      await rm(root, { recursive: true, force: true });
    }
  },
});
