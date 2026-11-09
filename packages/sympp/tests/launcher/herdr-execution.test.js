"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawn } = require("node:child_process");
const net = require("node:net");
const { once } = require("node:events");
const { createReporter } = require("../../scripts/sympp-session-location.js");
const cli = path.resolve(__dirname, "../../scripts/sympp-herdr.js");
const peer = path.join(__dirname, "herdr-execution-peer.js");

test("start detaches pipes, survives preparation exit 4 and reuses the backend", { skip: process.platform !== "win32" }, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp factory start "));
  let backendPid;
  t.after(() => {
    if (backendPid) { try { process.kill(backendPid); } catch (_) { } }
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
  });
  const reservation = net.createServer().listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const plugin = path.join(root, "installed skills");
  fs.mkdirSync(path.join(plugin, "scripts"), { recursive: true });
  fs.copyFileSync(path.resolve(__dirname, "../../scripts/setup-sympp.js"), path.join(plugin, "scripts", "setup-sympp.js"));
  fs.writeFileSync(path.join(root, "skills-lock.json"), JSON.stringify({ skills: { "sympp": { sourceType: "local" } } }));
  const home = path.join(root, "factory home");
  fs.mkdirSync(path.join(home, "runtime"), { recursive: true });
  const runtime = path.join(home, "runtime", "codex-plugin.json");
  const database = path.join(home, "ledger.sqlite3");
  fs.writeFileSync(runtime, JSON.stringify({ plugin_root: plugin, runtime_channel: "stable", publication: { controls: { database } }, artifact: { prepared_release: { configured_workflow: "factory-workflow.md" } }, backend: { port: 1 } }));
  const observed = path.join(root, "observed.json");
  const server = path.join(root, "backend.js");
  const pidFile = path.join(root, "backend.pid");
  fs.writeFileSync(server, `const fs=require('node:fs'); fs.writeFileSync(${JSON.stringify(pidFile)},String(process.pid));
    setTimeout(()=>require('node:http').createServer((req,res)=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify({status:'ok',ledger:{reachable:true,identity:{kind:'sqlite',display_path:${JSON.stringify(database)},default_home:true}}}));}).listen(${port},'127.0.0.1'),300);
    setTimeout(()=>process.exit(),15000);`);
  const ps = value => "'" + value.replaceAll("'", "''") + "'";
  fs.writeFileSync(path.join(plugin, "scripts", "start-sympp-mcp.ps1"), `param([switch]$PrepareRuntimeOnly)
    if (-not $PrepareRuntimeOnly) { exit 9 }
    $e = @{}; Get-ChildItem Env:SYMPP_* | ForEach-Object { $e[$_.Name] = $_.Value }
    $e | ConvertTo-Json | Set-Content -LiteralPath ${ps(observed)}
    $runtime = Get-Content -LiteralPath $env:SYMPP_RUNTIME_FILE -Raw | ConvertFrom-Json
    $runtime.backend.port = ${port}
    $runtime | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:SYMPP_RUNTIME_FILE
    Start-Process -FilePath ${ps(process.execPath)} -ArgumentList ${ps('"' + server + '"')} -WindowStyle Hidden
    exit 4
  `);
  const run = () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cli, "start", "--runtime", runtime], {
      env: { ...process.env, SYMPP_HOME: "wrong", SYMPP_DATABASE: "wrong", SYMPP_RUNTIME_CHANNEL: "wrong", SYMPP_REPO_ROOT: "wrong", SYMPP_BACKEND_URL: "http://wrong" }, windowsHide: true,
    });
    let stdout = "", stderr = "";
    const timeout = setTimeout(() => { child.kill(); reject(new Error("helper or output pipes did not close")); }, 10000);
    child.stdout.on("data", data => { stdout += data; });
    child.stderr.on("data", data => { stderr += data; });
    child.on("error", reject);
    child.on("close", code => { clearTimeout(timeout); resolve({ code, stdout, stderr }); });
  });
  const first = await run();
  assert.equal(first.code, 0, first.stdout + first.stderr);
  assert.equal(first.stderr, "");
  assert.deepEqual(JSON.parse(first.stdout), { ok: true, endpoint: `http://127.0.0.1:${port}`, started: true });
  backendPid = Number(fs.readFileSync(pidFile, "utf8"));
  process.kill(backendPid, 0);
  const env = JSON.parse(fs.readFileSync(observed, "utf8").replace(/^\uFEFF/, ""));
  assert.deepEqual(env, { SYMPP_HOME: home, SYMPP_DATABASE: database, SYMPP_RUNTIME_FILE: runtime, SYMPP_BACKEND_PORT: "1", SYMPP_OPEN_DASHBOARD: "0", SYMPP_SKILLS_MANAGED: "1", SYMPP_RUNTIME_CHANNEL: "stable", SYMPP_WORKFLOW_FILE: "factory-workflow.md" });
  fs.unlinkSync(observed);
  const second = await run();
  assert.equal(second.code, 0, second.stdout);
  assert.deepEqual(JSON.parse(second.stdout), { ok: true, endpoint: `http://127.0.0.1:${port}`, started: false });
  assert.equal(fs.existsSync(observed), false, "healthy factory does not invoke launcher again");
  fs.writeFileSync(runtime, JSON.stringify({ plugin_root: plugin, backend: { port }, publication: { controls: { database: null } } }));
  const defaultLedger = await run();
  assert.equal(defaultLedger.code, 0, defaultLedger.stdout);
  assert.equal(JSON.parse(defaultLedger.stdout).started, false, "default database records remain usable");
  const wrong = { plugin_root: path.join(root, "missing install"), backend: { port }, publication: { controls: { database: path.join(root, "another.sqlite3") } } };
  fs.writeFileSync(runtime, JSON.stringify(wrong));
  const mismatch = await run();
  assert.equal(JSON.parse(mismatch.stdout).error, "launcher_unavailable", "another ledger must not satisfy readiness");
});

async function scenario(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-herdr-"));
  const prior = { ...process.env };
  process.env.SYMPP_HOME = path.join(root, "ledger home");
  process.env.CLAUDE_CONFIG_DIR = path.join(root, "claude home");
  process.env.CODEX_HOME = path.join(root, "codex home");
  process.env.OPENAI_API_KEY = "controlled-secret-never-copy";
  const bin = path.join(root, "provider bin");
  fs.mkdirSync(bin);
  for (const provider of ["codex", "claude", "opencode"]) fs.writeFileSync(path.join(bin, provider + (process.platform === "win32" ? ".cmd" : "")), "controlled executable\n", { mode: 0o755 });
  process.env.PATH = bin + path.delimiter + (process.env.PATH || "");
  delete process.env.HC_TERMINAL_ID;
  delete process.env.HC_TERMINAL_SOCKET;
  const stateFile = path.join(root, "core.json");
  const save = (state) => fs.writeFileSync(stateFile, JSON.stringify(state));
  const state = () => JSON.parse(fs.readFileSync(stateFile, "utf8"));
  save({ core_id: "core-one", calls: [], runs: 0 });
  const task = path.join(root, 'task with spaces.txt');
  fs.writeFileSync(task, "Repair the specified fixture, then report evidence.");
  async function run(args, prelude = "") {
    // Only replace the transport executable; the public parser and process IO run unchanged.
    const entry = prelude + 'const {main,connectCore}=require(process.argv[1]); main(process.argv.slice(4), session=>connectCore(session,process.execPath,[process.argv[2],process.argv[3]]));';
    return new Promise((resolve, reject) => {
      const child = spawn(process.execPath, ["-e", entry, cli, peer, stateFile, ...args, "--json"], { env: process.env, cwd: root, windowsHide: true });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (data) => { stdout += data; });
      child.stderr.on("data", (data) => { stderr += data; });
      child.on("error", reject);
      child.on("exit", (code) => {
        try { assert.equal(stderr, ""); resolve({ code, body: JSON.parse(stdout) }); }
        catch (error) { reject(error); }
      });
    });
  }
  const connect = () => require(cli).connectCore(undefined, process.execPath, [peer, stateFile]);
  try { await fn({ root, task, state, save, run, connect }); }
  finally {
    for (const key of Object.keys(process.env)) if (!(key in prior)) delete process.env[key];
    Object.assign(process.env, prior);
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("Claude waits for a cooperating writer and merges its latest config", async () => scenario(async ({ root, task, run }) => {
  const home = process.env.CLAUDE_CONFIG_DIR;
  fs.mkdirSync(home);
  const file = path.join(home, ".claude.json");
  fs.writeFileSync(file, JSON.stringify({ projects: {} }));
  fs.mkdirSync(`${file}.lock`);
  const result = run(["launch", "--provider", "claude", "--task", task, "--cwd", root]);
  const writer = new Promise(resolve => setTimeout(() => {
    fs.writeFileSync(file, JSON.stringify({ projects: { unrelated: { keep: true } }, concurrent: "preserved" }));
    fs.rmdirSync(`${file}.lock`);
    resolve();
  }, 400));
  await writer;
  assert.equal((await result).code, 0);
  const after = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(after.concurrent, "preserved");
  assert.deepEqual(after.projects.unrelated, { keep: true });
  assert.equal(fs.existsSync(`${file}.lock`), false);
}));

test("hand-started MCP bridges report native identity and require an authenticated live process", async () => scenario(async ({ root, task, state, save, run, connect }) => {
  const launched = await run(["launch", "--provider", "claude", "--task", task, "--cwd", root]);
  const original = { ...state().terminal.labels };
  const otherCore = path.join(root, "other-core.json");
  fs.writeFileSync(otherCore, JSON.stringify({ ...state(), core_id:"wrong-core" }));
  const reporter = createReporter({ ...process.env, HC_TERMINAL_ID: "t9", HC_TERMINAL_SOCKET: "private-core-selector",
    HC_SOCKET:"other-selector", HERDR_ENV: "1", HERDR_PANE_ID: "old-pane" }, selected =>
    selected.HC_SOCKET === "private-core-selector" ? connect() : require(cli).connectCore(undefined, process.execPath, [peer, otherCore]));
  const pipe = process.platform === "win32" ? `\\\\.\\pipe\\sympp-observed-${process.pid}` : path.join(root, "probe.sock");
  const bridge = require("../../scripts/start-sympp-mcp-bridge.js");
  await bridge.ensureLivenessProbe();
  const leaseFile = bridge.createLocalLease(path.join(root, "runtime.json"), { backend: { managed:true } }, { runtimeKey:"fixture" }, "fixture");
  const lease = JSON.parse(fs.readFileSync(leaseFile, "utf8"));
  const probe = { pipe:lease.process_liveness_pipe, token:lease.process_liveness_token };
  const token = probe.token;
  let mode = "valid";
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    if (mode !== "stalled") socket.end(mode === "valid" ? token : (token[0] === "a" ? "b" : "a") + token.slice(1));
  });
  server.listen(pipe);
  await once(server, "listening");
  try {
    const forwarded = JSON.parse(await reporter.attach(JSON.stringify({ method: "initialize", params: {} })));
    const observed = forwarded.params._meta.herdr;
    assert.equal(observed.core_id, "core-one");
    assert.equal(observed.core_name, "controlled");
    assert.equal(observed.terminal_id, "t9");
    assert.equal(observed.pid, undefined, "the factory keys on core and address, never the pid");
    assert.deepEqual(reporter.terminal(), { core_id: "core-one", terminal_id: "t9" });
    assert.doesNotMatch(JSON.stringify(observed), /private-core-selector|process_liveness/);

    const chiefBinding = bridge.decodeHerdrBinding(Buffer.from(JSON.stringify({ role: "chief", domain: "Herdr" })).toString("base64url"));
    await reporter.report(chiefBinding, probe);
    const chiefLabels = state().terminal.labels;
    assert.equal(chiefLabels["sympp.session_id"], reporter.clientId);
    assert.equal(chiefLabels["sympp.session_role"], "chief");
    const chief = await run(["check", "--receipt", chiefLabels["sympp.session_receipt"]]);
    assert.equal(chief.code, 0);
    assert.equal(chief.body.state, "live");
    assert.equal(chief.body.role, "chief");
    assert.equal(chief.body.work_request_id, null);
    assert.equal(chief.body.work_package_id, null);
    for (const [key, value] of Object.entries(original)) assert.equal(chiefLabels[key], value);

    await reporter.report({ role: "architect", work_request_id: "wr-manual" }, probe);
    const labels = state().terminal.labels;
    for (const [key, value] of Object.entries(original)) assert.equal(labels[key], value);
    const args = ["check", "--receipt", labels["sympp.session_receipt"]];
    const alive = await run(args);
    assert.equal(alive.code, 0);
    assert.equal(alive.body.state, "live");
    assert.equal(alive.body.work_request_id, "wr-manual");
    assert.equal(alive.body.role, "architect");
    assert.doesNotMatch(JSON.stringify(alive.body), /process_liveness|private-core-selector/);
    assert.ok(!JSON.stringify(alive.body).includes(token));
    assert.equal((await run(["check", "--receipt", launched.body.receipt])).body.state, "live");
    assert.equal((await run(["list", "--cwd", root])).body.count, 1, "observing a bridge does not create another agent launch");

    await reporter.report({ role:"worker", work_package_id:"wp-manual" }, probe);
    const worker = await run(args);
    assert.equal(worker.body.state, "live");
    assert.equal(worker.body.work_request_id, null, "worker grants need not include a WorkRequest scope");
    assert.equal(worker.body.work_package_id, "wp-manual");
    await reporter.report({ role:"architect", work_request_id:"wr-manual" }, probe);

    for (const denied of ["wrong", "stalled"]) {
      mode = denied;
      await reporter.report({ role: "architect", work_request_id: "wr-manual" }, { pipe, token });
      assert.equal((await run(args)).body.state, "stale", "a timeout is not authenticated liveness");
      for (const socket of sockets) socket.destroy();
    }
    mode = "valid";
    await reporter.report({ role: "architect", work_request_id: "wr-manual" }, probe);
    save({ ...state(), terminal: { ...state().terminal, pid: 901 } });
    assert.equal((await run(args)).body.reason, "process_changed");
    await reporter.report({ role: "architect", work_request_id: "replacement" }, { pipe, token });
    assert.equal(state().terminal.labels["sympp.session_work_request_id"], "wr-manual", "an old bridge cannot bind a recovered terminal");
    assert.deepEqual(reporter.terminal(), { core_id: "core-one", terminal_id: "t9" }, "a pid change keeps the terminal identity");
    const afterRestart = JSON.parse(await reporter.attach(JSON.stringify({ method: "tools/call", params: { name: "read_work_request" } })));
    assert.equal(afterRestart.params._meta.herdr.terminal_id, "t9");
    save({ ...state(), terminal: { ...state().terminal, pid: 900 } });
    reporter.close();
    assert.equal(fs.existsSync(labels["sympp.session_receipt"]), false, "revoke before asynchronous runtime cleanup");
    await reporter.report({ role: "architect", work_request_id: "resurrected" }, { pipe, token });
    assert.equal(fs.existsSync(labels["sympp.session_receipt"]), false);
    assert.equal((await run(args)).body.error, "input_unreadable");
  } finally {
    reporter.close();
    bridge.closeLivenessProbe();
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  }
}));
