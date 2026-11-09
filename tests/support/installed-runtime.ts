import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { appendFile, chmod, copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, delimiter, dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { expect, test as base } from 'e2e';

export class Installed {
  readonly env: NodeJS.ProcessEnv;
  readonly project: string;
  // Host programs this machine has installed, first on PATH.
  readonly bin: string;

  constructor(readonly root: string) {
    this.project = join(root, 'project');
    this.bin = join(root, 'bin');
    this.env = Object.fromEntries(['PATH', 'PATHEXT', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PSModulePath']
      .filter(name => process.env[name]).map(name => [name, process.env[name]]));
    Object.assign(this.env, {
      HOME: join(root, 'profile'), USERPROFILE: join(root, 'profile'),
      APPDATA: join(root, 'profile', 'AppData', 'Roaming'), LOCALAPPDATA: join(root, 'profile', 'AppData', 'Local'),
      CODEX_HOME: join(root, 'codex'), CLAUDE_CONFIG_DIR: join(root, 'claude'),
      TEMP: join(root, 'tmp'), TMP: join(root, 'tmp'), npm_config_cache: join(root, 'npm-cache'),
      SYMPP_HOME: join(root, 'runtime'), SYMPP_DATABASE: join(root, 'runtime', 'ledger.sqlite3'),
      SYMPP_RUNTIME_FILE: join(root, 'runtime', 'runtime.json'), SYMPP_OPEN_DASHBOARD: '0',
      DISABLE_TELEMETRY: '1', DO_NOT_TRACK: '1',
    });
    if (process.platform !== 'win32') this.env.PATH = `${this.bin}${delimiter}${this.env.PATH}`;
  }

  async prepare() {
    for (const path of [this.project, this.bin, this.env.HOME!, this.env.TEMP!, this.env.CLAUDE_CONFIG_DIR!]) await mkdir(path, { recursive: true });
  }

  // Puts a host program on this machine's PATH: a script file or a Node module.
  async program(name: string, body: string | { module: string }) {
    const file = join(this.bin, name);
    if (typeof body === 'string') await writeFile(file, body);
    else await copyFile(resolve(body.module), file);
    await chmod(file, 0o755);
  }

  async run(command: string, args: string[], cwd = this.project, env = this.env) {
    const receipt = join('.e2e', `${basename(this.root)}-commands.jsonl`);
    await appendFile(receipt, JSON.stringify({ phase: 'request', command, args, cwd }) + '\n');
    const result = await new Promise<{ code: number | null; stdout: string; stderr: string }>((resolveResult, reject) => {
      const child = spawn(command, args, { cwd, env, windowsHide: true, timeout: 180_000, stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '', stderr = '';
      child.stdout.on('data', chunk => { stdout += chunk; });
      child.stderr.on('data', chunk => { stderr += chunk; });
      child.on('error', reject);
      child.on('close', code => resolveResult({ code, stdout: stdout.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, ''), stderr }));
    }).catch(async error => {
      await appendFile(receipt, JSON.stringify({ phase: 'failure', error: String(error) }) + '\n');
      throw error;
    });
    await appendFile(receipt, JSON.stringify({ phase: 'response', ...result }) + '\n');
    return result;
  }

  async ok(command: string, args: string[], cwd = this.project, env = this.env) {
    const result = await this.run(command, args, cwd, env);
    expect(result.code, `${command}: ${result.stdout}\n${result.stderr}`).toBe(0);
    return result.stdout;
  }

  skills(args: string[], cwd = this.project) {
    const npm = process.platform === 'win32' ? dirname(process.execPath) : resolve(dirname(process.execPath), '../lib');
    return this.ok(process.execPath, [join(npm, 'node_modules/npm/bin/npx-cli.js'),
      '--yes', 'skills@1.7.0', ...args], cwd);
  }

  async install(agent: 'codex' | 'claude-code', source = resolve('.'), copy = false) {
    await this.skills(['add', source, '-g', '--agent', agent, '--skill', 'sympp', '--yes', ...(copy ? ['--copy'] : [])]);
    return realpath(agent === 'codex'
      ? join(this.env.HOME!, '.agents/skills/sympp')
      : join(this.env.CLAUDE_CONFIG_DIR!, 'skills/sympp'));
  }

  setup(bundle: string, host = 'both', ...args: string[]) {
    return this.run(process.execPath, [join(bundle, 'scripts/setup-sympp.js'), '--host', host, ...args]);
  }

  // The sympp server Codex would start from its registration in config.toml.
  async codexRegistration() {
    const config = await readFile(join(this.env.CODEX_HOME!, 'config.toml'), 'utf8');
    const start = config.indexOf('# BEGIN sympp Skills MCP\n[mcp_servers.sympp]\n');
    const block = config.slice(start, config.indexOf('# END sympp Skills MCP', start));
    const value = (key: string) => JSON.parse(block.match(new RegExp(`^${key} = (.+)$`, 'm'))![1]);
    const env = Object.fromEntries([...block.slice(block.indexOf('[mcp_servers.sympp.env]')).matchAll(/^(\w+) = (".*")$/gm)]
      .map(([, key, text]) => [key, JSON.parse(text)]));
    return { command: value('command') as string, args: value('args') as string[], forwarded: value('env_vars') as string[], env };
  }
}

// An MCP server process speaking newline-delimited JSON-RPC over STDIO, as an agent host runs it.
export class Stdio {
  readonly process: ChildProcessWithoutNullStreams;
  stderr = '';
  private sequence = 0;
  private pending = new Map<number, (response: any) => void>();

  constructor(command: string, args: string[], env: NodeJS.ProcessEnv, cwd: string) {
    this.process = spawn(command, args, { env, cwd, windowsHide: true, stdio: 'pipe' });
    this.process.stderr.on('data', (chunk) => { this.stderr += chunk; });
    createInterface({ input: this.process.stdout }).on('line', (line) => {
      const response = JSON.parse(line);
      this.pending.get(response.id)?.(response);
      this.pending.delete(response.id);
    });
  }

  request(method: string, params: object = {}) {
    const id = ++this.sequence;
    return new Promise<any>((resolveResponse, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out: ${this.stderr}`)), 60_000);
      this.pending.set(id, (response) => { clearTimeout(timer); resolveResponse(response); });
      this.process.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }

  async call(name: string, args: object = {}) {
    const response = await this.request('tools/call', { name, arguments: args });
    expect(response.error, `${name}: ${JSON.stringify(response.error)}`).toBeUndefined();
    expect(response.result.isError, JSON.stringify(response.result)).not.toBe(true);
    return response.result.structuredContent;
  }

  async close() {
    if (this.process.exitCode !== null) return this.process.exitCode;
    const exited = new Promise<number | null>((resolveExit) => this.process.once('exit', resolveExit));
    this.process.stdin.end();
    const timer = setTimeout(() => this.process.kill('SIGKILL'), 10_000);
    try { return await exited; } finally { clearTimeout(timer); }
  }
}

export const test = base.extend<{ installed: Installed }>({
  installed: async ({}, use) => {
    const root = await mkdtemp(join(tmpdir(), 'sympp-installed-'));
    await mkdir('.e2e', { recursive: true });
    const installed = new Installed(root);
    try { await installed.prepare(); await use(installed); } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
});
