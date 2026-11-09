"use strict";

const { randomUUID } = require("crypto");
const { execFile } = require("child_process");
const os = require("os");
const fs = require("fs");
const path = require("path");
const { connectCore } = require("./sympp-herdr.js");

const META_LABELS = ["sympp.role", "sympp.domain"];

// The verified terminal as `_meta.herdr`: core id and name, terminal address, and the two sympp
// labels the factory reads (chief role and domain). The pid is checked, never sent: the factory keys
// ownership on core id plus address, so restarting an agent in the same terminal keeps its identity.
function terminalMeta(identity) {
  if (!identity) return null;
  const labels = Object.fromEntries(META_LABELS.filter((key) => typeof identity.labels?.[key] === "string" && identity.labels[key].trim())
    .map((key) => [key, identity.labels[key].trim()]));
  return { core_id: identity.core_id, ...(identity.core_name ? { core_name: identity.core_name } : {}),
    terminal_id: identity.terminal_id, ...(Object.keys(labels).length ? { labels } : {}) };
}

function withTerminal(body, identity) {
  const herdr = terminalMeta(identity);
  if (!herdr) return body;
  try {
    const payload = JSON.parse(body);
    if (!payload || Array.isArray(payload) || !["initialize", "tools/call"].includes(payload.method)) return body;
    payload.params = { ...payload.params, _meta: { ...payload.params?._meta, herdr } };
    return JSON.stringify(payload);
  } catch (_) { return body; }
}

function isRemoteEndpoint(env) {
  if (!env.SYMPP_SERVER_URL) return false;
  return !["localhost", "127.0.0.1", "[::1]"].includes(new URL(env.SYMPP_SERVER_URL).hostname);
}

async function remoteArguments(body, factoryOwned) {
  if (!factoryOwned) return body;
  const credentialFree = value => {
    let remote;
    try { remote = new URL(value); } catch (_) { return value; }
    if (remote.password || /%3a/i.test(remote.username)) {
      throw new Error("Repository origins must not include credentials. Use a credential-free remote and configure Git authentication on the factory.");
    }
    // HTTP userinfo can be either an account or a token. It is authentication,
    // not repository identity; the factory uses its own Git credentials.
    if (["http:", "https:"].includes(remote.protocol) && remote.username) {
      const withoutUser = value.replace(/^(\s*https?:\/\/)[^/?#]*@/i, "$1");
      if (withoutUser === value) throw new Error("Repository origin must use an absolute HTTP URL.");
      return withoutUser;
    }
    return value;
  };
  const origin = cwd => new Promise((resolve, reject) => {
    execFile("git", ["-C", cwd, "remote", "get-url", "origin"],
      { timeout: 5000, maxBuffer: 8192, windowsHide: true }, (error, stdout) => {
        if (error || !stdout.trim()) reject(new Error("Repository origin is unavailable. Supply a git remote URL or owner/name."));
        else {
          try { resolve(credentialFree(stdout.trim())); } catch (failure) { reject(failure); }
        }
      });
  });
  const repo = async value => {
    const local = typeof value === "string" && (path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value) || /^\.\.?([\\/]|$)/.test(value) ||
      (fs.existsSync(value) && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value)));
    return local ? origin(value) : credentialFree(value);
  };
  const repoObject = async value => {
    if (!value || typeof value !== "object" || Array.isArray(value) || !("repo" in value)) return value;
    return { ...value, repo: await repo(value.repo) };
  };
  async function rewrite(payload) {
    const params = payload?.params;
    const input = params?.arguments;
    if (payload?.method !== "tools/call" || !input || typeof input !== "object" || Array.isArray(input)) return payload;
    let args = { ...input };
    if (["create_work_request", "solo_attach", "solo_list"].includes(params.name)) args = await repoObject(args);
    if (params.name === "create_work_request") {
      if (!Object.hasOwn(args, "repo")) args.repo = await origin(process.cwd());
      if (Array.isArray(args.repo_scopes)) args.repo_scopes = await Promise.all(args.repo_scopes.map(repoObject));
    }
    if (params.name === "edit_plan" && Array.isArray(args.ops)) {
      args.ops = await Promise.all(args.ops.map(async op => {
        if (op?.op === "add_package") return repoObject(op);
        if (op?.op === "update_package" && op.patch) return { ...op, patch: await repoObject(op.patch) };
        return op;
      }));
    }
    // A factory with a repos root chooses the checkout itself.
    if (params.name === "dispatch_work_package") delete args.target_repo_root;
    return { ...payload, params: { ...params, arguments: args } };
  }
  const payload = JSON.parse(body);
  if (Array.isArray(payload)) return body;
  return JSON.stringify(await rewrite(payload));
}

// A remote factory's launch line runs `hc run --on <machine>` from this client, so it names the
// factory the way this client's hc does: SYMPP_SERVER_NAME, else the server URL's host name.
function remoteDispatchMachine(body, env = process.env) {
  if (!isRemoteEndpoint(env)) return body;
  try {
    const payload = JSON.parse(body);
    const params = payload?.params;
    const input = params?.arguments;
    if (Array.isArray(payload) || payload?.method !== "tools/call" || params?.name !== "dispatch_work_package" ||
        !input || typeof input !== "object" || Array.isArray(input) || Object.hasOwn(input, "machine")) return body;
    const machine = env.SYMPP_SERVER_NAME || new URL(env.SYMPP_SERVER_URL).hostname;
    return JSON.stringify({ ...payload, params: { ...params, arguments: { ...input, machine } } });
  } catch (_) { return body; }
}

// A worker terminal (`sympp.role=worker`) gets no sympp tools: it lists none and every call is refused.
function workerToolsResponse(request) {
  if (request.method === "tools/list") return { jsonrpc: "2.0", id: request.id, result: { tools: [] } };
  return { jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "sympp serves no tools in a worker terminal. Report to your parent terminal instead.",
    data: { reason: "worker_terminal" } } };
}

function createReporter(env = process.env, connect = selected => connectCore(undefined, "hc", [], selected)) {
  const clientId = randomUUID();
  let identity = null;
  let factoryOwned = false;
  const native = Boolean(env.HC_TERMINAL_ID && env.HC_TERMINAL_SOCKET);
  const file = path.resolve(env.SYMPP_HOME || path.join(os.homedir(), ".agents", "splusplus"), "herdr-sessions", `${clientId}.json`);
  let refreshAt = 0;
  let pending = null;
  let reports = Promise.resolve();
  let revision = 0;
  let closed = false;

  // Verifies this terminal against the local herdr-core: same core, live, same address, a real pid.
  // A different core never replaces the identity. A pid change keeps it, but receipts stay tied to
  // the first pid, so a bridge outliving its agent cannot label the terminal's next agent.
  async function withCore(action) {
    const core = connect({ ...env, HC_SOCKET: env.HC_TERMINAL_SOCKET });
    let timer;
    try {
      await Promise.race([
        (async () => {
          const hello = await core.call("hello", { generation: 1 });
          const terminal = await core.call("terminal.get", { terminal: env.HC_TERMINAL_ID });
          if (!hello?.core?.id || terminal.address !== env.HC_TERMINAL_ID || terminal.state !== "live" ||
              !Number.isSafeInteger(terminal.pid) || terminal.pid <= 0) return;
          if (identity && identity.core_id !== hello.core.id) return;
          identity = { core_id: hello.core.id, core_name: typeof hello.core.name === "string" ? hello.core.name : null,
            terminal_id: terminal.address, labels: terminal.labels ?? {}, pid: identity?.pid ?? terminal.pid,
            current_pid: terminal.pid, process_id: process.pid, client_id: clientId };
          await action(core, terminal);
        })(),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("core unavailable")), 1000); }),
      ]);
    } finally { clearTimeout(timer); core.close(); }
  }

  // Refreshes the identity at most once a minute; a missing core never holds up MCP calls.
  async function refresh() {
    if (native && Date.now() >= refreshAt && !pending) {
      refreshAt = Date.now() + 60000;
      pending = withCore(async () => {}).catch(() => {}).finally(() => { pending = null; });
    }
    if (pending) await pending;
  }

  function clear() {
    revision++;
    try { fs.unlinkSync(file); } catch (_) { }
  }

  return {
    clientId,
    native,
    setFactoryOwned(value) { factoryOwned = value; },
    // The terminal named in client leases, once verified.
    terminal() { return identity ? { core_id: identity.core_id, terminal_id: identity.terminal_id } : null; },
    // Whether the verified terminal is labelled as a chief.
    chief() { return identity?.labels?.["sympp.role"] === "chief"; },
    // Whether the verified terminal is labelled as a dispatched worker.
    async worker() {
      await refresh();
      return identity?.labels?.["sympp.role"] === "worker";
    },
    clear,
    close() { closed = true; clear(); },
    report(binding, probe) {
      if (!native || closed || !binding || !probe?.pipe || !probe?.token) return Promise.resolve();
      const current = ++revision;
      reports = reports.then(() => withCore(async (core, terminal) => {
        if (closed || current !== revision || terminal.pid !== identity.pid) return;
        // Session receipts share the verifier, without changing a worker's original launch receipt.
        const receipt = { schema_version: 1, kind: "session", launch_id: clientId, core_id: identity.core_id,
          terminal_id: identity.terminal_id, pid: identity.pid, process_id: identity.process_id, client_id: clientId,
          provider: "agent", cwd: terminal.cwd || process.cwd(), role: binding.role,
          work_request_id: binding.work_request_id || null, work_package_id: binding.work_package_id || null,
          process_liveness_pipe: probe.pipe, process_liveness_token: probe.token };
        fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
        const temporary = `${file}.tmp`;
        fs.writeFileSync(temporary, JSON.stringify(receipt), { mode: 0o600 });
        fs.renameSync(temporary, file);
        await core.call("terminal.label", { terminal: terminal.address, labels: {
          "sympp.session_id": clientId, "sympp.session_core_id": receipt.core_id,
          "sympp.session_pid": String(receipt.pid), "sympp.session_process_id": String(receipt.process_id),
          "sympp.session_receipt": file, "sympp.session_role": receipt.role,
          // Herdr takes only text labels; an empty one removes a scope this session no longer has.
          "sympp.session_work_request_id": receipt.work_request_id ?? "",
          "sympp.session_work_package_id": receipt.work_package_id ?? "",
        } });
      })).catch(() => {});
      return reports;
    },
    refresh,
    async attach(body) {
      await refresh();
      return withTerminal(remoteDispatchMachine(await remoteArguments(body, factoryOwned), env), identity);
    },
  };
}

module.exports = { terminalMeta, withTerminal, createReporter, remoteArguments, remoteDispatchMachine, workerToolsResponse };
