"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

test('board opens the saved factory with a private fragment and never logs its credential', { skip: process.platform !== 'linux' }, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sympp-board-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin'), config = path.join(root, '.local/share/sympp/connection.json');
  fs.mkdirSync(bin); fs.mkdirSync(path.dirname(config), { recursive: true });
  const token = require('node:crypto').randomBytes(32).toString('base64url');
  const tokenFile = path.join(root, 'token'), receipt = path.join(root, 'opened');
  fs.writeFileSync(tokenFile, token, { mode: 0o600 });
  const code = require('node:crypto').randomBytes(32).toString('base64url');
  let authorization;
  const server = require('node:http').createServer((request, response) => {
    authorization = request.headers.authorization;
    assert.equal(request.method, 'POST'); assert.equal(request.url, '/api/v1/sympp/board-sign-in-code');
    response.setHeader('content-type', 'application/json'); response.end(JSON.stringify({ code }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const endpoint = `http://127.0.0.1:${server.address().port}`;
  fs.writeFileSync(config, JSON.stringify({ env: { SYMPP_SERVER_URL: endpoint, SYMPP_SERVER_TOKEN_FILE: tokenFile } }));
  fs.writeFileSync(path.join(bin, 'xdg-open'), '#!/bin/sh\nprintf "%s" "$1" > "$RECEIPT"\n', { mode: 0o755 });
  const result = await require('node:util').promisify(require('node:child_process').execFile)(process.execPath, [path.resolve(__dirname, '../../packages/sympp/scripts/sympp-command.js'), 'board'], {
    env: { ...process.env, HOME: root, PATH: bin + path.delimiter + process.env.PATH, RECEIPT: receipt }, encoding: 'utf8',
  });
  assert.equal(authorization, `Bearer ${token}`);
  const url = new URL(fs.readFileSync(receipt, 'utf8'));
  assert.equal(url.origin, endpoint); assert.equal(url.pathname, '/sympp/board'); assert.equal(url.search, '');
  assert.equal(new URLSearchParams(url.hash.slice(1)).get('sympp-code'), code);
  assert.equal(result.stdout.includes(token) || result.stderr.includes(token), false);
  fs.writeFileSync(tokenFile, ''); // Loopback setup saves an empty token file.
  authorization = null;
  await require('node:util').promisify(require('node:child_process').execFile)(process.execPath, [path.resolve(__dirname, '../../packages/sympp/scripts/sympp-command.js'), 'board'], {
    env: { ...process.env, HOME: root, PATH: bin + path.delimiter + process.env.PATH, RECEIPT: receipt }, encoding: 'utf8',
  });
  assert.equal(authorization, null);
  assert.equal(new URL(fs.readFileSync(receipt, 'utf8')).hash, '');
});

test('failed activation restores the previous release, unit and readiness settings', { skip: process.platform !== 'linux' }, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sympp-activation-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const server = require('node:http').createServer((request, response) => response.end(JSON.stringify({ status: 'ok', ledger: { reachable: true }, source: { revision: 'previous' } })));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => server.close());
  const repo = path.join(root, 'repo'), bin = path.join(root, 'bin'), home = path.join(root, 'factory');
  const unit = path.join(root, 'config/systemd/user/qa.service');
  for (const directory of ['scripts', 'elixir/_build/prod/rel/symphony_elixir/bin']) fs.mkdirSync(path.join(repo, directory), { recursive: true });
  fs.mkdirSync(bin); fs.mkdirSync(path.dirname(unit), { recursive: true }); fs.mkdirSync(path.join(home, 'service/old'), { recursive: true });
  fs.symlinkSync(path.join(home, 'service/old'), path.join(home, 'service/current'));
  const previousUnit = `Environment="SYMPP_SOURCE_REVISION=previous"\nEnvironment="SYMPP_BACKEND_PORT=${server.address().port}"\nEnvironment="SYMPP_SERVICE_HOST=127.0.0.1"\n`;
  fs.writeFileSync(unit, previousUnit);
  fs.copyFileSync(path.resolve(__dirname, '../install-sympp-checkout.sh'), path.join(repo, 'scripts/install-sympp-checkout.sh'));
  fs.copyFileSync(path.resolve(__dirname, '../install-sympp-linux-runtime.py'), path.join(repo, 'scripts/install-sympp-linux-runtime.py'));
  for (const args of [['init', '-b', 'main'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.test'], ['add', '.'], ['commit', '-qm', 'candidate']]) assert.equal(spawnSync('git', args, { cwd: repo }).status, 0);
  fs.writeFileSync(path.join(bin, 'mise'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'systemctl'), '#!/bin/sh\ncase "$*" in *link*) exit 42;; *MainPID*) printf "%s\\n" "$LISTENER_PID";; *) exit 0;; esac\n', { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'ss'), '#!/bin/sh\nprintf "LISTEN 0 128 127.0.0.1:%s *:* users:(pid=%s,fd=1)\\n" "$OLD_PORT" "$LISTENER_PID"\n', { mode: 0o755 });
  const env = { ...process.env, PATH: bin + path.delimiter + process.env.PATH, XDG_RUNTIME_DIR: root, XDG_CONFIG_HOME: path.join(root, 'config'), SYMPP_HOME: home, SYMPP_REPOS_ROOT: root, SYMPP_SERVICE_NAME: 'qa', SYMPP_SERVICE_HOST: '192.0.2.1', SYMPP_BACKEND_PORT: '1', LISTENER_PID: String(process.pid), OLD_PORT: String(server.address().port) };
  const exec = require('node:util').promisify(require('node:child_process').execFile);
  await assert.rejects(exec('bash', [path.join(repo, 'scripts/install-sympp-checkout.sh')], { env }), error => {
    assert.equal(error.code, 1); assert.match(error.stderr, /previous release restored and ready/); return true;
  });
  assert.equal(fs.readlinkSync(path.join(home, 'service/current')), path.join(home, 'service/old'));
  assert.equal(fs.readFileSync(unit, 'utf8'), previousUnit);
});

test('update streams factory phases, installs an exact CI runtime, and builds on a miss', { skip: process.platform !== 'linux', timeout: 30000 }, async t => {
  const { spawn } = require('node:child_process');
  const crypto = require('node:crypto');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sympp-update-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const repo = path.join(root, 'repo'), bin = path.join(root, 'bin'), home = path.join(root, 'factory');
  const config = path.join(root, 'config/systemd/user/qa.service');
  const runtime = path.join(repo, 'elixir/_build/prod/rel/symphony_elixir');
  for (const directory of [bin, path.dirname(config), runtime + '/bin', repo + '/scripts', repo + '/packages/sympp', repo + '/elixir/priv/symphony_plus_plus']) fs.mkdirSync(directory, { recursive: true });
  for (const file of ['install-sympp-checkout.sh', 'install-sympp-linux-runtime.py']) fs.copyFileSync(path.resolve(__dirname, '..', file), path.join(repo, 'scripts', file));
  for (const file of ['packages/sympp/package.json', 'elixir/priv/symphony_plus_plus/mcp_contract.json']) fs.copyFileSync(path.resolve(__dirname, '../..', file), path.join(repo, file));
  fs.writeFileSync(runtime + '/bin/symphony_elixir', 'source release');
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); return result.stdout.trim();
  };
  git('init', '-b', 'main'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.test');
  git('add', '.'); git('commit', '-qm', 'candidate');
  const revision = git('rev-parse', 'HEAD');
  git('remote', 'add', 'origin', repo);
  const state = path.join(root, 'revision'); fs.writeFileSync(state, 'previous');
  let artifactAvailable = true, corrupt = false;
  const server = require('node:http').createServer((request, response) => {
    if (request.url === '/mcp/readiness') return response.end(JSON.stringify({ status: 'ok', ledger: { reachable: true }, source: { revision: fs.readFileSync(state, 'utf8') } }));
    if (!artifactAvailable) { response.statusCode = 404; return response.end(); }
    const file = request.url.endsWith('.zip') ? archive : manifestFile;
    response.end(corrupt && request.url.endsWith('.zip') ? 'corrupt' : fs.readFileSync(file));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => server.close());
  const port = String(server.address().port), archive = path.join(root, 'runtime.zip'), manifestFile = path.join(root, 'runtime.json');
  const dashboard = '<main>CI runtime</main>';
  const hash = value => crypto.createHash('sha256').update(value).digest('hex');
  const payload = {
    source_revision: revision, platform: 'linux-x64', plugin: JSON.parse(fs.readFileSync(repo + '/packages/sympp/package.json')),
    launcher_contract: { mcp_contract_fingerprint: JSON.parse(fs.readFileSync(repo + '/elixir/priv/symphony_plus_plus/mcp_contract.json')).mcp_contract_fingerprint },
    backend: { kind: 'mix_release' }, dashboard: { relative_path: 'dashboard-static', fingerprint: hash('index.html ' + hash(dashboard)) },
  };
  const payloadFile = path.join(root, 'payload.json'); fs.writeFileSync(payloadFile, JSON.stringify(payload));
  const zipped = spawnSync('python3', ['-c', 'import sys,zipfile\nwith zipfile.ZipFile(sys.argv[1],"w") as z:\n z.write(sys.argv[2],"runtime-manifest.json")\n z.writestr("dashboard-static/index.html",sys.argv[3])\n z.writestr("bin/symphony_elixir","CI release")', archive, payloadFile, dashboard], { encoding: 'utf8' });
  assert.equal(zipped.status, 0, zipped.stderr);
  fs.writeFileSync(manifestFile, JSON.stringify({ ...payload, artifact: { sha256: hash(fs.readFileSync(archive)) }, payload_manifest: { sha256: hash(fs.readFileSync(payloadFile)) } }));
  const settings = {
    SYMPP_HOME: home, SYMPP_DATABASE: home + '/ledger.sqlite3', SYMPP_REPOS_ROOT: root,
    SYMPP_SERVICE_HOST: '127.0.0.1', SYMPP_BACKEND_PORT: port, SYMPP_SERVICE_SOURCE: repo, SYMPP_SERVICE_REF: 'main',
  };
  fs.writeFileSync(config, 'previous unit');
  const environment = Object.entries(settings).map(([key, value]) => key + '=' + value).join(' ');
  const executable = (name, body) => fs.writeFileSync(path.join(bin, name), '#!/bin/sh\n' + body + '\n', { mode: 0o755 });
  executable('systemctl', 'case "$*" in *Environment*) printf "%s\\n" "$SERVICE_ENV";; *FragmentPath*) printf "%s\\n" "$UNIT";; *MainPID*) printf "%s\\n" "$LISTENER_PID";; *restart*) printf "%s" "$REVISION" > "$STATE";; esac');
  executable('ss', 'printf "LISTEN 0 128 127.0.0.1:%s *:* users:(pid=%s,fd=1)\\n" "$PORT" "$LISTENER_PID"');
  executable('mise', 'echo build >> "$BUILD_RECEIPT"; sleep 0.1');
  executable('npx', 'exit 0');
  executable('ssh', 'sleep 0.2; exec bash -s -- qa');
  // Run the public command with a disposable installed bundle and saved setup.
  const bundle = path.join(root, 'bundle'); fs.mkdirSync(bundle);
  for (const file of ['sympp-command.js', 'update-sympp-service.sh']) fs.copyFileSync(path.resolve(__dirname, '../../packages/sympp/scripts', file), path.join(bundle, file));
  fs.writeFileSync(path.join(bundle, 'setup-sympp.js'), '');
  const connection = path.join(root, '.local/share/sympp/connection.json'); fs.mkdirSync(path.dirname(connection), { recursive: true });
  const env = { ...process.env, HOME: root, PATH: bin + path.delimiter + process.env.PATH, XDG_RUNTIME_DIR: root, XDG_CONFIG_HOME: root + '/config', SYMPP_RUNTIME_RELEASE_URL: `http://127.0.0.1:${port}`, SERVICE_ENV: environment, UNIT: config, LISTENER_PID: String(process.pid), PORT: port, STATE: state, REVISION: revision, BUILD_RECEIPT: root + '/builds' };
  for (const mode of ['artifact', 'missing', 'corrupt', 'local']) {
    artifactAvailable = mode !== 'missing'; corrupt = mode === 'corrupt'; fs.writeFileSync(state, 'previous');
    fs.rmSync(root + '/builds', { force: true });
    fs.writeFileSync(connection, JSON.stringify({ env: {}, setup: { server: mode === 'local' ? `http://127.0.0.1:${port}` : 'scratch', hosts: 'codex', cwd: root, remote: { SYMPP_REMOTE_SERVICE: 'qa' } } }));
    const started = performance.now(); let output = '', errors = '', finished = false, sawFetching = false;
    const child = spawn(process.execPath, [bundle + '/sympp-command.js', 'update'], { env });
    child.stdout.on('data', data => { output += data; if (output.includes('factory: fetching main')) { assert.equal(finished, false); sawFetching = true; } });
    child.stderr.on('data', data => { errors += data; });
    // The update must expose fetching before the delayed artifact/build finishes.
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.kill(); reject(new Error('No live fetching progress: ' + output + errors)); }, 10000);
      const observe = () => { if (sawFetching) { clearTimeout(timer); child.stdout.off('data', observe); assert.equal(output.includes('factory: ready'), false); resolve(); } };
      child.stdout.on('data', observe);
      child.on('error', reject);
    });
    const code = await new Promise(resolve => child.on('close', code => { finished = true; resolve(code); }));
    assert.equal(code, 0, output + errors); assert.match(output, /factory: ready \(\d+s\)/);
    const builds = fs.existsSync(root + '/builds');
    assert.equal(builds, mode === 'missing' || mode === 'corrupt');
    assert.match(output, builds ? /factory: building \(no verified CI runtime/ : /factory: installing runtime/);
    assert.equal(fs.readFileSync(home + '/service/current/bin/symphony_elixir', 'utf8'), builds ? 'source release' : 'CI release');
    t.diagnostic(`${mode}: ${Math.round(performance.now() - started)}ms (controlled runtime and build commands)`);
  }
});
