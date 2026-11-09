"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { spawn } = require("node:child_process");
const { once } = require("node:events");

// The installed journey reaches a loopback factory, which needs no token and never drops a
// request. A tailnet factory's credential and a connection lost mid-mutation stay here.
test("remote bridge authenticates, never repeats a mutation the factory may have received, and stops on a refused token", async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-remote-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const received = [];
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    received.push({ url: req.url, headers: req.headers, body: body ? JSON.parse(body) : null });
    if (req.headers.authorization !== "Bearer fixture-token") return res.writeHead(401).end("Unauthorized");
    if (req.method === "GET" && req.url === "/mcp/readiness") return res.end(JSON.stringify({
      status: "ok", factory_owned_worktrees: true, ledger: { reachable: true, identity: { default_home: true } }
    }));
    if (JSON.parse(body).params?.name === "ambiguous_mutation") { req.socket.destroy(); return; }
    res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "remote-session" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: JSON.parse(body).id, result: { protocolVersion: "2025-03-26", extra: "preserved" } }));
  });
  server.listen(0, "0.0.0.0");
  await once(server, "listening");
  t.after(() => { server.closeAllConnections(); server.close(); });
  const nic = Object.values(os.networkInterfaces()).flat().find(x => x.family === "IPv4" && !x.internal)?.address;
  assert.ok(nic, "a non-loopback interface exercises remote URL admission");
  const tokenFile = path.join(root, "token");
  fs.writeFileSync(tokenFile, "fixture-token");
  async function run(token, tool = "list_work_requests", expectedSuccess = true, args = {}) {
    fs.writeFileSync(tokenFile, token);
    const child = spawn(process.execPath, [path.resolve(__dirname, "../../scripts/start-sympp-mcp-bridge.js")], {
      env: { ...process.env, HC_TERMINAL_ID: "", HERDR_ENV: "", SYMPP_REPO_ROOT: "must-not-use", SYMPP_POWERSHELL: "must-not-start",
        SYMPP_HOME: path.join(root, "runtime-must-not-exist"), SYMPP_SERVER_URL: `http://${nic}:${server.address().port}`, SYMPP_SERVER_TOKEN_FILE: tokenFile },
      stdio: ["pipe", "pipe", "pipe"], windowsHide: true, cwd: root,
    });
    t.after(() => child.kill());
    let stdout = "", stderr = "";
    child.stdout.on("data", c => stdout += c); child.stderr.on("data", c => stderr += c);
    child.stdin.end([ { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26" } },
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: args } } ].map(JSON.stringify).join("\n") + "\n");
    const [code] = await once(child, "exit");
    if (expectedSuccess) assert.equal(code, 0, stderr);
    else assert.notEqual(code, 0, stderr);
    assert.equal(fs.existsSync(path.join(root, "runtime-must-not-exist")), false);
    return { replies: stdout.trim() ? stdout.trim().split("\n").map(JSON.parse) : [], stderr };
  }
  const { replies } = await run("fixture-token");
  assert.equal(replies[1].result.extra, "preserved");
  const tool = received.find(r => r.body?.method === "tools/call");
  assert.equal(tool.headers["mcp-session-id"], "remote-session");
  assert.equal(tool.body.params._meta?.herdr, undefined, "outside Herdr no terminal identity accompanies the request");
  assert.deepEqual(received.map(r => r.url), ["/mcp/readiness", "/mcp", "/mcp"]);
  assert.equal(received[0].headers.authorization, "Bearer fixture-token");
  const ambiguous = await run("fixture-token", "ambiguous_mutation");
  assert.equal(ambiguous.replies[1].error.data.reason, "backend_lost_after_request_started");
  assert.equal(received.filter(r => r.body?.params?.name === "ambiguous_mutation").length, 1);
  const postsBeforeDenial = received.filter(r => r.url === "/mcp").length;
  const denied = await run("wrong-token", "list_work_requests", false);
  assert.match(denied.stderr, /authentication failed.*401/);
  assert.equal(denied.replies.length, 0);
  assert.equal(received.filter(r => r.url === "/mcp").length, postsBeforeDenial);
});

test("an unknown factory ownership capability stops the bridge before any MCP call", async t => {
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
