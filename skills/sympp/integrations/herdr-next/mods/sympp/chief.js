// Pure chief logic: the chief's brief and command, resuming a stopped chief, the factory's machine,
// where the chief starts and its place among Herdr's topics. No GPUI or Herdr imports; chiefview.js
// draws the dialog and runs these against Herdr.

const LOOPBACK = new Set(["localhost", "127.0.0.1", "::1"]);
// Agents that take their first message another way than as the last argument, as in Change anything.
const MESSAGE = { opencode: (m) => ["--prompt", m], gemini: (m) => ["-i", m], copilot: (m) => ["-i", m] };

// What the chief is told; the person's own words follow. Its terminal's labels make it the topic's
// chief for sympp (chiefLabelArgs); nothing needs registering.
export function chiefBrief(name, extra = "") {
  const brief = `You are the chief for the "${name}" topic. Use the sympp skill.`;
  return extra.trim() ? `${brief}\n\n${extra.trim()}` : brief;
}

// hc arguments that label a chief's terminal: sympp reads sympp.role and sympp.domain from the terminal
// through its bridge, to attribute the chief's requests and dispatches to the topic.
export const chiefLabelArgs = (terminal, name) => ["label", terminal, "sympp.role=chief", `sympp.domain=${name}`];

export const chiefArgv = (agent, brief) => [...agent.run, ...(MESSAGE[agent.key] ?? ((m) => [m]))(brief)];

export const chiefSpaceName = (name) => `${name} chief`;

export function chiefTerminalName(name) {
  const suffix = "-chief";
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-/, "")
    .slice(0, 32 - suffix.length).replace(/-$/, "");
  return `${slug || "topic"}${suffix}`;
}

// Agents whose saved session can be resumed, as herdr-core resumes them after a restart: the arguments
// after the agent's own command.
const RESUME = { codex: (id) => ["resume", id], claude: (id) => ["--resume", id] };

// Each topic's latest chief: { [topic id]: { terminal, agent, session, cwd, started?, pid?, native? } }.
// Start chief records its launch. The panel follows the live agent and keeps its conversation
// after it exits so the mark can resume it.
export const CHIEF_SESSIONS = "sympp.chief.sessions";
// How long a chief Start chief just started counts as running before its agent shows in its terminal.
const STARTING = 30e3;

// Herdr sets program.agent on status reports. The program key also identifies a stock Codex or
// Claude without reports, and the agent originally picked for a recorded launch.
export function chiefAgentKey(term, recordedAgent) {
  const program = term?.program;
  if (term?.state !== "live" || !program?.key || program.shell || program.key === "shell") return null;
  return program.agent || program.key === recordedAgent || canResumeAgent(program.key) ? program.key : null;
}
const chiefPid = (term) => term.foreground?.pid ?? term.pid ?? null;

// The record associates the terminal with a topic ID. That association survives a topic rename
// or failure to apply the terminal's labels during launch.
export function recordedChief(last, terminalList, now) {
  if (!last?.terminal) return null;
  const term = terminalList.find((t) => t.address === last.terminal);
  if (term?.state !== "live") return null;
  const role = term.labels?.["sympp.role"];
  if (role && role !== "chief") return null;
  const starting = last.started > 0 && now - last.started < STARTING;
  return chiefAgentKey(term, last.agent) || starting ? term : null;
}

const uuid = (value) => typeof value === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value) ? value : null;

// A CLI can name its conversation explicitly. Use the actual agent's arguments so a shell
// wrapping a different launch, a prompt, or a sympp bridge ID cannot supply the session.
function launchSession(term, agent) {
  const argv = term.foreground?.argv?.length ? term.foreground.argv : term.argv ?? [];
  const command = argv[0]?.split(/[\\/]/).at(-1).toLowerCase().replace(/\.exe$/, "");
  if (command !== agent && !(agent === "claude" && command === "claude-code")) return null;
  const end = argv.indexOf("--", 1);
  const args = argv.slice(1, end < 0 ? argv.length : end);
  if (agent === "codex") {
    const at = args[0] === "--no-daemon" ? 1 : 0;
    return args[at] === "resume" ? uuid(args[at + 1]) : null;
  }
  const fork = args.includes("--fork-session");
  for (const [at, arg] of args.entries()) {
    const [name, value] = arg.split("=", 2);
    if (name === "--session-id" || (!fork && (name === "--resume" || name === "-r"))) {
      const session = uuid(value ?? args[at + 1]);
      if (session) return session;
    }
  }
  return null;
}

export const canResumeAgent = (agent) => Object.hasOwn(RESUME, agent);

// A fresh core reply can supply an updated native conversation. The app snapshot doesn't
// refresh resume_session on status events. Keep a known ID only for the same agent and process.
export function chiefSession(term, last, saved = null) {
  const agent = chiefAgentKey(term, last?.agent);
  if (!agent) return null;
  const pid = chiefPid(term);
  const same = last?.terminal === term.address && last.agent === agent && (last.pid == null || last.pid === pid);
  const app = saved?.status?.app;
  const currentReport = saved?.state === "live" && chiefPid(saved) === pid && (app === agent || (agent === "claude" && app === "claude-code"));
  const fromCore = currentReport ? uuid(saved.resume_session) : null;
  const remembered = same ? uuid(last.session) : null;
  const resumable = canResumeAgent(agent);
  const native = resumable && (fromCore !== null || (same && last.native === true));
  let session = null;
  if (resumable) {
    session = native ? (currentReport ? fromCore : remembered) : launchSession(term, agent) ?? remembered;
  }
  return { terminal: term.address, agent, session, cwd: term.foreground?.cwd || term.cwd || "", pid,
    ...(native ? { native: true } : {}) };
}

export const machineOf = (address) => (address.includes("/") ? address.slice(0, address.indexOf("/")) : null);

export const canResume = (last) => Boolean(last && canResumeAgent(last.agent) && typeof last.session === "string" && last.session);

// Resumes the recorded session with the agent's own command and its brief again, in a new terminal
// that Start chief labels like the first.
export const resumeArgv = (agent, last, name) => [...agent.run, ...RESUME[last.agent](last.session), chiefBrief(name)];

// Where Start chief records the spaces it made: { [space id]: topic id }.
export const CHIEF_SPACES = "sympp.chief.spaces";

// A topic's chief space: one Start chief made for it, or one named as it names them (spaces made before
// it kept a record). Reached from the topic's sympp mark, never listed; the desk-topics chrome keeps
// the same rule.
export const isChiefSpace = (space, topic, made) => made?.[space.id] === topic.id || space.name === chiefSpaceName(topic.name);

export function endpointHost(endpoint) {
  const host = /^[a-z][a-z0-9+.-]*:\/\/(\[[^\]]+\]|[^/:?#]+)/i.exec(endpoint ?? "")?.[1];
  return host ? host.replace(/^\[|\]$/g, "").toLowerCase() : null;
}

// The Herdr machine the factory runs on: this computer (null) for a loopback endpoint; else the
// machine named, reached or hosted at the endpoint's host, or whose ssh destination resolves to it
// (setup takes a remote factory's address from its ssh host). Undefined when none matches.
export async function factoryMachine(endpoint, list, resolve) {
  const host = endpointHost(endpoint);
  if (!host || LOOPBACK.has(host)) return null;
  const same = (value) => typeof value === "string" && value.toLowerCase() === host;
  const named = list.find((m) => same(m.name) || same(m.target) || same(m.host));
  if (named) return named.name;
  for (const m of list.filter((m) => !m.via && m.target)) if (same(await resolve(m.target).catch(() => null))) return m.name;
  return undefined;
}

const trimmed = (path) => path.replace(/[\\/]+$/, "");
const drive = (part) => /^[a-z]:$/i.test(part);
function parent(path) {
  const clean = trimmed(path);
  const split = clean.search(/[\\/][^\\/]*$/);
  if (split < 0) return "";
  const folder = clean.slice(0, split);
  return !folder || drive(folder) ? clean.slice(0, split + 1) : folder;
}
const worktree = (path) => /[\\/]\.worktrees([\\/]|$)/.test(path);
const parts = (path) => trimmed(path).split(/[\\/]/);
function joined(list, like) {
  const sep = like.includes("\\") && !like.includes("/") ? "\\" : "/";
  const folder = list.join(sep);
  return list.length === 1 && (!folder || drive(folder)) ? folder + sep : folder;
}
const common = (lists) => {
  let n = 0;
  while (lists.every((l) => n < l.length && l[n] === lists[0][n])) n++;
  return lists[0].slice(0, n);
};

// A space's saved folder is where its new terminals start. Its panes can be somewhere else.
// Resolve their live folders to Git checkout roots, including when a pane is in a subdirectory.
export async function chiefCheckouts(spaceList, paneList, gitRoot, batchDeadline) {
  const byTab = new Map(spaceList.flatMap((space) => space.tabs.map((tab) => [tab.id, space])));
  const showing = new Set();
  const lookups = new Map();
  function add(space, cwd) {
    if (!cwd || worktree(cwd)) return;
    const machine = space.machine ?? null;
    if (!lookups.has(machine)) lookups.set(machine, new Map());
    const folders = lookups.get(machine);
    if (!folders.has(cwd)) folders.set(cwd, new Set());
    folders.get(cwd).add(space.id);
  }
  for (const pane of paneList) {
    const space = byTab.get(pane.tab);
    if (!space || !pane.cwd) continue;
    showing.add(space.id);
    add(space, pane.cwd);
  }
  for (const space of spaceList) if (!showing.has(space.id)) add(space, space.folder);

  const byMachine = await Promise.all([...lookups].map(async ([machine, folders]) => {
    const pending = [...folders];
    const checkouts = [];
    // Herdr Core allows 16 concurrent execs per machine. Leave room for its other clients.
    const batchSize = 8;
    for (let i = 0; i < pending.length; i += batchSize) {
      let expired = false;
      const batch = Promise.all(pending.slice(i, i + batchSize).map(async ([cwd, spaces]) => {
        const folder = await gitRoot(cwd, machine);
        if (!expired && folder && !worktree(folder)) {
          for (const id of spaces) checkouts.push({ id, machine, folder });
        }
      }));
      const deadline = batchDeadline?.(machine);
      await (deadline ? Promise.race([batch, deadline.then(() => { expired = true; })]) : batch);
      // Keep the results that arrived and put no more work on a stalled machine.
      if (expired) break;
    }
    return checkouts;
  }));
  return byMachine.flat();
}

const contains = (root, folder) => root.every((part, i) => part === folder[i]);

function commonFolder(folders, includeFilesystemRoot = false) {
  const path = folders.length ? common(folders.map(parts)) : [];
  return path.length >= (includeFilesystemRoot ? 1 : 2) ? joined(path, folders[0]) : null;
}

function checkoutHolders(checkouts, machine) {
  return checkouts.filter((s) => (s.machine ?? null) === machine).map((s) => parent(s.folder)).filter(Boolean);
}

function mapHolder(folder, reportedRoot, observedRoot, root, reportedTarget) {
  const holder = parts(folder);
  const reported = reportedRoot && parts(reportedRoot);
  const known = reported && contains(reported, holder) ? reported : null;
  const observed = observedRoot && parts(observedRoot);
  const source = known ?? observed;
  const target = parts(root);
  // Inferred roots can end inside a team folder. Align them at the nearest shared ancestor name.
  // A reported factory root fixes that machine's side of the mapping.
  const first = reportedTarget ? target.length - 1 : 1;
  for (let i = target.length - 1; i >= first; i--) {
    const anchor = known ? (known.at(-1) === target[i] ? known.length - 1 : -1)
      : (observed || holder).lastIndexOf(target[i]);
    if (anchor > 0) return joined([...target.slice(0, i + 1), ...holder.slice(anchor + 1)], root);
  }
  return source && contains(source, holder) ? joined([...target, ...holder.slice(source.length)], root) : null;
}

// Try the topic's common holder on the chief's machine, translating checkout holders from other
// machines relative to their repos roots. The factory's reported root precedes the root inferred
// from other checkouts. With no topic holder, try the machine's repos roots before home.
export function chiefFolders(topicCheckouts, allCheckouts, machine, factory = null) {
  const reportedRoot = (m) => factory?.root && factory.machine === m ? factory.root : null;
  const observedRoot = (m) => commonFolder(checkoutHolders(allCheckouts, m));
  const factoryTarget = reportedRoot(machine);
  const targets = [factoryTarget, observedRoot(machine)].filter(Boolean);
  const local = checkoutHolders(topicCheckouts, machine);
  const remote = topicCheckouts.filter((s) => (s.machine ?? null) !== machine);
  const candidates = targets.map((root) => {
    const mapped = remote.map((s) => {
      const folder = parent(s.folder);
      const source = s.machine ?? null;
      return folder && mapHolder(folder, reportedRoot(source), observedRoot(source), root, root === factoryTarget);
    }).filter(Boolean);
    return commonFolder([...local, ...mapped], true);
  });
  return [...new Set([...candidates, commonFolder(local, true), ...targets].filter(Boolean))];
}

// Herdr's topics with the space added to the end of the topic and the topic unfolded; null when the
// topic is gone.
export function intoTopic(deskTopics, topic, space) {
  const next = JSON.parse(JSON.stringify(deskTopics ?? { groups: [], unsorted: [] }));
  const group = (next.groups ?? []).find((g) => g.id === topic);
  if (!group) return null;
  next.unsorted = (next.unsorted ?? []).filter((id) => id !== space);
  for (const g of next.groups) g.spaces = (g.spaces ?? []).filter((id) => id !== space);
  group.spaces.push(space);
  group.folded = false;
  return next;
}

// The topic mark's right-click menu, only what applies: a running chief's space (when it has a pane
// there) and adding it to a composition, then starting a new chief, whose labels make it the topic's chief.
export function chiefMenu(terminal, terminalList, paneList) {
  const live = Boolean(terminal) && terminalList.some((k) => k.address === terminal && k.state === "live");
  return [
    ...(live && paneList.some((p) => p.terminal === terminal) ? [{ label: "Go to chief space", action: "space" }] : []),
    ...(live ? [{ label: "Add to composition", action: "composition" }] : []),
    { label: "Start new chief", action: "start" },
  ];
}
