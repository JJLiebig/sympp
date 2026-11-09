"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawn } = require("node:child_process");
const { remoteArguments, remoteDispatchMachine } = require("../../scripts/sympp-session-location.js");

test("remote path requests become origin identities", async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-repo-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  execFileSync("git", ["init", root]);
  execFileSync("git", ["-C", root, "remote", "add", "origin", "https://github.com/example/service.git"]);
  const env = { SYMPP_SERVER_URL: "http://100.123.207.19:19998", SYMPP_SERVER_NAME: "jjdev" };
  const call = args => JSON.stringify({ method: "tools/call", params: { name: "create_work_request", arguments: args } });
  const input = call({ repo: root, constraints: { repo: "/deployment/path", review: { repos: ["/do-not-resolve"] } } });
  const converted = JSON.parse(await remoteArguments(input, true)).params.arguments;
  assert.equal(converted.repo, "https://github.com/example/service.git");
  assert.equal(JSON.parse(await remoteArguments(call({ repo: path.relative(process.cwd(), root) }), true)).params.arguments.repo, converted.repo);
  assert.deepEqual(converted.constraints, JSON.parse(input).params.arguments.constraints);
  assert.equal(JSON.parse(await remoteArguments(call({ repo: 0 }), true)).params.arguments.repo, 0);
  const unknown = JSON.stringify({ method: "tools/call", params: { name: "sympp.health", arguments: { repo: "/unknown-field" } } });
  assert.equal(await remoteArguments(unknown, true), unknown);

  assert.equal(await remoteArguments(input, false), input);

  assert.equal(JSON.parse(await remoteArguments(input, true)).params.arguments.repo, converted.repo);
  assert.equal(await remoteArguments(input, false), input);
  for (const remote of ["https://fixture-user:fixture-password@example.org/team/repo.git", "ssh://deploy:fixture-password@example.org/team/repo.git", "ssh://deploy%3Afixture-password@example.org/team/repo.git"]) {
    execFileSync("git", ["-C", root, "remote", "set-url", "origin", remote]);
    await assert.rejects(remoteArguments(input, true), error => error.message === "Repository origins must not include credentials. Use a credential-free remote and configure Git authentication on the factory.");
    await assert.rejects(remoteArguments(call({ repo: remote }), true), /Repository origins must not include credentials/);
  }
  for (const repoPath of ["/team/repo.git", "/team/ü/repo.git", "/team/%2e%2e/repo.git"]) {
    for (const user of ["alice", "fixture-token"]) {
      const remote = `https://${user}@example.org${repoPath}`;
      execFileSync("git", ["-C", root, "remote", "set-url", "origin", remote]);
      assert.equal(JSON.parse(await remoteArguments(input, true)).params.arguments.repo, `https://example.org${repoPath}`);
      assert.equal(JSON.parse(await remoteArguments(call({ repo: remote }), true)).params.arguments.repo, `https://example.org${repoPath}`);
    }
  }
  execFileSync("git", ["-C", root, "remote", "set-url", "origin", "ssh://deploy@example.org/team/repo.git"]);
  assert.equal(JSON.parse(await remoteArguments(input, true)).params.arguments.repo, "ssh://deploy@example.org/team/repo.git");
  execFileSync("git", ["-C", root, "remote", "set-url", "origin", converted.repo]);
  execFileSync("git", ["-C", root, "remote", "remove", "origin"]);
  assert.equal(await remoteArguments(input, false), input);
});

test("dispatch to a remote factory names the factory machine and lets the factory choose the checkout", async () => {
  const dispatch = args => JSON.stringify({ method: "tools/call", params: { name: "dispatch_work_package", arguments: { work_package_id: "wp-1", review_mode: "fast", ...args } } });
  const remote = { SYMPP_SERVER_URL: "http://100.123.207.19:19998", SYMPP_SERVER_NAME: "jjdev" };
  const named = body => JSON.parse(remoteDispatchMachine(body, remote)).params.arguments;
  assert.equal(named(dispatch({})).machine, "jjdev");
  assert.equal(JSON.parse(remoteDispatchMachine(dispatch({}), { SYMPP_SERVER_URL: "http://factory.example:19998" })).params.arguments.machine, "factory.example");
  assert.equal(named(dispatch({ machine: "other" })).machine, "other");
  for (const local of [{}, { SYMPP_SERVER_URL: "http://127.0.0.1:19998" }]) assert.equal(remoteDispatchMachine(dispatch({}), local), dispatch({}));
  const withRoot = dispatch({ target_repo_root: "/client/checkout" });
  assert.equal(JSON.parse(await remoteArguments(withRoot, true)).params.arguments.target_repo_root, undefined);
  assert.equal(await remoteArguments(withRoot, false), withRoot);
});

// The gate for dispatched workers: in a terminal labelled sympp.role=worker the bridge lists no
// tools and refuses calls without reaching the factory. A fake `hc` stands in for herdr-core.
test("a worker terminal lists zero sympp tools", async t => {
  const http = require("node:http");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-worker-tools-"));
  const bin = path.join(root, "bin");
  fs.mkdirSync(bin);
  const labelsFile = path.join(root, "labels.json");
  fs.writeFileSync(path.join(bin, "hc"), `#!${process.execPath}
const fs = require("node:fs");
require("node:readline").createInterface({ input: process.stdin }).on("line", line => {
  const { id, method } = JSON.parse(line);
  const result = method === "hello" ? { generation: 1, core: { id: "core-1", name: "fixture" } }
    : { address: "t5", state: "live", pid: process.pid, labels: JSON.parse(fs.readFileSync(${JSON.stringify(labelsFile)}, "utf8")) };
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
});
`, { mode: 0o755 });
  const forwarded = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", chunk => { body += chunk; });
    req.on("end", () => {
      if (req.method === "GET") return res.end(JSON.stringify({ status: "ok", factory_owned_worktrees: true, ledger: { reachable: true }, source: { mcp_contract: { fingerprint: "a".repeat(64) } } }));
      if (req.url === "/mcp/client-lease") return res.end(JSON.stringify({ ok: true }));
      const message = JSON.parse(body);
      forwarded.push(message.method);
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: message.method === "tools/list" ? { tools: [{ name: "sympp.health", inputSchema: { type: "object" } }] } : {} }));
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => { server.close(); fs.rmSync(root, { recursive: true, force: true }); });
  const session = async role => {
    fs.writeFileSync(labelsFile, JSON.stringify(role ? { "sympp.role": role } : {}));
    const env = { ...process.env, HOME: root, USERPROFILE: root, SYMPP_HOME: root, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      SYMPP_SERVER_URL: `http://127.0.0.1:${server.address().port}`, HC_TERMINAL_ID: "t5", HC_TERMINAL_SOCKET: path.join(root, "core.sock") };
    delete env.SYMPP_SERVER_TOKEN_FILE;
    const child = spawn(process.execPath, [path.resolve(__dirname, "../../scripts/start-sympp-mcp-bridge.js")], { env, stdio: ["pipe", "pipe", "pipe"] });
    const lines = require("node:readline").createInterface({ input: child.stdout });
    const responses = [];
    lines.on("line", line => responses.push(JSON.parse(line)));
    child.stderr.resume();
    child.stdin.end([{ id: 1, method: "tools/list", params: {} }, { id: 2, method: "tools/call", params: { name: "sympp.health", arguments: {} } }]
      .map(request => JSON.stringify({ jsonrpc: "2.0", ...request })).join("\n") + "\n");
    await new Promise((resolve, reject) => { child.once("exit", resolve); child.once("error", reject); });
    return responses;
  };

  const [listed, called] = await session("worker");
  assert.deepEqual(listed.result.tools, []);
  assert.equal(called.error.data.reason, "worker_terminal");
  assert.deepEqual(forwarded.filter(method => method.startsWith("tools/")), []);

  const [architectList] = await session("architect");
  assert.deepEqual(architectList.result.tools.map(tool => tool.name), ["sympp.health"]);
  assert.deepEqual(forwarded.filter(method => method.startsWith("tools/")), ["tools/list", "tools/call"]);
});

test("an unknown factory ownership capability stops the bridge before any MCP call", async t => {
  const http = require("node:http");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-unknown-owner-"));
  let posts = 0;
  const server = http.createServer((req, res) => {
    if (req.method === "POST") posts++;
    res.end(JSON.stringify({ status: "ok", ledger: { reachable: true }, source: { mcp_contract: { fingerprint: "a".repeat(64) } } }));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => { server.close(); fs.rmSync(root, { recursive: true, force: true }); });
  const env = { ...process.env, HOME: root, USERPROFILE: root, SYMPP_HOME: root,
    SYMPP_SERVER_URL: `http://127.0.0.1:${server.address().port}`, HC_TERMINAL_ID: "", HC_TERMINAL_SOCKET: "" };
  delete env.SYMPP_SERVER_TOKEN_FILE;
  const child = spawn(process.execPath, [path.resolve(__dirname, "../../scripts/start-sympp-mcp-bridge.js")], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  child.stdout.resume();
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_work_request", arguments: {} } }) + "\n");
  const exit = await new Promise((resolve, reject) => { child.once("exit", resolve); child.once("error", reject); });
  assert.notEqual(exit, 0);
  assert.match(stderr, /could not determine repository ownership/);
  assert.equal(posts, 0);
});
