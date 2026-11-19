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

// Agents whose saved session can be resumed, as herdr-core resumes them after a restart: the arguments
// after the agent's own command.
const RESUME = { codex: (id) => ["resume", id], claude: (id) => ["--resume", id] };

// Each topic's latest chief: { [topic id]: { terminal, agent, session, cwd, started? } }. Start chief
// records the terminal it started or resumed; while the chief runs, the sympp panel adds the session
// Herdr saved for it, kept after its program ends (Herdr then forgets it) so the topic's mark can
// resume it.
export const CHIEF_SESSIONS = "sympp.chief.sessions";
// How long a chief Start chief just started counts as running before its agent shows in its terminal.
const STARTING = 30e3;

// The factory's repos root as it reports it (its SYMPP_REPOS_ROOT), shared by the sympp panel; null
// when it has none.
export const FACTORY_ROOT = "sympp.factory.root";

// A running chief's terminal as a CHIEF_SESSIONS entry, when its agent saved a session it can resume.
export function chiefSession(term) {
  const agent = term?.program?.key, session = term?.resume_session;
  if (term?.state !== "live" || !RESUME[agent] || typeof session !== "string" || !session) return null;
  return { terminal: term.address, agent, session, cwd: term.foreground?.cwd || term.cwd || "" };
}

export const machineOf = (address) => (address.includes("/") ? address.slice(0, address.indexOf("/")) : null);

// The topic's latest chief runs in its terminal: its agent runs there, or Start chief has just started
// it. That is the topic's chief from its start, before its agent first reaches sympp.
export const chiefRunning = (last, terminalList, now = Date.now()) => Boolean(last?.terminal) && terminalList.some((k) =>
  k.address === last.terminal && k.state === "live" && (k.program?.key === last.agent || (last.started > 0 && now - last.started < STARTING)));

export const canResume = (last) => Boolean(last && RESUME[last.agent] && typeof last.session === "string" && last.session);

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

// A labelled chief's terminal while it is live.
export function chiefTerminal(chief, terminalList) {
  if (!chief?.terminal) return null;
  return terminalList.find((t) => t.address === chief.terminal && t.state === "live")?.address ?? null;
}

const trimmed = (path) => path.replace(/[\\/]+$/, "");
const parent = (path) => (/[\\/]/.test(trimmed(path)) ? trimmed(path).replace(/[\\/][^\\/]*$/, "") : "");
const worktree = (path) => /[\\/]\.worktrees([\\/]|$)/.test(path);
const parts = (path) => trimmed(path).split(/[\\/]/);
const joined = (list, like) => list.join(like.includes("\\") && !like.includes("/") ? "\\" : "/");
const common = (lists) => {
  let n = 0;
  while (lists.every((l) => n < l.length && l[n] === lists[0][n])) n++;
  return lists[0].slice(0, n);
};

// A space's saved folder is where its new terminals start. Its active pane can be somewhere else.
// Resolve the pane's live folder to the Git checkout root, including when it is in a subdirectory.
export async function chiefCheckouts(spaceList, paneList, gitRoot) {
  const lookups = new Map();
  const checkouts = await Promise.all(spaceList.map(async (space) => {
    const active = space.tabs.find((tab) => tab.active);
    const shown = paneList.filter((pane) => pane.tab === active?.id && pane.cwd);
    const pane = shown.find((p) => p.focused) ?? shown.find((p) => p.branch === space.branch) ?? shown[0];
    const cwd = pane?.cwd || space.folder;
    if (!cwd || worktree(cwd)) return null;
    const machine = space.machine ?? null;
    const key = JSON.stringify([machine, cwd]);
    if (!lookups.has(key)) lookups.set(key, gitRoot(cwd, machine));
    const folder = await lookups.get(key);
    return folder && !worktree(folder) ? { id: space.id, machine, folder } : null;
  }));
  return checkouts.filter(Boolean);
}

const contains = (root, folder) => root.every((part, i) => part === folder[i]);

function commonFolder(folders) {
  const path = folders.length ? common(folders.map(parts)) : [];
  return path.length > 1 ? joined(path, folders[0]) : null;
}

function checkoutHolders(checkouts, machine) {
  return checkouts.filter((s) => (s.machine ?? null) === machine).map((s) => parent(s.folder)).filter(Boolean);
}

function relativeHolder(folder, reportedRoot, observedRoot, targetName) {
  const holder = parts(folder);
  const reported = reportedRoot && parts(reportedRoot);
  if (reported && contains(reported, holder)) return holder.slice(reported.length);

  const observed = observedRoot && parts(observedRoot);
  // All visible checkouts may be in the same team folder. Match the target root's name to an
  // ancestor so C:\Code\team and /srv/user/Code/team keep the team component.
  const anchor = (observed || holder).lastIndexOf(targetName);
  if (anchor > 0) return holder.slice(anchor + 1);
  return observed && contains(observed, holder) ? holder.slice(observed.length) : null;
}

// Try the topic's common holder on the chief's machine, translating checkout holders from other
// machines relative to their repos roots. The factory's reported root precedes the root inferred
// from other checkouts. With no topic holder, try the machine's repos roots before home.
export function chiefFolders(topicCheckouts, allCheckouts, machine, factory = null) {
  const reportedRoot = (m) => factory?.machine === m ? factory.root : null;
  const observedRoot = (m) => commonFolder(checkoutHolders(allCheckouts, m));
  const targets = [reportedRoot(machine), observedRoot(machine)].filter(Boolean);
  const local = checkoutHolders(topicCheckouts, machine);
  const remote = topicCheckouts.filter((s) => (s.machine ?? null) !== machine);
  const candidates = targets.map((root) => {
    const target = parts(root);
    if (!local.every((folder) => contains(target, parts(folder)))) return null;
    const mapped = remote.flatMap((s) => {
      const folder = parent(s.folder);
      const source = s.machine ?? null;
      const relative = folder && relativeHolder(folder, reportedRoot(source), observedRoot(source), target.at(-1));
      return relative ? [joined([...target, ...relative], root)] : [];
    });
    return commonFolder([...local, ...mapped]);
  });
  return [...new Set([...candidates, commonFolder(local), ...targets].filter(Boolean))];
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
