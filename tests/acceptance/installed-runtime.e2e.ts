import { cp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { expect } from 'e2e';
import { Stdio, test } from '../support/installed-runtime.js';
import { contract, Factory } from '../support/factory.js';
import { GitHttp } from '../support/git-http.js';
import { git, repository } from '../support/worktree-git.js';

// Required Windows gate. A1 separately proves native host consumption of setup's
// exact generated command; this journey never substitutes a direct Node launch.
if (process.env.SYMPP_INSTALLED_ACCEPTANCE === '1') {
  test('Skills installation, refresh and relocated copy preserve usable native registration and unrelated ownership', { timeout: 600_000 }, async ({ installed }) => {
    expect(process.platform).toBe('win32');
    expect(await installed.skills(['add', resolve('.'), '--list'])).toContain('sympp');
    const bundle = await installed.install('codex');
    installed.env.SYMPP_BACKEND_PORT = '21345';
    const claudeFile = join(installed.env.CLAUDE_CONFIG_DIR!, '.claude.json');
    await writeFile(claudeFile, JSON.stringify({ other: true, mcpServers: { notes: { command: 'notes.exe' } } }));
    expect(existsSync(installed.env.CODEX_HOME!)).toBe(false);
    expect((await installed.setup(bundle)).code).toBe(0);
    const configFile = join(installed.env.CODEX_HOME!, 'config.toml');
    const unrelated = 'model = "example-model"\n';
    await writeFile(configFile, unrelated + await readFile(configFile, 'utf8'));
    const config = await readFile(configFile, 'utf8');
    const claude = await readFile(claudeFile, 'utf8');
    const invalid = await installed.run(process.execPath, [join(bundle, 'scripts/setup-sympp.js'), '--hos', 'codex']);
    expect(invalid.code).toBe(2);
    expect(await readFile(configFile, 'utf8')).toBe(config);
    expect(await readFile(claudeFile, 'utf8')).toBe(claude);
    expect(JSON.parse(claude).mcpServers.notes.command).toBe('notes.exe');
    expect(JSON.parse(claude).other).toBe(true);
    expect((await installed.setup(bundle)).code).toBe(0);
    expect(await readFile(configFile, 'utf8')).toBe(config);
    expect(await readFile(claudeFile, 'utf8')).toBe(claude);
    const registration = JSON.parse(await installed.ok('codex.exe', ['mcp', 'get', 'sympp', '--json']));
    expect(registration.transport.env.SYMPP_DATABASE).toBe(installed.env.SYMPP_DATABASE);
    expect(registration.transport.env.SYMPP_HOME).toBe(installed.env.SYMPP_HOME);
    expect(registration.transport.env.SYMPP_RUNTIME_FILE).toBe(installed.env.SYMPP_RUNTIME_FILE);
    expect(registration.transport.env.SYMPP_BACKEND_PORT).toBe('21345');
    expect(registration.transport.env.SYMPP_RUNTIME_CHANNEL).toBe('stable');

    // A project registration from before the rename is removed, and a project sympp entry is named as taking precedence.
    const projectMcp = join(installed.project, '.mcp.json');
    await writeFile(projectMcp, JSON.stringify({ mcpServers: { symphony_plus_plus: { command: 'old', env: { SYMPP_SKILLS_MANAGED: '1' } }, notes: { command: 'notes' } } }));
    const migrated = await installed.setup(bundle);
    expect(migrated.code).toBe(0);
    expect(migrated.stdout).toContain('takes precedence');
    expect(JSON.parse(await readFile(projectMcp, 'utf8')).mcpServers).toEqual({ notes: { command: 'notes' } });
    await rm(projectMcp);

    // A saved install must still run setup after the original is refreshed.
    const saved = join(installed.root, 'saved skill');
    await cp(bundle, saved, { recursive: true });
    await writeFile(join(bundle, 'scripts/setup-sympp.js'), 'process.exit(91);\n');
    expect((await installed.setup(bundle)).code).toBe(91);
    await installed.install('codex');
    expect((await installed.setup(bundle)).code).toBe(0);
    const copied = await installed.install('claude-code', saved, true);
    expect((await installed.setup(copied)).code).toBe(0);
    const moved = JSON.parse(await installed.ok('codex.exe', ['mcp', 'get', 'sympp', '--json']));
    expect(moved.transport.args).toContain(join(copied, 'scripts/start-sympp-mcp-bridge.js'));
    expect((await readFile(configFile, 'utf8')).startsWith(unrelated)).toBe(true);
    expect((await installed.setup(bundle)).code).toBe(0);
    const restored = JSON.parse(await installed.ok('codex.exe', ['mcp', 'get', 'sympp', '--json']));
    expect(restored.transport.args).toContain(join(bundle, 'scripts/start-sympp-mcp-bridge.js'));

    const foreignConfig = '[mcp_servers.sympp]\ncommand = "unrelated-owner.exe"\n';
    await writeFile(configFile, foreignConfig);
    const beforeClaude = await readFile(claudeFile, 'utf8');
    const refused = await installed.setup(copied);
    expect(refused.code).toBe(1);
    expect(refused.stdout).toContain('unmanaged sympp MCP registration');
    expect(await readFile(configFile, 'utf8')).toBe(foreignConfig);
    expect(await readFile(claudeFile, 'utf8')).toBe(beforeClaude);

    const inline = 'mcp_servers = { notes = { command = "notes.exe" } }\n';
    await writeFile(configFile, inline);
    const inlineRefused = await installed.setup(copied);
    expect(inlineRefused.code).toBe(1);
    expect(inlineRefused.stdout).toContain('inline MCP table');
    expect(await readFile(configFile, 'utf8')).toBe(inline);
    expect(await readFile(claudeFile, 'utf8')).toBe(beforeClaude);

    await writeFile(configFile, config);
    const foreignClaude = JSON.stringify({ mcpServers: { sympp: { command: 'unrelated-owner.exe' } } });
    await writeFile(claudeFile, foreignClaude);
    expect((await installed.setup(copied)).code).toBe(1);
    expect(await readFile(configFile, 'utf8')).toBe(config);
    expect(await readFile(claudeFile, 'utf8')).toBe(foreignClaude);
    expect(existsSync(installed.env.SYMPP_DATABASE!)).toBe(false);
    await installed.skills(['remove', 'sympp', '-g', '--yes']);
    expect(JSON.parse(await installed.skills(['list', '-g', '--json']))).toEqual([]);
  });

}

// Linux and macOS clients connect to a factory; local setup is Windows only.
if (process.platform !== 'win32') {
  test('Skills install and remote setup register a bridge that takes a request from the person\'s checkout to a worker terminal', { timeout: 300_000 }, async ({ installed }) => {
    const { root, env } = installed;
    // The factory clones its repositories from a Git remote. The person works in a checkout of it.
    const service = await repository(root, 'service');
    const remotes = new GitHttp(root);
    const gitHost = await remotes.start();
    const repos = join(root, 'factory repos');
    const factory = new Factory(root, undefined, { env: { SYMPP_REPOS_ROOT: repos } });
    try {
      const server = new URL(await factory.endpoint).origin;
      const remote = `${gitHost}/service.git`;
      await git(root, service.checkout, 'remote', 'set-url', 'origin', `${gitHost.replace('//', '//person@')}/service.git`);

      // This machine has Codex, Herdr-app with a personal desk, and a herdr-core for its agents.
      await installed.program('codex', '#!/bin/sh\nexit 0\n');
      await installed.program('hc', { module: 'tests/support/herdr-terminals.mjs' });
      await installed.program('herdr-app', '#!/bin/sh\ncase "$1" in --version) echo acceptance ;; check) test ! -e "$HERDR_APP_HOME/refuse-check" ;; *) exit 1 ;; esac\n');
      await installed.program(process.platform === 'darwin' ? 'open' : 'xdg-open', `#!/bin/sh\nprintf '%s' "$1" > ${JSON.stringify(join(root, 'opened'))}\n`);
      env.HERDR_APP_HOME = join(root, 'herdr');
      const layout = '{"id":"root","children":[{"content":{"terminal":"t5"}}]}\n';
      const topics = { 'desk.topics': { groups: [{ id: 'my-topic', spaces: ['s1'] }] } };
      await mkdir(join(env.HERDR_APP_HOME, 'layouts'), { recursive: true });
      await writeFile(join(env.HERDR_APP_HOME, 'layouts/personal.json'), layout);
      await writeFile(join(env.HERDR_APP_HOME, 'shared.json'), JSON.stringify(topics));
      const core = join(root, 'herdr-core.json');
      await writeFile(core, JSON.stringify({ core: { id: 'desk-core', name: 'desk' }, calls: [], terminals: { t1: { state: 'live', pid: 4242, labels: {} } } }));

      // Codex settings, an inert example of a sympp block and a registration from before the rename stay the person's.
      const configFile = join(env.CODEX_HOME!, 'config.toml');
      const settings = 'model = "example-model"\ninstructions = \'\'\'\n[mcp_servers.sympp]\n# BEGIN sympp Skills MCP\nexample\n# END sympp Skills MCP\n\'\'\'\n';
      await mkdir(env.CODEX_HOME!, { recursive: true });
      await writeFile(configFile, settings + '\n# BEGIN Symphony++ Skills MCP\n[mcp_servers.symphony_plus_plus]\ncommand = "old"\n# END Symphony++ Skills MCP\n');

      const bundle = await installed.install('codex');
      // A server is an SSH alias or this machine's loopback; nothing else reaches ssh or the config.
      const original = await readFile(configFile, 'utf8');
      for (const [value, refusal] of [['-oProxyCommand=touch owned', 'SSH host alias or an HTTP loopback origin'], ['http://192.0.2.1:19998', 'Use an SSH host alias']]) {
        const rejected = await installed.setup(bundle, 'codex', '--server', value);
        expect([rejected.code, rejected.stdout.includes(refusal)]).toEqual([1, true]);
      }
      expect(await readFile(configFile, 'utf8')).toBe(original);
      const first = await installed.setup(bundle, 'codex', '--server', server);
      expect(first.code, first.stdout + first.stderr).toBe(0);
      for (const line of ['codex: "configured"', 'herdr: "configured"', 'channel: "remote"']) expect(first.stdout).toContain(line);
      const config = await readFile(configFile, 'utf8');
      expect(config.startsWith(settings)).toBe(true);
      expect(config).not.toContain('symphony_plus_plus');
      expect(config.match(/^\[mcp_servers\.sympp\]$/gm)).toHaveLength(2);
      const registration = await installed.codexRegistration();
      expect(registration.args).toEqual([join(bundle, 'scripts/start-sympp-mcp-bridge.js')]);
      expect(registration.forwarded).toEqual(['HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET']);
      expect(registration.env.SYMPP_SERVER_URL).toBe(server);
      expect(registration.env.SYMPP_DATABASE).toBeUndefined();
      expect(await readFile(registration.env.SYMPP_SERVER_TOKEN_FILE, 'utf8')).toBe('');
      expect((await stat(registration.env.SYMPP_SERVER_TOKEN_FILE)).mode & 0o777).toBe(0o600);
      expect(await readFile(join(env.HERDR_APP_HOME, 'layouts/personal.json'), 'utf8')).toBe(layout);
      const shared = JSON.parse(await readFile(join(env.HERDR_APP_HOME, 'shared.json'), 'utf8'));
      expect(shared['sympp.connection'].endpoint).toBe(server);
      expect(shared['desk.topics']).toEqual(topics['desk.topics']);

      // Setup again changes nothing; a lost END marker is repaired without taking the person's next table.
      const again = await installed.setup(bundle, 'codex', '--server', server);
      expect(again.stdout).toContain('codex: "already configured"');
      expect(await readFile(configFile, 'utf8')).toBe(config);
      const userTable = '\n# keep this table\n[profiles.custom]\nmodel = "custom"\n';
      const end = config.lastIndexOf('# END sympp Skills MCP\n');
      await writeFile(configFile, config.slice(0, end).trimEnd() + '\n' + userTable);
      expect((await installed.setup(bundle, 'codex', '--server', server)).code).toBe(0);
      expect(await readFile(configFile, 'utf8')).toBe(config.trimEnd() + '\n' + userTable);

      // A panel that fails Herdr's check is rolled back with the person's own edit and connection.
      const panel = join(env.HERDR_APP_HOME, 'mods/sympp/main.js');
      await writeFile(panel, '// my edit\n');
      await writeFile(join(env.HERDR_APP_HOME, 'refuse-check'), '');
      const sharedBefore = await readFile(join(env.HERDR_APP_HOME, 'shared.json'), 'utf8');
      const refused = await installed.setup(bundle, 'codex', '--server', server);
      expect(refused.code).toBe(1);
      expect(refused.stdout).toContain('Herdr panel setup failed');
      expect(await readFile(panel, 'utf8')).toBe('// my edit\n');
      expect(await readFile(join(env.HERDR_APP_HOME, 'shared.json'), 'utf8')).toBe(sharedBefore);
      await rm(join(env.HERDR_APP_HOME, 'refuse-check'));

      // The installed command reaches the factory and opens its board.
      const command = join(env.HOME!, '.local/bin/sympp');
      expect(await installed.ok(command, ['status'])).toContain('answers: true');
      expect(await installed.ok(command, ['board'])).toContain('board: opened');
      expect(await readFile(join(root, 'opened'), 'utf8')).toBe(`${server}/sympp/board`);

      // Codex starts the registered server in the person's Herdr terminal, inside their checkout.
      const agent = (terminal: string) => ({ PATH: env.PATH, HOME: env.HOME, ...registration.env, HC_TERMINAL_ID: terminal, HC_TERMINAL_SOCKET: core });
      const chief = new Stdio(registration.command, registration.args, agent('t1'), service.checkout);
      const initialized = await chief.request('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'codex', version: 'acceptance' } });
      expect(initialized.result.protocolVersion).toBe('2025-03-26');
      const health = await chief.call('sympp.health');
      expect([health.status, health.source.revision, health.factory_owned_worktrees]).toEqual(['ok', process.env.ACCEPTANCE_CHECKOUT_SHA, true]);
      const ask = { repo: '.', base_branch: 'beta', title: 'Installed service change', description: 'Synthetic acceptance request.', work_type: 'feature' };

      // A checkout whose origin carries a password, however it is spelled, never reaches the factory.
      for (const credential of ['person:private-pass', 'person%3Aprivate-pass']) {
        await git(root, service.checkout, 'remote', 'set-url', 'origin', `${gitHost.replace('//', `//${credential}@`)}/service.git`);
        const leaked = await chief.request('tools/call', { name: 'create_work_request', arguments: ask });
        expect(leaked.error.data.detail).toContain('Repository origins must not include credentials');
        expect(JSON.stringify(leaked)).not.toContain('private-pass');
      }
      expect((await chief.call('list_work_requests')).work_requests).toEqual([]);
      await git(root, service.checkout, 'remote', 'set-url', 'origin', `${gitHost.replace('//', '//person@')}/service.git`);

      // The factory records the request against the remote, owned by this terminal.
      const created = await chief.call('create_work_request', ask);
      expect(created.worked_on.address).toBe('desk/t1');
      const request = created.work_request.id;
      expect((await chief.call('read_work_request', { work_request_id: request })).work_request.repo).toBe(remote);
      const planned = await chief.call('edit_plan', { work_request_id: request, ops: [{ op: 'add_package', ...contract('Installed change', { branch_pattern: 'feature/installed' }) }] });
      const wp = planned.applied[0].work_package_id;

      // Dispatch prepares a factory-owned worktree from its own clone; the launch line starts the worker.
      const dispatched = await chief.call('dispatch_work_package', { work_package_id: wp, review_mode: 'none' });
      const worktree = dispatched.worktree.path;
      expect(worktree.startsWith(repos)).toBe(true);
      expect(await git(root, worktree, 'branch', '--show-current')).toBe('feature/installed');
      expect(await git(root, worktree, 'rev-parse', 'HEAD')).toBe(await git(root, service.checkout, 'rev-parse', 'beta'));
      expect(await installed.ok('sh', ['-c', dispatched.launch_line], root, { ...env, HC_SOCKET: core })).toBe('t2\n');
      const launched = JSON.parse(await readFile(core, 'utf8')).terminals.t2;
      expect([launched.cwd, launched.name, launched.labels['sympp.role'], launched.labels['sympp.work_package_id']]).toEqual([worktree, wp, 'worker', wp]);
      expect(launched.argv).toEqual(['codex', `Read ${dispatched.assignment_file}`]);

      // The worker's own sympp server has no tools and refuses calls without reaching the factory.
      const worker = new Stdio(registration.command, registration.args, agent('t2'), worktree);
      expect((await worker.request('tools/list')).result.tools).toEqual([]);
      const refusedCall = await worker.request('tools/call', { name: 'create_work_request', arguments: { ...ask, repo: remote } });
      expect(refusedCall.error.data.reason).toBe('worker_terminal');
      expect((await chief.call('list_work_requests')).work_requests.map((row: any) => row.id)).toEqual([request]);
      expect(await worker.close()).toBe(0);
      expect(await chief.close()).toBe(0);
    } finally {
      await factory.stop();
      await remotes.stop();
    }
  });

  test('the installed task launcher starts an ordinary task in Herdr once, trusting only its folder and copying no credentials', async ({ installed }) => {
    const { root, env, project } = installed;
    const bundle = await installed.install('codex');
    const core = join(root, 'herdr-core.json');
    await writeFile(core, JSON.stringify({ core: { id: 'desk-core', name: 'desk' }, calls: [], terminals: {} }));
    const state = async () => JSON.parse(await readFile(core, 'utf8'));
    const change = async (edit: (value: any) => void) => { const value = await state(); edit(value); await writeFile(core, JSON.stringify(value)); };
    await installed.program('hc', { module: 'tests/support/herdr-terminals.mjs' });
    await installed.program('codex', { module: 'tests/support/codex-config.cjs' });
    for (const provider of ['claude', 'opencode']) await installed.program(provider, '#!/bin/sh\nexit 0\n');
    const launcher = { ...env, HC_SOCKET: core, OPENAI_API_KEY: 'controlled-secret-never-copy' };
    const helper = async (...args: string[]) => {
      const result = await installed.run(process.execPath, [join(bundle, 'scripts/sympp-herdr.js'), ...args, '--json'], project, launcher);
      expect(result.stderr).toBe('');
      return JSON.parse(result.stdout);
    };
    const task = join(root, 'task with spaces.txt');
    await writeFile(task, 'Repair the specified fixture, then report evidence.');

    // Claude trusts exactly this folder in the chosen profile and keeps everything else in it.
    const profile = join(root, 'claude profile');
    await mkdir(profile);
    const before = { unknown: { keep: true }, projects: { [project]: { hasTrustDialogAccepted: false, allowedTools: ['keep'] }, sibling: { hasTrustDialogAccepted: false } } };
    await writeFile(join(profile, '.claude.json'), JSON.stringify(before));
    const claude = ['launch', '--provider', 'claude', '--model', 'opus', '--task', task, '--cwd', project, '--provider-home', profile];
    const launched = await helper(...claude);
    expect(launched.workspace_trust).toEqual({ trusted: true, changed: true, reason: 'launch_authorized' });
    const trusted = structuredClone(before);
    trusted.projects[project].hasTrustDialogAccepted = true;
    expect(JSON.parse(await readFile(join(profile, '.claude.json'), 'utf8'))).toEqual(trusted);
    const started = (await state()).terminals.t1;
    expect([started.name, started.cwd, started.env.CLAUDE_CONFIG_DIR, started.env.OPENAI_API_KEY]).toEqual(['repair-the-specified-claude', project, profile, undefined]);
    expect(started.argv.at(-1)).toContain(JSON.stringify(task));
    expect(started.argv.join(' ')).not.toContain('Repair the specified');

    // The same launch again is the same agent; a follow-up reaches it while it is idle.
    const again = await helper(...claude);
    expect([again.reused, again.receipt]).toEqual([true, launched.receipt]);
    expect(Object.keys((await state()).terminals)).toEqual(['t1']);
    expect((await helper('check', '--receipt', launched.receipt)).state).toBe('live');
    const followUp = join(root, 'follow-up.txt');
    await writeFile(followUp, 'Also update the changelog.');
    expect((await helper('send', '--receipt', launched.receipt, '--message', followUp)).started).toBe(true);
    expect((await state()).terminals.t1.sent).toEqual(['Also update the changelog.']);

    // Once the agent's process is replaced by a shell, nothing types into it.
    await change((value) => { value.terminals.t1.pid += 1; value.terminals.t1.status = null; });
    expect((await helper('check', '--receipt', launched.receipt)).reason).toBe('process_changed');
    expect((await helper('send', '--receipt', launched.receipt, '--message', followUp)).error).toBe('agent_not_ready');
    expect((await state()).terminals.t1.sent).toHaveLength(1);

    // An unreadable Claude config is left alone and starts no agent.
    await mkdir(env.CLAUDE_CONFIG_DIR!, { recursive: true });
    await writeFile(join(env.CLAUDE_CONFIG_DIR!, '.claude.json'), '{broken');
    expect((await helper('launch', '--provider', 'claude', '--task', task, '--cwd', project, '--attempt', 'unreadable')).error).toBe('operation_failed');
    expect(await readFile(join(env.CLAUDE_CONFIG_DIR!, '.claude.json'), 'utf8')).toBe('{broken');
    expect(Object.keys((await state()).terminals)).toEqual(['t1']);

    // Codex trust goes through its own config API, and a concurrent edit stops the launch.
    const codexState = join(env.CODEX_HOME!, 'peer.json');
    await mkdir(env.CODEX_HOME!, { recursive: true });
    const codexBefore = { config: { model: 'keep', projects: { [project]: { trust_level: 'untrusted', keep: true } } }, version: 'first' };
    await writeFile(codexState, JSON.stringify(codexBefore));
    expect((await helper('launch', '--provider', 'codex', '--task', task, '--cwd', project, '--attempt', 'codex')).workspace_trust.trusted).toBe(true);
    const codex = JSON.parse(await readFile(codexState, 'utf8'));
    expect([codex.config.model, codex.config.projects[project], codex.credential_present]).toEqual(['keep', { trust_level: 'trusted', keep: true }, false]);
    await writeFile(codexState, JSON.stringify({ ...codexBefore, concurrent_update: true }));
    expect((await helper('launch', '--provider', 'codex', '--task', task, '--cwd', project, '--attempt', 'conflict')).error).toBe('workspace_trust_failed');
    expect(Object.keys((await state()).terminals)).toHaveLength(2);

    // A title that looks like a credential is not shown, and a lost reply never starts the task twice.
    await writeFile(task, 'token=controlled-private-value');
    await change((value) => { value.lose_reply = true; });
    const opencode = ['launch', '--provider', 'opencode', '--task', task, '--cwd', project, '--attempt', 'opencode'];
    expect((await helper(...opencode)).error).toBe('core_unreachable');
    await change((value) => { value.lose_reply = false; });
    expect((await helper(...opencode)).error).toBe('launch_uncertain');
    const terminals = Object.values((await state()).terminals) as any[];
    expect(terminals.map((terminal) => terminal.name)).toEqual(['repair-the-specified-claude', 'repair-the-specified-codex', 'task-opencode']);
  });
}

