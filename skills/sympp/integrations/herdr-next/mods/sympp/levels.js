// Pure Factory, Topic and Space levels: where sympp jobs sit among the person's Herdr topics and
// spaces, what needs them first, what the panel follows and which needs are new. No GPUI or Herdr
// imports, so every rule here is asserted on its own. Jobs stay canonical sympp jobs: a level only
// places, ranks and references them; it never copies the backlog.

import { shortRepo, lanesOf, chiefBindings } from "./model.js";
import * as J from "./job.js";
import { intoTopic, chiefTerminal, chiefRunning } from "./chief.js";

export const UNSORTED = "unsorted";
export const NOWHERE = "nowhere";
export const LEVELS = ["factory", "topic", "space", "job"];

const keyOf = (value) => shortRepo(value ?? "").toLowerCase();

// ---------- Topics and spaces ----------

// Herdr's own topic grouping, shared("desk.topics") = { groups: [{ id, name, spaces, folded }],
// unsorted }. Spaces no group claims are unsorted, so a new space never disappears.
export function deskOf(deskTopics, spaceList) {
  const list = Array.isArray(spaceList) ? spaceList : [];
  const byId = new Map(list.map((s) => [s.id, s]));
  const placed = new Set();
  const groups = Array.isArray(deskTopics?.groups) ? deskTopics.groups : [];
  const topics = groups.filter((g) => g && g.id && g.name).map((g) => {
    const spaces = (Array.isArray(g.spaces) ? g.spaces : []).map((id) => byId.get(id)).filter((s) => s && !placed.has(s.id));
    for (const s of spaces) placed.add(s.id);
    return { id: g.id, name: g.name, kind: "topic", spaces };
  });
  return [...topics,
    { id: UNSORTED, name: "Unsorted", kind: "unsorted", spaces: list.filter((s) => !placed.has(s.id)) },
    { id: NOWHERE, name: "Without a space", kind: "none", spaces: [] }];
}

// A space's repository is the leaf of its folder; ancestor folders never match.
export function spaceRepo(space) {
  return space?.folder ? keyOf(space.folder) || null : null;
}

export function spaceById(desk, id) {
  for (const topic of desk) {
    const space = topic.spaces.find((s) => s.id === id);
    if (space) return { space, topic };
  }
  return null;
}

// Explicit repository mappings first, then every topic with a space on that repository.
function topicsOfRepo(repo, desk, repoTopics) {
  const explicit = repoTopics && typeof repoTopics === "object" ? repoTopics[repo] ?? repoTopics[shortRepo(repo)] : undefined;
  if (typeof explicit === "string") return desk.filter((t) => t.kind === "topic" && (t.id === explicit || t.name === explicit));
  const key = keyOf(repo);
  return key ? desk.filter((t) => t.spaces.some((s) => spaceRepo(s) === key)) : [];
}

const leaf = (address) => String(address ?? "").split("/").pop();

// The chief domain owning a task: its owner's when a chief works on it; else the chief it was created
// or dispatched under; else the domain Herdr's labels give the owner's terminal, as an architect a
// chief started carries its chief's. The factory and Herdr may name that terminal's machine
// differently, so it is found by its terminal id and its binding to this task.
export function ownerDomain(job, terminalList) {
  if (job.owner?.role === "chief" && job.owner.domain) return job.owner.domain;
  if (job.dispatchedBy) return job.dispatchedBy;
  if (!job.owner?.address) return null;
  const term = (terminalList ?? []).find((t) => leaf(t?.address) === leaf(job.owner.address) &&
    (t.labels?.["sympp.work_request_id"] === job.id || t.labels?.["sympp.session_work_request_id"] === job.id));
  const domain = term?.labels?.["sympp.domain"];
  return typeof domain === "string" && domain.trim() ? domain.trim() : null;
}

// The topic a chief domain is registered for in shared("sympp.chiefs") ({ [topic id]: [{ domain }] }),
// else the topic its name matches as chiefsFor matches names.
export function domainTopic(domain, desk, registered) {
  const key = words(domain).join(" ");
  if (!key) return null;
  const topics = desk.filter((t) => t.kind === "topic");
  const listed = (t) => (Array.isArray(registered?.[t.id]) ? registered[t.id] : []);
  return topics.find((t) => listed(t).some((c) => words(c?.domain).join(" ") === key))?.id
    ?? topics.find((t) => chiefsFor(t, [{ domain, repos: [] }], desk).length > 0)?.id ?? null;
}

// Each job has one home topic, so the factory counts it once: its owning chief's topic, else its
// own repository's first. Every other topic it touches holds a reference to that one job.
// owners: { terminals, chiefs } as Herdr reports them, for each job's owning chief.
export function placeJobs(jobs, desk, repoTopics, owners = {}) {
  const home = new Map();
  const repos = new Map();
  for (const job of jobs) {
    const within = new Map();
    const chief = domainTopic(ownerDomain(job, owners.terminals), desk, owners.chiefs);
    if (chief) within.set(chief, [...job.repos]);
    for (const repo of job.repos) {
      for (const topic of topicsOfRepo(repo, desk, repoTopics)) {
        if (!within.has(topic.id)) within.set(topic.id, []);
        if (!within.get(topic.id).includes(repo)) within.get(topic.id).push(repo);
      }
    }
    repos.set(job.id, within);
    home.set(job.id, within.keys().next().value ?? NOWHERE);
  }
  return {
    home: (job) => home.get(job.id) ?? NOWHERE,
    touches: (job, topicId) => repos.get(job.id)?.has(topicId) ?? false,
    reposIn: (job, topicId) => repos.get(job.id)?.get(topicId) ?? [],
    alsoIn: (job) => [...(repos.get(job.id)?.keys() ?? [])].filter((id) => id !== home.get(job.id)),
  };
}

// ---------- Factory ----------

// What answering frees: every unfinished package after this one in the execution graph. An ask
// about the whole job holds all of its unfinished packages.
export function unblocks(job, pkgId) {
  const open = new Set(job.packages.filter((pkg) => pkg.stage !== "ended").map((pkg) => pkg.id));
  if (!pkgId) return open.size;
  const after = new Set();
  const queue = [pkgId];
  while (queue.length) {
    const id = queue.shift();
    for (const [pre, dep] of job.edges ?? []) {
      if (pre === id && dep !== pkgId && !after.has(dep)) { after.add(dep); queue.push(dep); }
    }
  }
  return [...after].filter((id) => open.has(id)).length;
}

// Needs-you across the factory, from asks only: what unblocks the most waiting packages first, then
// the longest wait. A card's ask frees no package.
export function needsQueue(jobs, cards = []) {
  const age = (need) => need.since ?? Infinity;
  return [...jobs.flatMap((job) => job.needs.map((need) => ({ ...need, job, card: null, unblocks: unblocks(job, need.pkgId) }))),
    ...cards.flatMap((card) => card.needs.map((need) => ({ ...need, job: null, card, unblocks: 0 })))]
    .sort((a, b) => b.unblocks - a.unblocks || age(a) - age(b));
}

// Decisions to review across the factory, oldest first, each with its task.
export function decisionQueue(jobs) {
  return jobs.flatMap((job) => job.decisions.map((d) => ({ ...d, job }))).sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
}

// One row per Herdr topic, then unsorted spaces and work without a space when either has anything,
// cards and settled tasks included, so an archived one can still be restored. A card's asks count
// where the card lives.
export function factoryRows(jobs, desk, place, cards = []) {
  const open = jobs.filter((job) => job.state !== "settled");
  const names = new Map(desk.map((t) => [t.id, t.name]));
  return desk.map((topic) => {
    const own = open.filter((job) => place.home(job) === topic.id);
    const held = cards.filter((card) => place.home(card) === topic.id);
    const shared = new Map();
    for (const job of open) {
      if (place.home(job) === topic.id || !place.touches(job, topic.id)) continue;
      const from = names.get(place.home(job)) ?? names.get(NOWHERE);
      shared.set(from, (shared.get(from) ?? 0) + 1);
    }
    return {
      ...topic,
      jobs: own,
      needs: own.reduce((n, job) => n + job.needs.length, 0) + held.reduce((n, card) => n + card.needs.length, 0),
      cards: held.length,
      settled: jobs.filter((job) => job.state === "settled" && place.home(job) === topic.id).length,
      moving: own.reduce((n, job) => n + job.counts.live, 0),
      repos: [...new Set(own.flatMap((job) => job.repos.map(shortRepo)).filter(Boolean))],
      shared: [...shared].map(([name, count]) => ({ name, count })),
    };
  }).filter((row) => row.kind === "topic" || row.jobs.length > 0 || row.cards > 0 || row.settled > 0 || row.shared.length > 0 || (row.kind === "unsorted" && row.spaces.length > 0));
}

// ---------- Topic and space ----------

// Every job touching the space's repository, each with the job's other repositories as references.
export function spaceWork(space, jobs) {
  const key = spaceRepo(space);
  const touching = key ? jobs.filter((job) => job.repos.some((repo) => keyOf(repo) === key)) : [];
  const lanes = lanesOf(touching);
  return {
    repo: key ? shortRepo(space.folder) : null,
    jobs: [...lanes.moving, ...lanes.parked, ...lanes.landed],
    planned: lanes.backlog,
    away: lanes.settled.length + lanes.dormant.length,
    elsewhere: (job) => [...new Set(job.repos.filter((repo) => keyOf(repo) !== key).map(shortRepo))],
  };
}

// ---------- Chiefs ----------

// A chief space Start chief made for a topic belongs in that topic, where the desk keeps it unlisted.
// Herdr can drop a space out of its topic; the next desk with each such space back at the end of
// its topic, folded as it was, or null when every one is home or its space or topic is gone.
export function homeChiefSpaces(deskTopics, made, spaceIds) {
  let next = null;
  for (const [space, topic] of Object.entries(made && typeof made === "object" ? made : {})) {
    const desk = next ?? deskTopics;
    const group = desk?.groups?.find((g) => g.id === topic);
    if (!group || !spaceIds.includes(space) || (group.spaces ?? []).includes(space)) continue;
    const moved = intoTopic(desk, topic, space);
    if (!moved) continue;
    moved.groups.find((g) => g.id === topic).folded = group.folded;
    next = moved;
  }
  return next;
}

const words = (name) => String(name ?? "").toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);

// One name's words lead or end the other's: Kraken and Nextide-Kraken, Personal and Personal Tools.
function wordMatch(a, b) {
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  if (!short.length) return false;
  const from = (offset) => short.every((word, i) => long[offset + i] === word);
  return from(0) || from(long.length - short.length);
}

// A Herdr topic's chiefs: the chief named exactly like it; else chiefs whose name leads or ends the
// topic's; else chiefs whose declared repositories place there, as jobs place. A chief named exactly
// like another topic belongs to that one. Several at the first rule that matches are all returned,
// never one picked.
export function chiefsFor(topic, chiefs, desk, repoTopics) {
  if (topic?.kind !== "topic" || !chiefs?.length) return [];
  const name = (value) => words(value).join(" ");
  const exact = name(topic.name) ? chiefs.filter((c) => name(c.domain) === name(topic.name)) : [];
  if (exact.length) return exact;
  const claimed = new Set(desk.filter((t) => t.kind === "topic").map((t) => name(t.name)));
  const free = chiefs.filter((c) => !name(c.domain) || !claimed.has(name(c.domain)));
  const named = free.filter((c) => wordMatch(words(c.domain), words(topic.name)));
  if (named.length) return named;
  return free.filter((c) => c.repos.some((repo) => topicsOfRepo(repo, desk, repoTopics).some((t) => t.id === topic.id)));
}

// The latest started chief and its labelled terminal are one entry even before a helper check succeeds.
// The labelled terminal is only an identity for dedupe; liveness still comes from chiefAgent.
export function chiefEntries(topic, chiefs, latest, terminalList, now) {
  const running = chiefRunning(latest, terminalList, now);
  const entries = chiefs.filter(({ chief, agent }) => !running ||
    (agent.binding?.address ?? chiefTerminal(chief, terminalList)) !== latest.terminal)
    .map(({ chief, agent }) => ({ domain: chief.domain, terminal: agent.state === "live" ? agent.binding.address : null }));
  return running ? [{ domain: topic.name, terminal: latest.terminal }, ...entries] : entries;
}

// The chief as an agent, by the Job level's rule: Live only after a helper check of its bound session,
// else its last sympp sighting, else unknown. Provider and role come from that binding, the report from
// the agent's own OSC status.
export function chiefAgent(chief, bindings, terminalList, checks, now) {
  const own = chiefBindings(bindings, chief);
  const seen = J.liveness(own, checks, chief.location, null, now);
  const binding = seen.binding ?? own[0] ?? null;
  return {
    ...seen, bindings: own,
    provider: binding && binding.provider !== "Agent" ? binding.provider : null,
    role: binding?.role ?? null,
    report: J.reportFor(own, terminalList, now),
  };
}

// ---------- Navigation ----------

// A path names the level and what it sits under: { topic, space, job }. The deepest one set is the level.
export function levelOf(path) {
  return path?.job ? "job" : path?.space ? "space" : path?.topic ? "topic" : "factory";
}

// Esc and the breadcrumb go up one level at a time.
export function up(path) {
  if (path.job) return { topic: path.topic ?? null, space: path.space ?? null, job: null };
  if (path.space) return { topic: path.topic ?? null, space: null, job: null };
  return { topic: null, space: null, job: null };
}

// What still exists of a remembered path. A job that left the board falls back a level, unless it
// was just created and the board has not caught up.
export function resolvePath(path, desk, jobs, awaiting = null) {
  const topic = desk.find((t) => t.id === path?.topic) ?? null;
  const found = path?.space ? spaceById(desk, path.space) : null;
  const job = path?.job && (jobs.some((j) => j.id === path.job) || path.job === awaiting) ? path.job : null;
  return { topic: found?.topic.id ?? topic?.id ?? null, space: found?.space.id ?? null, job };
}

export function crumbs(path, desk, jobs) {
  const list = [{ level: "factory", label: "Factory", path: { topic: null, space: null, job: null } }];
  const topic = desk.find((t) => t.id === path.topic);
  if (topic) list.push({ level: "topic", label: topic.name, path: { topic: topic.id, space: null, job: null } });
  const found = path.space ? spaceById(desk, path.space) : null;
  if (found) list.push({ level: "space", label: found.space.name || shortRepo(found.space.folder) || "Space", path: { topic: path.topic, space: found.space.id, job: null } });
  if (path.job) list.push({ level: "job", label: jobs.find((j) => j.id === path.job)?.title ?? "New job", path });
  return list;
}

// ---------- Following focus ----------

// A tab holding a Topic, Space or the Factory registers this key instead of a job id.
export const scopeTabKey = (path) => `scope:${path.topic ?? ""}:${path.space ?? ""}`;

// Each chief terminal the panel knows, with its topic: the chiefs it shares ({ [topic id]: [{ terminal }] }),
// each topic's latest started chief while it still runs ({ [topic id]: { terminal, agent } }) and
// terminals labelled as a chief ([{ domain, terminal }]) whose domain names a topic, unless only a
// shell runs there now.
export function chiefTopics(chiefs, sessions, labelled, desk, terminalList = [], now = Date.now()) {
  const out = new Map();
  for (const [topic, list] of Object.entries(chiefs && typeof chiefs === "object" ? chiefs : {})) {
    for (const c of Array.isArray(list) ? list : []) if (c?.terminal) out.set(c.terminal, topic);
  }
  for (const [topic, s] of Object.entries(sessions && typeof sessions === "object" ? sessions : {})) {
    if (s?.terminal && !out.has(s.terminal) && chiefRunning(s, terminalList, now)) out.set(s.terminal, topic);
  }
  for (const c of labelled ?? []) {
    // A chief that exited leaves its labels on the shell left behind.
    if ((terminalList ?? []).find((k) => k.address === c.terminal)?.program?.key === "shell") continue;
    const topic = out.has(c.terminal) ? null : domainTopic(c.domain, desk, chiefs);
    if (topic) out.set(c.terminal, topic);
  }
  return out;
}

// The tab bindings that still hold (shared("sympp.jobTabs") = { [tab]: job id | scopeTabKey }): the tab
// still has a sympp pane and no chief's terminal, and a bound task is on the board and not archived.
// Opening an agent that has no pane keeps it beside the focused tab, so a task's own tab can come to
// hold a chief, or only that, long after its task is done with.
export function liveTabs(jobTabs, jobs, paneList, chiefs = new Map()) {
  const panes = paneList ?? [];
  const held = new Set(panes.filter((p) => p.mod === "sympp" && !p.terminal).map((p) => p.tab));
  const chiefTabs = new Set(panes.filter((p) => p.terminal && chiefs.has(p.terminal)).map((p) => p.tab));
  const open = new Set(jobs.filter((job) => job.phase !== "archived").map((job) => job.id));
  return Object.fromEntries(Object.entries(jobTabs && typeof jobTabs === "object" ? jobTabs : {}).filter(([tab, shows]) =>
    typeof shows === "string" && held.has(tab) && !chiefTabs.has(tab) && (shows.startsWith("scope:") || open.has(shows))));
}

// What Herdr's focus shows: a chief's terminal or tab is its topic; an sympp-labelled terminal or a job
// tab names its job; a mod pane (this panel, a viewer, a scope tab) keeps what is shown; anything else
// is its space. Labels only pick what to show; they never authorize an agent jump.
export function focusTarget(focus, terminalList, jobTabs, paneList, chiefs = new Map()) {
  if (!focus?.space) return null;
  const address = focus.shown ?? focus.terminal;
  if (address && chiefs.has(address)) return { kind: "topic", topic: chiefs.get(address), space: focus.space };
  const labels = (address ? (terminalList ?? []).find((t) => t.address === address)?.labels : null) ?? {};
  const job = labels["sympp.work_request_id"] || labels["sympp.session_work_request_id"] || null;
  const pkg = labels["sympp.work_package_id"] || labels["sympp.session_work_package_id"] || null;
  if (job || pkg) return { kind: "job", job, pkg, space: focus.space };
  const chief = (paneList ?? []).find((p) => p.tab === focus.tab && p.terminal && chiefs.has(p.terminal));
  if (chief) return { kind: "topic", topic: chiefs.get(chief.terminal), space: focus.space };
  const tabJob = jobTabs && typeof jobTabs === "object" ? jobTabs[focus.tab] : null;
  if (typeof tabJob === "string" && tabJob && !tabJob.startsWith("scope:")) return { kind: "job", job: tabJob, pkg: null, space: focus.space };
  const pane = (paneList ?? []).find((p) => p.pane === focus.pane);
  if (pane && !pane.terminal && !focus.shown) return null;
  return { kind: "space", space: focus.space };
}

// The path a focus target leads to: its job; else its space while sympp work touches it; else the
// space's topic; else the space, which says that ordinary Herdr work stays ordinary.
export function followPath(target, jobs, desk, place) {
  if (!target) return null;
  if (target.kind === "topic") return desk.some((t) => t.id === target.topic) ? { topic: target.topic, space: null, job: null } : null;
  const found = spaceById(desk, target.space);
  if (target.kind === "job") {
    const job = jobs.find((j) => j.id === target.job) ?? (target.pkg ? jobs.find((j) => j.packages.some((pkg) => pkg.id === target.pkg)) : null);
    if (job) {
      const inSpace = Boolean(found && spaceRepo(found.space) && job.repos.some((repo) => keyOf(repo) === spaceRepo(found.space)));
      return { topic: inSpace ? found.topic.id : place.home(job), space: inSpace ? found.space.id : null, job: job.id };
    }
  }
  if (!found) return null;
  const work = spaceWork(found.space, jobs);
  if (work.jobs.length > 0 || work.planned.length > 0 || found.topic.kind !== "topic") return { topic: found.topic.id, space: found.space.id, job: null };
  return { topic: found.topic.id, space: null, job: null };
}

// ---------- Toasts ----------

// Needs that appeared between two successful reads. The first read only records what is there, and
// an offline copy never announces anything.
export function newNeeds(previous, board) {
  const needs = [...board.jobs.flatMap((job) => job.needs.map((need) => ({ ...need, job }))),
    ...(board.cards ?? []).flatMap((card) => card.needs.map((need) => ({ ...need, card, job: null })))];
  const seen = new Set(needs.map((need) => need.key));
  if (previous === null || board.offline === true) return { seen, fresh: [] };
  return { seen, fresh: needs.filter((need) => !previous.has(need.key)) };
}


// One toast per need: the same need raised again later is a new item.
export function toastId(need) {
  return `${need.key}@${need.since ?? ""}`;
}
