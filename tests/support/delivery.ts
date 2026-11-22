import { createServer } from 'node:http';
import { once } from 'node:events';
import { appendFile, chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { expect, test as base } from 'e2e';
import { Factory, type Client } from './factory.js';

type Reply = { stdout: string; exitCode: number };

// A terminal as the factory host's herdr-core lists it.
export type Terminal = { address: string; state: 'live' | 'finished'; cwd?: string; parent?: string; title?: string; labels?: Record<string, string> };

// Own only the external protocols: the `gh` and `hc` CLIs, and GitHub's HTTP
// API the Observer reads. One PR model (`set`) answers both `gh pr view` and
// GraphQL. The real factory, adapters and OS child invocation remain
// unchanged. This does not qualify gh, herdr or GitHub compatibility.
export class Provider {
  readonly replies = new Map<number, Reply>();
  readonly apiReplies = new Map<string, Reply>();
  private readonly pausedApiReplies = new Map<string, () => Promise<void>>();
  readonly calls: { argv: string[]; reply: Reply }[] = [];
  // GitHub's HTTP API: down answers 503; unreadable PRs and branch lookups resolve to nothing.
  github: 'up' | 'down' = 'up';
  readonly unreadable = new Set<number>();
  readonly unreadableBranches = new Set<string>();
  readonly graphql: { query: string; variables: Record<string, unknown> }[] = [];
  readonly rest: string[] = [];
  readonly baseTips = new Map<string, string>();
  readonly commitParents = new Map<string, string[]>();
  readonly unreadableComparisons = new Set<string>();
  // herdr-core: `core` null is unreachable. `sent` records `hc send`.
  core: { id: string; name: string } | null = { id: 'acceptance-core', name: 'acceptance' };
  readonly terminals = new Map<string, Terminal>();
  readonly sent: string[][] = [];
  readonly execRoutes: string[] = [];
  private terminalGetRequested?: (address: string) => void;
  readonly server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    let status = 200;
    let reply: unknown;
    if (request.url === '/cli') {
      const { program, argv, rpc } = JSON.parse(body);
      if (program === 'hc' && argv[0] === 'get' && this.terminalGetRequested) {
        this.terminalGetRequested(argv[1]);
        return;
      }
      const paused = program === 'gh' && argv[0] === 'api' && this.pausedApiReplies.get(argv[5]);
      if (paused) {
        this.pausedApiReplies.delete(argv[5]);
        await paused();
      }
      const answer = program === 'hc' ? this.herdr(argv, rpc) : this.gh(argv);
      if (program !== 'hc') this.calls.push({ argv, reply: answer });
      await appendFile(this.receipt, `${JSON.stringify({ program, argv, rpc, reply: answer })}\n`);
      reply = answer;
    } else {
      [status, reply] = this.http(request.method ?? 'GET', request.url ?? '/', body);
      await appendFile(this.receipt, `${JSON.stringify({ http: `${request.method} ${request.url}`, status })}\n`);
    }
    response.writeHead(status, { 'content-type': 'application/json' });
    response.end(JSON.stringify(reply));
  });
  constructor(private receipt: string) {}

  set(number: number, metadata: object) {
    this.replies.set(number, { stdout: JSON.stringify(metadata), exitCode: 0 });
  }

  pauseApiReply(path: string) {
    let markStarted!: () => void;
    let release!: () => void;
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    this.pausedApiReplies.set(path, () => { markStarted(); return released; });
    return { started, release };
  }

  terminal(record: Terminal) {
    this.terminals.set(record.address, { labels: {}, ...this.terminals.get(record.address), ...record });
  }

  // Withhold get replies until the fixture closes, and signal the first request.
  holdTerminalGets(): Promise<string> {
    return new Promise((resolve) => { this.terminalGetRequested = resolve; });
  }

  // A client's own Herdr terminal is live unless the journey says otherwise.
  readonly clientTerminal = (address: string) => {
    if (!this.terminals.has(address)) this.terminal({ address, state: 'live' });
  };

  private gh(argv: string[]): Reply {
    if (JSON.stringify(argv) === JSON.stringify(['auth', 'status', '--hostname', 'github.com'])) {
      return { stdout: 'Synthetic protocol available', exitCode: 0 };
    } else if (argv.length === 6 && JSON.stringify(argv.slice(0, 5)) ===
      JSON.stringify(['api', '--hostname', 'github.com', '--method', 'GET'])) {
      return this.apiReplies.get(argv[5]) ?? { stdout: 'HTTP 404 synthetic API not found', exitCode: 1 };
    } else if (argv.length === 7 && argv[0] === 'pr' && argv[1] === 'view' &&
      /^\d+$/.test(argv[2]) && argv[3] === '--repo' && ['example/service', 'example/client'].includes(argv[4].toLowerCase()) && argv[5] === '--json') {
      const number = Number(argv[2]);
      const pr = this.pr(number);
      if (pr?.commits?.length > 100) return { stdout: JSON.stringify({ ...pr, commits: pr.commits.slice(0, 100) }), exitCode: 0 };
      return this.replies.get(number) ?? { stdout: 'HTTP 404 synthetic PR not found', exitCode: 1 };
    }
    return { stdout: 'Unexpected synthetic provider command', exitCode: 1 };
  }

  private herdr(argv: string[], rpc?: { id: number; method: string }): Reply {
    const json = (value: unknown) => ({ stdout: JSON.stringify(value), exitCode: 0 });
    if (!this.core) return { stdout: 'herdr-core unreachable', exitCode: 1 };
    const [command, ...rest] = argv;
    if (command === 'server' && rest.join(' ') === 'status --json') return json({ core: this.core });
    if (command === 'connect' && rpc?.method === 'terminal.list') {
      return { stdout: JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result: { terminals: [...this.terminals.values()] } }) + '\n', exitCode: 0 };
    }
    if (command === 'ls' && rest[0] === '--all' && rest[1] === '--json') {
      const [key, value] = rest[2] === '--label' ? rest[3].split('=') : [];
      const listed = [...this.terminals.values()].filter((terminal) => !key || terminal.labels?.[key] === value);
      // `hc ls` leaves worker labels out; `hc get` reads them.
      return json({ terminals: listed.map(({ labels, ...terminal }) => (labels?.['sympp.role'] === 'worker' ? terminal : { ...terminal, labels })) });
    }
    if (command === 'get' && rest[1] === '--json' && this.terminals.has(rest[0])) return json(this.terminals.get(rest[0]));
    if (command === 'send') {
      this.sent.push(rest);
      return json({ ok: true });
    }
    if (command === 'exec' && rest[0] === '--json' && rest[1] === '--on') {
      this.execRoutes.push(rest[2]);
      return { stdout: '{"error":"machine_unknown"}', exitCode: 1 };
    }
    return { stdout: 'Unexpected synthetic herdr command', exitCode: 1 };
  }

  private pr(number: number): any {
    const reply = this.replies.get(number);
    if (!reply || reply.exitCode !== 0 || this.unreadable.has(number)) return undefined;
    try { return JSON.parse(reply.stdout); } catch { return undefined; }
  }

  private prs(repository: string) {
    return [...this.replies.keys()].map((number) => this.pr(number))
      .filter((pr) => pr && typeof pr.url === 'string' && pr.url.startsWith(`https://github.com/${repository}/pull/`));
  }

  private baseTip(pr: any) {
    const repository = new URL(pr.url).pathname.split('/').slice(1, 3).join('/');
    return this.baseTips.get(`${repository}/${pr.baseRefName}`) ?? pr.baseRefOid;
  }

  private ancestors(oid: string) {
    const pending = [oid];
    const seen = new Set<string>();
    while (pending.length) {
      const sha = pending.pop()!;
      if (seen.has(sha)) continue;
      seen.add(sha);
      pending.push(...this.commitParents.get(sha) ?? []);
    }
    return seen;
  }

  private compare(left: string, right: string): [number, unknown] {
    if (this.unreadableComparisons.has(`${left}...${right}`) || !this.commitParents.has(left) || !this.commitParents.has(right)) return [404, {}];
    const mine = this.ancestors(left);
    const theirs = this.ancestors(right);
    const common = [...mine].filter((sha) => theirs.has(sha));
    const older = new Set(common.flatMap((sha) => this.commitParents.get(sha) ?? []));
    const mergeBase = common.filter((sha) => !older.has(sha)).sort()[0];
    if (!mergeBase) return [404, {}];
    return [200, { base_commit: { sha: left }, merge_base_commit: { sha: mergeBase }, ahead_by: theirs.size - common.length, behind_by: mine.size - common.length }];
  }

  private http(method: string, url: string, body: string): [number, unknown] {
    if (this.github === 'down') return [503, { message: 'Synthetic GitHub unavailable' }];
    if (method === 'POST' && url === '/graphql') {
      const { query, variables } = JSON.parse(body);
      this.graphql.push({ query, variables });
      if (typeof variables.c === 'string') {
        const pr = this.pr(variables.n);
        return [200, { data: { repository: { pullRequest: pr && commitsNode(pr, this.baseTip(pr), Number(variables.c)) } } }];
      }
      const data: Record<string, unknown> = {};
      for (let index = 0; `o${index}` in variables; index++) {
        const repository = `${variables[`o${index}`]}/${variables[`r${index}`]}`;
        const selection = query.slice(query.indexOf(`e${index}: repository(`));
        if (!['example/service', 'example/client'].includes(repository)) { data[`e${index}`] = null; continue; }
        if (selection.includes(`pullRequest(number: $n${index}) { headRefOid baseRefOid`) && selection.includes('commits(first: 100)')) {
          const pr = this.pr(variables[`n${index}`]);
          data[`e${index}`] = pr ? { pullRequest: commitsNode(pr, this.baseTip(pr)) } : null;
        } else if (selection.includes(`pullRequest(number: $n${index})`)) {
          if (this.unreadable.has(variables[`n${index}`])) { data[`e${index}`] = null; continue; }
          const pr = this.pr(variables[`n${index}`]);
          data[`e${index}`] = { pullRequest: pr && prNode(pr, this.baseTip(pr)) };
        } else if (this.unreadableBranches.has(variables[`b${index}`])) {
          data[`e${index}`] = null;
        } else {
          const base = variables[`t${index}`];
          const nodes = this.prs(repository).filter((pr) => pr.headRefName === variables[`b${index}`] && (!base || pr.baseRefName === base));
          data[`e${index}`] = { pullRequests: { nodes: nodes.map((pr) => prNode(pr, this.baseTip(pr))) } };
        }
      }
      return [200, { data }];
    }
    this.rest.push(url);
    const comparison = url.match(/^\/repos\/example\/service\/compare\/([0-9a-f]+)\.\.\.([0-9a-f]+)\?per_page=1&page=2$/);
    if (method === 'GET' && comparison) return this.compare(comparison[1], comparison[2]);
    const ref = url.match(/^\/repos\/([^/]+\/[^/]+)\/git\/ref\/heads\/(.+)$/);
    if (method === 'GET' && ref) {
      const sha = this.baseTips.get(`${ref[1]}/${decodeURIComponent(ref[2])}`);
      return sha ? [200, { object: { sha } }] : [404, {}];
    }
    const checks = url.match(/^\/repos\/([^/]+\/[^/]+)\/commits\/([0-9a-f]+)\/(check-runs|status)\?per_page=100$/);
    if (method === 'GET' && checks) {
      const pr = this.prs(checks[1]).find((candidate) => candidate.headRefOid === checks[2]);
      if (checks[3] === 'status') return [200, { statuses: [] }];
      return [200, { check_runs: (pr?.statusCheckRollup ?? []).map((check: any) => ({ name: check.name, conclusion: check.conclusion?.toLowerCase() ?? null })) }];
    }
    return [404, { message: 'Not Found' }];
  }

  // `herdr` also puts the controlled `hc` on PATH; without it the candidate
  // finds no herdr-core, as on a machine without Herdr.
  async start(root: string, herdr = false) {
    this.server.listen(0, '127.0.0.1');
    await once(this.server, 'listening');
    const address = this.server.address() as { port: number };
    const bin = join(root, 'provider-bin');
    await mkdir(bin);
    for (const program of herdr ? ['gh', 'hc'] : ['gh']) {
      await copyFile(resolve('tests/support/provider-cli.mjs'), join(bin, program));
      await chmod(join(bin, program), 0o755);
    }
    return { bin, endpoint: `http://127.0.0.1:${address.port}` };
  }

  async stop() {
    const closed = once(this.server, 'close');
    this.server.close();
    this.server.closeAllConnections();
    await closed;
  }
}

// GitHub's GraphQL view of a `gh pr view` PR: the head commit's check rollup
// is derived from the same checks, and no checks at all is no rollup.
function prNode(pr: any, baseTip: string) {
  const checks: any[] = pr.statusCheckRollup ?? [];
  const states = checks.map((check) => (check.status === 'COMPLETED' ? check.conclusion : check.status ?? check.state));
  const counts = [...new Set(states)].map((state) => ({ state, count: states.filter((item) => item === state).length }));
  const rollup = checks.length === 0 ? null : {
    state: states.some((state) => ['FAILURE', 'STARTUP_FAILURE', 'TIMED_OUT', 'CANCELLED', 'ERROR'].includes(state)) ? 'FAILURE'
      : states.some((state) => ['IN_PROGRESS', 'QUEUED', 'PENDING', 'WAITING', 'REQUESTED', 'EXPECTED'].includes(state)) ? 'PENDING' : 'SUCCESS',
    contexts: { checkRunCountsByState: counts, statusContextCountsByState: [] },
  };
  return {
    number: pr.number, url: pr.url, state: pr.state, isDraft: pr.isDraft, merged: pr.state === 'MERGED', mergedAt: pr.mergedAt,
    mergeable: pr.mergeable, headRefOid: pr.headRefOid, headRefName: pr.headRefName, baseRefName: pr.baseRefName,
    baseRefOid: pr.baseRefOid, baseRef: { target: { oid: baseTip } }, mergeCommit: pr.mergeCommit,
    headRepositoryOwner: { login: new URL(pr.url).pathname.split('/')[1] },
    commits: { totalCount: pr.commits?.length ?? 0, nodes: [{ commit: { oid: pr.headRefOid, statusCheckRollup: rollup } }] },
    reviews: { nodes: [] },
  };
}

function commitsNode(pr: any, baseTip: string, offset = 0) {
  const commits = pr.commits ?? [];
  const end = Math.min(offset + 100, 250, commits.length);
  return {
    headRefOid: pr.headRefOid, baseRefOid: pr.baseRefOid,
    baseRef: { target: { oid: baseTip } },
    commits: { totalCount: commits.length, pageInfo: { hasNextPage: end < Math.min(250, commits.length), endCursor: String(end) },
      nodes: commits.slice(offset, end).map((commit: any) => ({ commit: { oid: commit.oid } })) },
  };
}

// `restart` stops the candidate and starts a new process on the same ledger.
type Delivery = { factory: Factory; provider: Provider; root: string; restart: () => Promise<Factory> };

async function delivery(watcher: boolean, use: (value: Delivery) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), 'sympp-delivery-'));
  await mkdir('.e2e', { recursive: true });
  const provider = new Provider(join('.e2e', `${basename(root)}-provider.jsonl`));
  let current: Factory | undefined;
  try {
    const started = await provider.start(root, watcher);
    const options = {
      ...(watcher ? { watcher: started.endpoint } : {}),
      onTerminal: provider.clientTerminal,
    };
    current = new Factory(root, started, options);
    const restart = async () => {
      await current!.stop();
      current = new Factory(root, started, { ...options, database: current!.database });
      return current;
    };
    await use({ factory: current, provider, root, restart });
  } finally {
    await current?.stop();
    await provider.stop();
    await rm(root, { recursive: true, force: true });
  }
}

// `delivery` is the cockpit: no Observer runs. `watched` is the factory
// runtime with its Observer, whose ticks the journey sends (`factory.tick`).
export const test = base.extend<{ delivery: Delivery; watched: Delivery }>({
  delivery: async ({}, use) => delivery(false, use),
  watched: async ({}, use) => delivery(true, use),
});

export const head = (digit: string) => digit.repeat(40);
export const prUrl = (number: number) => `https://github.com/example/service/pull/${number}`;

export function pr(number: number, sha: string, patch: object = {}) {
  return {
    id: `PR_synthetic_${number}`, number, url: prUrl(number),
    headRefName: `feature/delivery-${number}`, headRefOid: sha,
    baseRefName: 'beta', baseRefOid: head('0'), changedFiles: 1,
    files: [{ path: 'src/service.ts', changeType: 'MODIFIED' }],
    statusCheckRollup: [{ name: 'required', status: 'COMPLETED', conclusion: 'SUCCESS' }],
    reviewDecision: 'APPROVED', state: 'OPEN', isDraft: false,
    mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN',
    createdAt: '2026-01-01T10:00:00Z', updatedAt: '2026-01-01T11:00:00Z',
    mergedAt: null, mergeCommit: null, commits: [{ oid: sha }], ...patch,
  };
}

export async function board(client: Client, request: string) {
  return client.board(request, 'full');
}

export async function row(client: Client, request: string, wp: string) {
  const result = (await board(client, request)).work_packages.find((item: any) => item.id === wp);
  expect(result).toBeTruthy();
  return result;
}

// Only superseded and skipped can end a planned package, so other outcomes
// dispatch it first; dispatching an already dispatched package replays and
// leaves it as it is.
export async function close(client: Client, wp: string, outcome = 'completed_no_pr', args: object = { evidence: 'The architect accepted the investigation findings; no code change was needed.' }) {
  if (outcome !== 'superseded') await client.tool('dispatch_work_package', { work_package_id: wp });
  return client.call('close_work_package', { work_package_id: wp, outcome, ...args });
}

// A package's recorded progress, as the operator's package detail lists it.
export async function progress(client: Client, wp: string) {
  return (await client.inspect(`/api/v1/sympp/operator/work-packages/${wp}`)).progress;
}

export async function sync(client: Client, wp: string, number: number, sha: string) {
  return client.call('sync_pr', { work_package_id: wp, url: prUrl(number), head_sha: sha });
}

// External Review Suite stand-in at the installed skill's fixed path under the
// candidate's home. The factory finds and runs it as a subprocess unchanged;
// `answer` sets what it prints and its exit status, and every argv is recorded.
export async function installReviewSuite(home: string) {
  const directory = join(home, '.agents/skills/review-suite/plugins/review-suite/scripts');
  await mkdir(directory, { recursive: true });
  const answerPath = join(directory, 'answer.json');
  const receipt = join(directory, 'calls.jsonl');
  await writeFile(receipt, '');
  await writeFile(join(directory, 'review.py'), `import json, sys, time
with open(${JSON.stringify(receipt)}, 'a', encoding='utf-8') as calls:
    calls.write(json.dumps(sys.argv[1:]) + '\\n')
with open(${JSON.stringify(answerPath)}, encoding='utf-8') as source:
    answer = json.load(source)
if 'reviews' in answer:
    review_id = sys.argv[sys.argv.index('--id') + 1]
    answer = answer['reviews'].get(review_id, {'stdout': {'error': 'unknown review cycle id: ' + review_id}, 'status': 2})
time.sleep(answer.get('delay_ms', 0) / 1000)
print(json.dumps(answer['stdout']))
raise SystemExit(answer['status'])
`);
  return {
    answer: (stdout: object, status = 0) => writeFile(answerPath, JSON.stringify({ stdout, status })),
    cycles: (reviews: Record<string, object>, delayMs = 0) => writeFile(answerPath, JSON.stringify({ reviews:
      Object.fromEntries(Object.entries(reviews).map(([id, stdout]) => [id, { stdout, status: 0, delay_ms: delayMs }])) })),
    calls: async () => (await readFile(receipt, 'utf8')).split('\n').filter(Boolean).map((line) => JSON.parse(line)),
  };
}
