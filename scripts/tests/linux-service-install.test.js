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
