// sympp Lens: the shared sympp board, natively in Herdr. Levels run Factory > Topic > Space > Job; Esc
// goes up one. Topic and Space show the same tasks, a space only those on its repository; a task shows
// its packages at work. A copy opened with props.job is that job's own tab. A panel copy follows
// Herdr's focus (a job's terminal or tab, else the space, else its topic) until it is pinned. A toast
// says when something newly needs the person. Intake and answers persist through sympp; board
// agent controls require a trusted execution helper's check. A copy opened with props.studio is one
// UI package's studio: its worker's terminal beside a preview, in a tab named after the package. A copy
// opened with props.role "chief" is the Start chief dialog for props.topic; "chief-menu" is the topic
// mark's right-click menu.
//
// A copy opened with props.scope is that Topic or Space, or the Factory, as its own big tab.
//
// Block props: { endpoint: "http://127.0.0.1:<port>", role?: "overview" | "panel" | "chief" | "chief-menu", job?: "<work request id>",
//   scope?: { topic: "<desk topic id>" | null, space: "<space id>" | null },
//   studio?: { job: "<work request id>", pkg: "<work package id>" },
//   dashboardUrl?, repoTopics?: { "owner/repo" | "repo": "<desk topic id or name>" },
//   hosts?: { local: { node, helper, session?, runtime? }, "machine": { node, helper, session? } } }
// With local.runtime (the factory's runtime record) a view starts that sympp when it doesn't answer.
// Hosts may also be configured explicitly in shared("sympp.hosts"). Another machine without a host runs
// the sympp skill's helper installed there (model.js). A copy without an endpoint uses the
// connection the last connected copy shared ("sympp.connection"), so a scripted studio needs only its ids.
//
// Modules: model.js (board in, view data out), levels.js (Factory, Topic and Space placement, panel
// following and new needs), scope.js (what a Topic, Space or task shows), job.js (agents and job
// tabs), controls.js (persisted actions), transport.js (native HTTP), ui.js (shared look),
// overview.js (the Factory level) and scopeview.js (the Topic, Space and task views), jobview.js (the
// answer form and review drill-down), rails.js (review rounds, row moves), chrome.js (what the patched desk agents
// list shows on sympp agents), studio.js and studioview.js (a UI package's studio), chief.js and
// chiefview.js (Start chief and the topic mark's menu).

import { View } from "gpui-kit";
import { v_flex, InputState, TextareaState } from "gpui-base";
import * as fs from "fs/promises";
import { props, theme, shared, setShared, spaces, panes, terminals, focused, notify, run, window as appWindow, exec, hc, appHome, watchFolder } from "herdr";
import * as M from "./model.js";
import * as L from "./levels.js";
import * as J from "./job.js";
import * as R from "./rails.js";
import * as C from "./controls.js";
import * as Chrome from "./chrome.js";
import * as S from "./studio.js";
import { scopeTitle } from "./scope.js";
import { request, remoteAuthorization, remoteRequest } from "./transport.js";
import { boardConnection, currentConnection, readBoard } from "./board.js";
import { button, message } from "./ui.js";
import * as O from "./overview.js";
import * as Lv from "./scopeview.js";
import { studioView } from "./studioview.js";
import { ChiefStart, ChiefMenu } from "./chiefview.js";
import { CHIEF_SESSIONS, CHIEF_SPACES, canResumeAgent, chiefSession, recordedChief } from "./chief.js";

const TICK = 5000;
const REPAINT = 30000;
const DAY = 24 * 3600e3;
const KEYS = { j: "down", k: "up", down: "down", up: "up" };
const TOP = { topic: null, space: null, job: null };
const CONNECTION = "sympp.connection";
// For other mods (the status bar): the live jobs, [{ id, title, stage, needs, failed }] with stage the
// furthest a live package reached; and their ask to show one in the panel, { job, at }.
const BOARD = "sympp.board";
const OPEN = "sympp.open";
// For desk-tabs' link beside the sympp panel button: the board's address, null when there is none.
const DASHBOARD = "sympp.dashboard_url";
// For the spaces sidebar's chief button: each Herdr topic's chiefs, { [topic id]: [{ domain,
// terminal }] }, terminal only while its agent runs or Start chief is in its starting grace.
const CHIEFS = "sympp.chiefs";
// Read sooner until the core confirms the session. Launch arguments can name an older conversation.
const SESSION_READ = [10e3, 60e3];
const STAGES = ["build", "checks", "review", "merge"];
const SWEEP = 60e3;
// A copy starting sympp records when ("sympp.starting"); other copies leave it to that one meanwhile.
const STARTING = "sympp.starting";
const START_WAIT = 60e3;
// How often an open view renews its sympp client lease; sympp drops one unrenewed for 10 minutes.
const LEASE = 60e3;
// The studio's own pane shrinks to its header, under Herdr's pane header, while a native preview
// shows below it.
const STRIP = 88;

async function runtimeConnection(path) {
  try {
    const runtime = JSON.parse(await fs.readFile(path, "utf8"));
    const endpoint = M.normalizeEndpoint(runtime.backend?.url);
    const pid = runtime.backend?.pid;
    const epoch = pid ? `${pid}:${runtime.publication?.backend?.process_start_time_utc_ticks ?? ""}` : null;
    return endpoint ? { endpoint, epoch } : null;
  } catch {
    return null;
  }
}

async function remoteConfig() {
  return JSON.parse(await fs.readFile(`${appHome()}/sympp-remote.json`, "utf8"));
}

// Removes a preview copy: a flat mods/sympp-dev-* folder, never another mod.
async function removeCopy(name) {
  if (!name.startsWith(S.DEV_PREFIX)) return;
  const dir = `${appHome()}/mods/${name}`;
  for (const file of await fs.readdir(dir)) await fs.unlink(`${dir}/${file}`);
  await fs.rmdir(dir);
}

// What a scope tab shows, as its tab registry records it.

function storedPath() {
  try {
    const path = JSON.parse(localStorage.getItem("path") ?? "null");
    return path && typeof path === "object" ? { ...TOP, ...path } : TOP;
  } catch {
    return TOP;
  }
}

// The Factory topics this copy shows opened, by topic id.
function storedTopics() {
  try {
    const ids = JSON.parse(localStorage.getItem("topics.open") ?? "[]");
    return new Set(Array.isArray(ids) ? ids.filter((id) => typeof id === "string") : []);
  } catch {
    return new Set();
  }
}

// Which tasks' packages at work are folded: every task or none, apart from the ones the person
// flipped since. Collapse all and Expand all set the rule and clear the exceptions, so tasks that
// arrive later and other spaces follow it. Kept across restarts.
function storedFolds() {
  try {
    const folds = JSON.parse(localStorage.getItem("tasks.folded") ?? "null");
    const flipped = Array.isArray(folds?.flipped) ? folds.flipped.filter((id) => typeof id === "string") : [];
    return { all: folds?.all === true, flipped: new Set(flipped) };
  } catch {
    return { all: false, flipped: new Set() };
  }
}

export default class Lens extends View {
  init(p, cx) {
    const own = p ?? props() ?? {};
    const stored = own.endpoint ? null : shared(CONNECTION);
    const given = stored && typeof stored === "object" ? { ...stored, ...own } : own;
    const runtime = given.remote ? null : given.hosts?.local?.runtime;
    const endpoint = M.normalizeEndpoint(given.endpoint);
    const loadRemote = given.remote ? remoteConfig : null;
    if (own.role === "chief" || own.role === "chief-menu") {
      const factoryRoot = async () => {
        const current = runtime ? await runtimeConnection(runtime) : { endpoint };
        if (!current?.endpoint) return null;
        try {
          const authorization = loadRemote ? await remoteAuthorization(current.endpoint, loadRemote) : undefined;
          return boardConnection(current.endpoint, current.epoch, authorization).latest?.board.reposRoot ?? null;
        } catch {
          return null;
        }
      };
      this.chief = own.role === "chief" ? new ChiefStart(own, endpoint, factoryRoot, cx) : new ChiefMenu(own, cx);
      return;
    }
    this.given = given;
    this.ownConnection = Boolean(own.endpoint);
    const studio = own.studio;
    this.studio = typeof studio?.job === "string" && typeof studio?.pkg === "string" ? { job: studio.job, pkg: studio.pkg } : null;
    this.worker = { state: "checking" };
    this.native = { state: "idle", error: null, builtAt: null, dev: null, cwd: null };
    // Whether this package's preview copy is known gone; one may be left from before Herdr
    // restarted, so a studio ends it before building afresh.
    this.ended = !this.studio;
    this.sweptAt = 0;
    this.role = given.role === "panel" ? "panel" : "overview";
    const scope = own.scope && typeof own.scope === "object" ? own.scope : null;
    this.scoped = Boolean(scope);
    this.pinned = typeof given.job === "string" && given.job ? given.job : null;
    this.endpoint = endpoint;
    this.dashboard = M.dashboardUrl(this.endpoint, given.dashboardUrl);
    this.repoTopics = given.repoTopics && typeof given.repoTopics === "object" ? given.repoTopics : null;
    this.hosts = given.hosts ?? null;
    this.runtime = runtime;
    this.loadRemote = loadRemote;
    this.request = this.loadRemote ? remoteRequest(endpoint, this.loadRemote, () => this.connection?.authorization) : request;
    this.connection = null;
    this.net = M.initialFetch();
    this.payload = null;
    this.seeded = false;
    this.readSince = 0;
    this.reading = false;
    this.turn = 0;
    this.companion = false;
    this.pkgSel = null;
    this.review = null;
    this.shown = null;
    this.rowOrder = [];
    this.agentChecks = {};
    this.checking = false;
    this.checkedFor = null;
    this.checkedAt = 0;
    // Where this copy is: its own across restarts. A panel's pin stops it following focus.
    this.path = scope ? { ...TOP, topic: scope.topic ?? null, space: scope.space ?? null } : storedPath();
    this.pin = localStorage.getItem("pin") === "1";
    this.openTopics = storedTopics();
    this.folds = storedFolds();
    this.lastFocus = null;
    this.cursor = null;
    this.rows = [];
    this.expanded = new Set();
    this.awaiting = null;
    this.seenNeeds = null;
    this.painted = Date.now();
    this.keys = cx.focus_handle();
    this.intake = false;
    this.draft = { title: this.input("Title"), repo: this.input("owner/repository or repository path"), base_branch: this.input("Base branch"), human_description: this.input("What should this job accomplish?", true) };
    this.creation = { pending: false, error: null };
    this.answers = {};
    this.feedback = {};
    this.ops = {};
    // Operator actions drawn ahead of the factory (controls.js), and the last read they are drawn on.
    this.taken = [];
    this.writeFinishes = new Set();
    // This machine's core name, so the factory's "<core>/t8" addresses find their local terminals.
    this.coreName = null;
    hc(["server", "status", "--json"]).then((result) => {
      const name = JSON.parse(result.stdout)?.core?.name;
      if (typeof name === "string" && name) this.coreName = name;
    }).catch(() => {});
    this.leaseId = `herdr-app-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    this.leasedAt = 0;
    // Resolve a runtime record or remote authorization before showing its board or controls.
    this.resolving = Boolean(runtime || this.loadRemote);
    if (!this.resolving) this.useConnection(boardConnection(endpoint), cx, true);
    cx.timer.every(TICK, (cx) => this.tick(cx));
    this.tick(cx);
    this.started = Date.now();
    if (this.role === "panel") cx.timer.every(250, (cx) => this.checkOpen(cx));
  }

  clearBoard() {
    this.net = M.initialFetch();
    this.payload = null;
    this.seeded = false;
    this.readSince = 0;
    this.taken = [];
    this.seenNeeds = null;
    this.leasedAt = 0;
    this.lastFocus = null;
  }

  useConnection(connection, cx, restore) {
    if (this.connection === connection) return;
    this.connection = connection;
    this.clearBoard();
    if (connection) {
      this.endpoint = connection.endpoint;
      this.dashboard = M.dashboardUrl(this.endpoint, this.given.dashboardUrl);
    }
    const cached = restore ? connection?.latest : null;
    if (!cached || cached.building) return;
    this.seeded = true;
    this.readSince = cached.since;
    this.payload = cached.payload;
    this.net = M.fetchSucceeded(this.net, cached.board, cached.receivedAt);
    this.seenNeeds = L.newNeeds(null, cached.board).seen;
    this.updatePlacement();
    if (this.ownConnection) this.shareConnection();
    this.holdLease(cached.board, Date.now(), cx);
  }

  // Another mod asked the panel to show a job (shared OPEN); asks from before this copy started are old.
  checkOpen(cx) {
    const ask = shared(OPEN);
    if (!ask?.job || !(ask.at > (this.openedAt ?? this.started))) return;
    this.openedAt = ask.at;
    const job = this.net.data?.jobs.find((j) => j.id === ask.job);
    if (job) this.openJob(job, {}, cx);
  }

  needsControlRead() {
    const connection = this.connection;
    return !connection || connection.denied || !currentConnection(connection) ||
      (this.seeded && (connection.factory.writes > 0 || this.readSince < connection.factory.lastWrite));
  }

  // Data timer: the board when due, and agent checks for whichever view has agents to reach.
  // Otherwise it repaints now and then so ages move.
  tick(cx) {
    if (!this.endpoint && !this.runtime) return;
    const now = Date.now();
    // A copy that starts with the app (the sympp panel) ticks before Herdr has a window.
    const active = appWindow()?.active !== false;
    const cadence = M.nextDelay(this.net, active);
    const connection = this.connection;
    const changedConnection = connection && !currentConnection(connection);
    if ((changedConnection || connection?.denied) && this.net.data) this.clearBoard();
    const latest = connection?.latest;
    const newer = latest && !latest.building && latest.since > this.readSince;
    const afterWrite = this.readSince < (connection?.factory.lastWrite ?? 0);
    const due = newer || (!this.net.error && afterWrite) || M.fetchDue(this.net, now, active);
    const busy = (changedConnection || due) && this.read(cx, changedConnection);
    this.shareChiefs(now);
    const watch = this.withChiefs(this.agentWatch);
    if (watch && !this.checking && (this.checkedFor !== watch.key || now - this.checkedAt >= cadence)) this.checkAgents(watch, cx);
    if (now - this.sweptAt >= SWEEP) this.sweep(cx);
    if (!busy && now - this.painted >= REPAINT) {
      this.painted = now;
      cx.notify();
    }
  }

  // A new write boundary or explicit refresh can supersede a read that is still on the wire.
  read(cx, force = false) {
    const factory = this.connection?.factory;
    const boundary = factory?.lastWrite ?? 0;
    if (this.closed || (!this.endpoint && !this.runtime)) return false;
    if (!force && (factory?.writes || (this.reading && this.readBoundary === boundary))) return false;
    this.reading = true;
    this.readBoundary = boundary;
    const turn = ++this.turn;
    const after = force ? C.readStarts() : 0;
    const stillReading = () => !this.closed && turn === this.turn;
    cx.spawn(async (cx) => {
      let outcome;
      try {
        const runtime = this.runtime ? await runtimeConnection(this.runtime) : null;
        const endpoint = runtime?.endpoint ?? this.endpoint;
        const authorization = this.loadRemote ? await remoteAuthorization(endpoint, this.loadRemote) : undefined;
        if (!stillReading()) return;
        this.resolving = false;
        const connection = boardConnection(endpoint, runtime?.epoch, authorization);
        if (!connection) { cx.notify(); return; }
        const unverified = Boolean(this.runtime && !runtime && !this.connection);
        if (this.connection !== connection) {
          this.useConnection(connection, cx, !force && !unverified && !this.connection && !this.net.error);
          cx.notify();
        }
        const factory = connection.factory;
        if (factory.writes) return;
        this.readBoundary = factory.lastWrite;
        const cached = connection.latest;
        const active = appWindow()?.active !== false;
        const recent = !unverified && cached && !cached.building && cached.since >= after && !connection.pending && !connection.disconnected &&
          cached.since > factory.lastWrite && (!this.net.error || cached.since > this.readSince) &&
          Date.now() - cached.receivedAt < M.nextDelay({ data: cached.board }, active);
        if (recent && cached.since === this.readSince) return;
        outcome = recent ? cached : await readBoard(connection, cx, { unconditional: unverified, after, needed: stillReading });
        if (!stillReading() || !outcome || !currentConnection(connection)) return;
        if (outcome.board && (factory.writes || outcome.since < factory.lastWrite)) return;
      } catch (caught) {
        if (!stillReading()) return;
        this.resolving = false;
        if (this.loadRemote) this.useConnection(null, cx, false);
        outcome = { error: caught.userMessage || M.networkError(this.endpoint) };
      } finally {
        if (stillReading()) this.reading = false;
      }
      this.applyRead(outcome, cx);
      try { cx.notify(); } catch { /* reloaded while reading */ }
    });
    return true;
  }

  applyRead(outcome, cx) {
    const now = Date.now();
    this.painted = now;
    if (!outcome.board) {
      if (outcome.building) {
        this.net = M.fetchBuilding(this.net, now);
        return;
      }
      if (outcome.denied && this.net.data) this.clearBoard();
      this.net = M.fetchFailed(this.net, outcome.error, now);
      if (outcome.unreachable) this.startServer(cx);
      return;
    }

    this.seeded = false;
    if (!outcome.building) this.readSince = outcome.since;
    const board = this.drawn(outcome.payload, outcome.board, outcome.building ? null : outcome.since);
    this.net = M.fetchSucceeded(this.net, board, outcome.receivedAt);
    if (outcome.building) this.net = M.fetchBuilding(this.net, now);
    this.updatePlacement();
    this.outage = false;
    this.startFailed = false;
    this.holdLease(board, now, cx);
    if (this.ownConnection) this.shareConnection();
    if ((shared(DASHBOARD) ?? null) !== this.dashboard) setShared(DASHBOARD, this.dashboard);
    this.announce(board);
    const agents = Chrome.nextDecorations(shared(Chrome.AGENTS), Chrome.decorations(board, terminals(), this.endpoint, now, (a) => this.local(a)), this.endpoint, now);
    if (agents) setShared(Chrome.AGENTS, agents);
    const live = board.jobs.filter((j) => j.state === "live").map((j) => {
      const moving = j.packages.map(Chrome.deskStage).filter(Boolean);
      return { id: j.id, title: j.title, stage: STAGES[Math.max(-1, ...moving.map((s) => STAGES.indexOf(s)))] ?? null,
        needs: j.needs.length > 0, failed: j.packages.some((p) => p.failed && p.stage !== "ended") };
    });
    if (JSON.stringify(shared(BOARD)) !== JSON.stringify(live)) setShared(BOARD, live);
  }

  // A local sympp that doesn't answer starts through its helper, once per outage (Retry asks again), and
  // only from one copy at a time: the others see the shared start and wait for it.
  startServer(cx) {
    const host = this.hosts?.local;
    if (this.given.remote || !host?.runtime || this.starting || this.outage) return;
    const at = shared(STARTING);
    if (typeof at === "number" && Date.now() - at < START_WAIT) return;
    this.outage = true;
    this.starting = true;
    this.startFailed = false;
    setShared(STARTING, Date.now());
    cx.spawn(async (cx) => {
      let result = null;
      try { result = await exec(host.node, [host.helper, "start", "--runtime", host.runtime]); } catch { result = null; }
      this.starting = false;
      this.startFailed = result?.code !== 0;
      setShared(STARTING, 0);
      this.net = { ...this.net, attemptAt: null };
      this.read(cx, true);
      try { cx.notify(); } catch { /* closed while starting */ }
    });
  }

  // While a view is open sympp counts Herdr as a client, so it stays up after the last agent session
  // closes; the lease lapses on its own if Herdr quits before letting go.
  holdLease(board, now, cx) {
    if (board.offline !== false || now - this.leasedAt < LEASE) return;
    const action = this.leasedAt ? "heartbeat" : "attach";
    this.leasedAt = now;
    cx.spawn(async () => {
      const attached = await this.lease(action).then((response) => response.ok, () => false);
      if (!attached && this.leasedAt === now) this.leasedAt = 0;
    });
  }

  lease(action) {
    return this.request(`${this.endpoint}/mcp/client-lease`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_id: this.leaseId, action }),
    });
  }

  async close() {
    this.closed = true;
    // A fetch owned by this view may never settle after closing. A new view can verify its result
    // with a board read without waiting on that promise.
    for (const finish of this.writeFinishes ?? []) finish();
    if (this.leasedAt) await this.lease("detach").catch(() => null);
  }

  // Lets a copy opened without connection props (a scripted studio) reach the same sympp.
  shareConnection() {
    const { role: _role, job: _job, studio: _studio, ...connection } = this.given;
    if (JSON.stringify(shared(CONNECTION)) !== JSON.stringify(connection)) setShared(CONNECTION, connection);
  }

  // Removes preview copies no open studio uses, e.g. after a studio tab closed: only one unused on
  // two sweeps in a row and still unused just before it goes, so a studio starting one keeps it.
  sweep(cx) {
    this.sweptAt = Date.now();
    const before = this.strays ?? new Set();
    cx.spawn(async () => {
      try {
        const unused = () => new Set(S.strayCopies(names, shared(S.STUDIOS), this.openTabs(), panes()));
        const names = await fs.readdir(`${appHome()}/mods`);
        this.strays = unused();
        for (const name of this.strays) if (before.has(name) && unused().has(name)) await removeCopy(name);
      } catch { /* the next sweep tries again */ }
    });
  }

  openTabs() {
    return this.spaceList().flatMap((s) => (s.tabs ?? []).map((tab) => tab.id));
  }

  // A toast only for a need that appeared between two successful reads of this copy. Copies share
  // what was announced, so each need is announced once however many sympp views are open.
  announce(board) {
    const { seen, fresh } = L.newNeeds(this.seenNeeds, board);
    this.seenNeeds = seen;
    if (!fresh.length) return;
    const now = Date.now();
    const before = shared("sympp.toasted");
    const told = Object.fromEntries(Object.entries(before && typeof before === "object" ? before : {}).filter(([, at]) => now - at < DAY));
    let posted = false;
    for (const need of fresh) {
      const id = L.toastId(need);
      if (told[id]) continue;
      told[id] = now;
      posted = true;
      notify({ title: need.label, body: `${need.text} · ${need.job?.title ?? need.card?.task}`, level: "warning", ...(need.job ? { action: this.jobAction(need.job) } : {}) });
    }
    if (posted) setShared("sympp.toasted", told);
  }

  // The job's open tab when there is one, else a new one.
  jobAction(job) {
    const tab = L.tabShowing(shared("sympp.jobTabs"), job.id, this.endpoint, new Set(this.openTabs()));
    return tab ? { name: "tab.select", args: { id: tab } } : { name: "tab.new", args: J.jobTabArgs(this.given, job, this.spaceList()) };
  }

  // "Live" means the trusted helper confirmed this exact launch and process just now.
  checkAgents({ key, bindings }, cx) {
    this.checkedFor = key;
    this.checkedAt = Date.now();
    const due = bindings.filter((b) => b.available);
    if (!due.length) return;
    this.checking = true;
    cx.spawn(async (cx) => {
      for (const b of due) {
        let ok = false;
        try { ok = M.checkedBinding(b, await exec(b.host.node, M.bindingCheckArgs(b), { on: b.machine }), terminals()); } catch { ok = false; }
        this.agentChecks[b.address] = { ok, at: Date.now(), launchId: b.launchId, pid: b.pid };
      }
      this.checking = false;
      try { cx.notify(); } catch { /* closed while checking */ }
    });
  }

  retry(cx) {
    if (this.studio) {
      this.buildPreview(cx);
    }
    this.net = { ...this.net, attemptAt: null };
    this.checkedFor = null;
    this.outage = false;
    this.read(cx, true);
    cx.notify();
  }

  openDashboard(cx) {
    if (this.dashboard) cx.open_url(this.dashboard);
  }

  // ---------- Levels ----------

  // Moving to a level. Following focus never takes the keyboard; the person's own moves do.
  go(path, cx, { pkg = null, follow = false } = {}) {
    this.path = { topic: path.topic ?? null, space: path.space ?? null, job: path.job ?? null };
    this.following = follow;
    this.cursor = null;
    this.pkgSel = pkg;
    this.review = null;
    if (!this.scoped) try { localStorage.setItem("path", JSON.stringify(this.path)); } catch { /* storage is a convenience */ }
    if (follow) return;
    this.keys.focus();
    cx.notify();
  }

  goUp(cx) {
    this.go(L.up(this.path), cx);
  }

  openTopic(id, cx) {
    this.go({ topic: id }, cx);
  }

  openSpace(spaceId, topicId, cx) {
    this.go({ topic: topicId, space: spaceId }, cx);
  }

  // A job opened from a topic or space stays under it; from the factory it sits under its home topic.
  openJob(job, { pkg = null } = {}, cx) {
    const under = this.level === "topic" || this.level === "space" ? { topic: this.path.topic, space: this.path.space } : { topic: this.place?.home(job) ?? null };
    this.go({ ...under, job: job.id }, cx, { pkg });
  }

  togglePin(cx) {
    this.pin = !this.pin;
    try { localStorage.setItem("pin", this.pin ? "1" : "0"); } catch { /* storage is a convenience */ }
    this.lastFocus = null;
    cx.notify();
  }

  // Opens or closes a topic's tasks on the Factory; this copy remembers it across restarts.
  toggleTopic(id, cx) {
    if (this.openTopics.has(id)) this.openTopics.delete(id);
    else this.openTopics.add(id);
    try { localStorage.setItem("topics.open", JSON.stringify([...this.openTopics])); } catch { /* storage is a convenience */ }
    cx.notify();
  }

  folded(id) {
    return this.folds.all !== this.folds.flipped.has(id);
  }

  // Folds or opens one task's rows. Exceptions for tasks no longer on the board go.
  toggleFold(id, cx) {
    const jobs = new Set(this.net.data?.jobs.map((job) => job.id) ?? []);
    const flipped = new Set([...this.folds.flipped].filter((other) => jobs.has(other)));
    if (flipped.has(id)) flipped.delete(id);
    else flipped.add(id);
    this.saveFolds({ all: this.folds.all, flipped }, cx);
  }

  foldAll(all, cx) {
    this.saveFolds({ all, flipped: new Set() }, cx);
  }

  saveFolds(folds, cx) {
    this.folds = folds;
    try { localStorage.setItem("tasks.folded", JSON.stringify({ all: folds.all, flipped: [...folds.flipped] })); } catch { /* storage is a convenience */ }
    cx.notify();
  }

  toggleExpanded(key, cx) {
    if (this.expanded.has(key)) this.expanded.delete(key);
    else this.expanded.add(key);
    cx.notify();
  }

  // Rows register in reading order as they draw, so keys reach every row a pointer can.
  row(key, open) {
    this.rows.push({ key, open });
    return this.cursor === key && this.keys.is_focused();
  }

  // The panel follows Herdr's focus when it changes; the person's own moves stand until it does.
  follow(board, desk, cx) {
    const f = focused();
    // A newly added space can take focus before the next placement snapshot.
    if (f?.space && !L.spaceById(desk, f.space)) return;
    const stored = shared("sympp.jobTabs") ?? {};
    const chiefs = this.chiefTerminals(desk);
    const tabs = L.liveTabs(stored, board.jobs, panes(), chiefs, this.endpoint);
    // A binding that no longer holds goes, so the tab falls back to what it shows.
    if (JSON.stringify(tabs) !== JSON.stringify(stored)) cx.spawn(async () => setShared("sympp.jobTabs", tabs));
    // A chief recognised after it took focus still leads to its topic.
    const chief = f ? chiefs.get(f.shown ?? f.terminal) ?? panes().find((p) => p.tab === f.tab && chiefs.has(p.terminal))?.terminal : null;
    const seen = f ? [f.space, f.tab, f.pane, f.terminal, f.shown, tabs[f.tab]?.shows, chief].join("|") : "";
    if (seen === this.lastFocus) return;
    this.lastFocus = seen;
    const next = L.followPath(L.focusTarget(f, terminals(), tabs, panes(), chiefs), board.jobs, desk, this.place);
    this.following = Boolean(next);
    if (next && JSON.stringify(next) !== JSON.stringify(this.path)) this.go(next, cx, { follow: true });
  }

  // Herdr draws a mod pane only while its tab is the shown one, so a drawing job or scope tab is the
  // focused tab. It records what it shows (a job id, or L.scopeTabKey for a scope) so a panel and toasts can
  // find it instead of opening a second.
  registerTab(cx, shows) {
    const f = focused();
    if (!f?.tab || !this.net.data) return;
    const before = shared("sympp.jobTabs");
    const current = before && typeof before === "object" ? before : {};
    const mine = { shows, endpoint: this.endpoint };
    // Again once the panel dropped it, should it hold again.
    if (this.registered === f.tab && this.registeredAs === shows && JSON.stringify(current[f.tab]) === JSON.stringify(mine)) return;
    // Only a binding that holds: never a chief's tab, an archived task or a tab without a sympp pane.
    const next = L.liveTabs({ ...current, [f.tab]: mine }, this.net.data.jobs, panes(),
      this.chiefTerminals(L.deskOf(this.deskTopics(), this.spaceList())), this.endpoint);
    if (next[f.tab]?.shows !== shows) return;
    this.registered = f.tab;
    this.registeredAs = shows;
    if (JSON.stringify(next) !== JSON.stringify(current)) cx.spawn(async () => setShared("sympp.jobTabs", next));
  }

  // The panel's level as a big tab: the task's own tab, else one holding this Topic, Space or the
  // Factory. One already open is selected instead of a second; it closes like any tab.
  openBig(_cx) {
    const path = this.path;
    const job = path.job ? this.net.data?.jobs.find((j) => j.id === path.job) : null;
    const tab = L.tabShowing(shared("sympp.jobTabs"), job ? job.id : L.scopeTabKey(path), this.endpoint, new Set(this.openTabs()));
    if (tab) return run("tab.select", { id: tab });
    if (job) return run("tab.new", J.jobTabArgs(this.given, job, this.spaceList()));
    const { role: _role, job: _job, studio: _studio, scope: _scope, ...rest } = this.given;
    const name = path.topic ? scopeTitle(path, L.deskOf(this.deskTopics(), this.spaceList())) : "Factory";
    run("tab.new", { name, mod: "sympp", props: { ...rest, scope: { topic: path.topic, space: path.space } } });
  }

  // Herdr's own topics and spaces; the drawn-structure tests substitute fixtures here.
  deskTopics() {
    return shared("desk.topics");
  }

  spaceList() {
    return spaces();
  }

  // Repository and chief placement is independent of the focused space. Prepare it outside
  // render and keep it until the board or one of its placement inputs changes.
  updatePlacement() {
    const board = this.net.data;
    if (!board || this.studio || this.pinned) return false;
    const desk = L.deskOf(this.deskTopics(), this.spaceList().map(({ id, name, folder, machine }) => ({ id, name, folder, machine })));
    const chiefs = shared(CHIEFS);
    const owners = terminals().filter((t) => t.labels?.["sympp.work_request_id"] || t.labels?.["sympp.session_work_request_id"]);
    const key = JSON.stringify([desk, chiefs, owners.map(({ address, labels }) => [
      address, labels["sympp.work_request_id"], labels["sympp.session_work_request_id"], labels["sympp.domain"],
    ])]);
    if (this.placement?.board === board && this.placement.key === key) return false;
    this.place = L.placeJobs([...board.jobs, ...board.cards], desk, this.repoTopics, { terminals: owners, chiefs });
    this.placement = { board, key, desk };
    if (this.following) this.lastFocus = null;
    return true;
  }

  schedulePlacement(cx) {
    if (this.placementPending) return;
    this.placementPending = true;
    cx.timer.after(1, (cx) => {
      this.placementPending = false;
      if (this.updatePlacement()) cx.notify();
    });
  }

  watch(key, list) {
    this.agentWatch = { key, bindings: list.filter((b, i) => list.findIndex((o) => o.address === b.address) === i) };
  }

  bindingsOf(board) {
    return M.discoverBindings(this.hosts ?? shared("sympp.hosts"), terminals()).map((binding) => board.offline === false
      ? binding : { ...binding, available: false, unavailable: board.offline ? "Offline copy" : "Update sympp for agent access" });
  }

  // The panel keeps every topic's chiefs checked, whichever level it shows, and shares them.
  // Written outside render, and only when something differs.
  shareChiefs(now) {
    const board = this.net.data;
    if (this.role !== "panel" || this.studio) return;
    const desk = L.deskOf(this.deskTopics(), this.spaceList()), bindings = board ? this.bindingsOf(board) : [];
    const out = {}, list = terminals(), sessions = shared(CHIEF_SESSIONS) ?? {};
    const next = { ...sessions };
    let changed = false;
    this.chiefWatch = [];
    for (const { topic, entries, terminal, matches } of L.chiefEntries(desk, sessions, list, this.repoTopics, now)) {
      const last = sessions[topic.id];
      this.chiefWatch.push(...matches.flatMap((chief) => M.chiefBindings(bindings, chief)));
      if (entries.length) out[topic.id] = entries;
      const record = chiefSession(terminal, last);
      if (!record) continue;
      if (JSON.stringify(record) !== JSON.stringify(last)) {
        next[topic.id] = record;
        changed = true;
      }
      if (canResumeAgent(record.agent)) this.readSession(topic.id, record, now);
    }
    if (changed) setShared(CHIEF_SESSIONS, next);
    if (JSON.stringify(shared(CHIEFS) ?? {}) !== JSON.stringify(out)) setShared(CHIEFS, out);
    // A chief space that fell out of its topic goes back, where the desk keeps it unlisted.
    const home = L.homeChiefSpaces(this.deskTopics(), shared(CHIEF_SPACES), this.spaceList().map((s) => s.id));
    if (home) setShared("desk.topics", home);
  }

  // Refresh the conversation from herdr-core. A pending reply belongs to the observed process;
  // a replacement chief can take over before it arrives.
  readSession(topic, record, now) {
    const { terminal: address, agent, pid, session, native } = record;
    const reads = (this.sessionReads ??= new Map()), previous = reads.get(topic);
    if (previous?.address === address && previous.agent === agent && previous.pid === pid && now - previous.at < SESSION_READ[native && session ? 1 : 0]) return;
    const read = { address, agent, pid, at: now };
    reads.set(topic, read);
    hc(["get", address, "--json"]).then((result) => {
      if (result.code !== 0 || reads.get(topic) !== read) return;
      const all = shared(CHIEF_SESSIONS) ?? {}, current = all[topic];
      if (current?.terminal !== address || current.agent !== agent || current.pid !== pid) return;
      const live = recordedChief(current, terminals(), Date.now());
      const next = chiefSession(live, current, JSON.parse(result.stdout));
      if (next?.agent === agent && next.pid === pid && JSON.stringify(current) !== JSON.stringify(next)) {
        setShared(CHIEF_SESSIONS, { ...all, [topic]: next });
      }
    }).catch(() => {});
  }

  withChiefs(watch) {
    const chiefs = this.chiefWatch ?? [];
    if (!chiefs.length) return watch;
    const list = [...(watch?.bindings ?? []), ...chiefs];
    return { key: `${watch?.key ?? "none"}+chiefs`, bindings: list.filter((b, i) => list.findIndex((o) => o.address === b.address) === i) };
  }

  // Each chief terminal Herdr shows, with its topic.
  chiefTerminals(desk) {
    return L.chiefTopics(shared(CHIEFS), shared(CHIEF_SESSIONS), M.chiefsOf(terminals()), desk, terminals());
  }

  // The chiefs matching a topic, each as an agent.
  chiefsOf(topic, board, desk, bindings, now) {
    return L.chiefsFor(topic, M.chiefsOf(terminals()), desk, this.repoTopics)
      .map((chief) => ({ chief, agent: L.chiefAgent(chief, bindings, terminals(), this.agentChecks, now) }));
  }

  // An open review drill-down follows the selected package.
  selectPackage(id, cx) {
    this.pkgSel = id;
    if (this.review) this.review = { jobId: this.review.jobId, pkgId: id, round: null };
    this.keys.focus();
    cx.notify();
  }

  // A package's review drill-down, opened at a round. The rails stay drawn and scrolled as they were.
  openReview(jobId, pkgId, round, cx) {
    this.review = { jobId, pkgId, round };
    this.pkgSel = pkgId;
    this.keys.focus();
    cx.notify();
  }

  closeReview(cx) {
    this.review = null;
    this.keys.focus();
    cx.notify();
  }

  // The job's local space when one matches its repository, else the shown one.
  openInTab(job, _cx) {
    run("tab.new", J.jobTabArgs(this.given, job, spaces()));
  }

  // A UI package's studio: its open tab, else a new one in the job's local space.
  openStudio(job, pkg, _cx) {
    const tab = S.studioTabFor(shared(S.STUDIOS), this.openTabs(), pkg.id);
    if (tab) run("tab.select", { id: tab });
    else run("tab.new", S.studioTabArgs(this.given, job, pkg, this.spaceList()));
  }

  // ---------- Studio ----------

  // The studio's tab and pane once it is the package's one studio in the job's space; until then
  // null. A second studio for the package, or one opened elsewhere, hands over and closes, but only
  // while its tab holds no terminal.
  studioHere(job, pkg, cx) {
    if (this.here) return this.here;
    const f = focused();
    const paneList = panes();
    const own = f?.tab ? paneList.find((p) => p.tab === f.tab && p.mod === "sympp" && !p.terminal) : null;
    if (!own || this.handingOver) return null;
    const tab = f.tab;
    const spaceList = this.spaceList();
    const other = S.studioTabFor(shared(S.STUDIOS), this.openTabs(), pkg.id, tab);
    const mine = spaceList.find((s) => (s.tabs ?? []).some((x) => x.id === tab));
    const target = J.jobSpace(job, spaceList);
    if (!paneList.some((p) => p.tab === tab && p.terminal) && (other || (target && mine && target.id !== mine.id))) {
      this.handingOver = true;
      cx.spawn(async () => {
        if (other) run("tab.select", { id: other });
        else run("tab.new", S.studioTabArgs(this.given, job, pkg, spaceList));
        run("tab.close", { id: tab });
      });
      return null;
    }
    this.here = { tab, pane: own.pane };
    this.registerStudio(cx);
    if (mine?.tabs.find((x) => x.id === tab)?.named === false) cx.spawn(async () => run("tab.rename", { id: tab, name: S.tabName(pkg.title) }));
    return this.here;
  }

  // Records this studio and its preview copy, and marks its tab for the desk tab bar.
  registerStudio(cx) {
    const tab = this.here.tab;
    const open = this.openTabs();
    const studios = { ...S.openStudios(shared(S.STUDIOS), open), [tab]: { ...this.studio, dev: this.native.dev } };
    const before = shared(S.TAB_MARKS);
    const marks = (Array.isArray(before) ? before : []).filter((m) => m?.tab !== tab && open.includes(m?.tab));
    cx.spawn(async () => {
      setShared(S.STUDIOS, studios);
      setShared(S.TAB_MARKS, [...marks, { tab, ...S.MARK }]);
    });
  }

  // The package's worker as the factory sees it, where Herdr runs it; a different terminal is placed
  // afresh.
  findWorker(pkg) {
    const found = S.studioWorker(pkg, terminals(), (address) => this.local(address));
    if (found.address !== this.worker.address) {
      this.swapped = false;
      this.keeping = false;
    }
    this.worker = found;
  }

  // Puts the worker beside the studio: a pane on the right, then swapped to the left once.
  arrange(place, address, cx) {
    const pane = this.here.pane;
    if (place.step === "keep" && !this.keeping) {
      this.keeping = true;
      cx.spawn(async () => {
        run("pane.focus", { pane });
        run("terminal.keep", { terminal: address, place: "right" });
      });
    } else if (place.step === "swap") {
      this.swapped = true;
      // After the new pane has been drawn once, so Herdr knows where it is.
      cx.timer.after(250, () => {
        run("pane.focus", { pane });
        run("pane.swap", { direction: "right" });
        run("pane.focus", { pane: place.pane });
      });
    }
  }

  moveWorker(cx) {
    const address = this.worker.address;
    if (!address) return;
    this.keeping = false;
    cx.spawn(async () => run("terminal.park", { terminal: address }));
  }

  goToWorker(_cx) {
    const pane = panes().find((p) => p.terminal === this.worker.address);
    if (pane) run("pane.focus", { pane: pane.pane });
  }

  openPreview(url, cx) {
    if (url) cx.open_url(url);
  }

  // The local worktree the worker previews from, or null: a remote worker, or no folder.
  previewSource() {
    return this.worker.cwd ?? null;
  }

  // A local worker's sympp worktree: its Herdr view built on sample data as this package's preview
  // copy, and rebuilt on every save that touches it.
  startPreview(cwd, job, cx) {
    const generation = (this.previewRun ?? 0) + 1;
    this.previewRun = generation;
    // Node from this machine's trusted host configuration runs the worktree's preview builder.
    const node = (this.hosts ?? shared("sympp.hosts"))?.local?.node ?? null;
    if (!cwd || !node) {
      this.native = { state: "none", error: null, builtAt: null, dev: null, cwd: null };
      this.registerStudio(cx);
      return;
    }
    this.ended = false;
    this.native = { state: "building", error: null, builtAt: null, dev: S.devName(this.studio.pkg), cwd, node, base: `origin/${job.baseBranch || "main"}` };
    this.registerStudio(cx);
    this.buildPreview(cx);
    this.watchPreview(generation, cx);
  }

  buildPreview(cx) {
    const n = this.native;
    const generation = this.previewRun;
    if (!n.dev || n.state === "none" || this.landed || this.ending) return;
    if (this.building) { this.rebuild = true; return; }
    this.building = true;
    cx.spawn(async (cx) => {
      let outcome;
      try {
        outcome = S.buildOutcome(await exec(n.node, [S.builderPath(n.cwd), "--to", `${appHome()}/mods/${n.dev}`, "--base", n.base], { cwd: n.cwd }));
      } catch {
        outcome = { state: "error", error: "Node couldn't run the preview build." };
      }
      this.building = false;
      // Ended meanwhile: the copy waits for this build before it goes.
      if (generation !== this.previewRun) {
        try { cx.notify(); } catch { /* closed while building */ }
        return;
      }
      const built = outcome.state === "ready" ? Date.now() : this.native.builtAt;
      const state = outcome.state === "unchanged" && built ? "ready" : outcome.state;
      this.native = { ...this.native, state, error: outcome.error ?? null, builtAt: built };
      if (this.rebuild) { this.rebuild = false; this.buildPreview(cx); }
      try { cx.notify(); } catch { /* closed while building */ }
    });
  }

  watchPreview(generation, cx) {
    const folder = S.builderPath(this.native.cwd).replace(/\/preview\.mjs$/, "");
    cx.spawn(async (cx) => {
      for (;;) {
        let changed;
        try { changed = await watchFolder(folder); } catch { return; }
        if (generation !== this.previewRun || this.native.state === "none" || this.landed) return;
        if (changed.some(S.previewInput)) this.buildPreview(cx);
      }
    });
  }

  // The studio's own pane is a header-high strip while a preview pane shows below it. When that
  // pane goes, Herdr gives the studio's pane the column's place and size back.
  fitStrip(shown, cx) {
    if (shown === Boolean(this.stripped)) return;
    this.stripped = shown;
    const pane = this.here.pane;
    if (shown) cx.spawn(async () => run("layout.resize", { id: pane, px: STRIP }));
  }

  // The preview copy's pane below the studio's, opened once it first builds; Show preview reopens it.
  previewPane(devPane, cx) {
    const pane = this.here.pane;
    if (devPane || this.devOpened || this.native.state !== "ready") return;
    this.devOpened = true;
    const { dev } = this.native;
    const generation = this.previewRun;
    // Herdr finds a new mod folder through its file watcher, a moment after the first build. By
    // then the preview may have ended.
    cx.timer.after(800, () => {
      if (generation === this.previewRun && !this.ending && !this.landed && this.native.state === "ready") run("pane.split", { pane, direction: "down", mod: dev, props: {} });
    });
  }

  showPreview(cx) {
    this.devOpened = false;
    if (this.native.state !== "ready") this.buildPreview(cx);
    cx.notify();
  }

  // Ends this package's preview copy before another worktree's starts, once the package lands or
  // when the worktree has none to build, also a copy left from before Herdr restarted: its pane
  // closes, a running build finishes, then the copy goes. True once neither is left.
  endPreview(devPane, cx) {
    if (devPane) {
      if (!this.closingDev) { this.closingDev = true; cx.spawn(async () => run("pane.close", { pane: devPane.pane })); }
      return false;
    }
    if (this.ended) return true;
    if (this.building || this.ending) return false;
    this.ending = true;
    this.rebuild = false;
    this.previewRun = (this.previewRun ?? 0) + 1;
    cx.spawn(async (cx) => {
      try { await removeCopy(S.devName(this.studio.pkg)); } catch { /* none was made, or a sweep removes it */ }
      this.ending = false;
      this.ended = true;
      this.closingDev = false;
      this.devOpened = false;
      this.native = { ...this.native, dev: null };
      this.registerStudio(cx);
      try { cx.notify(); } catch { /* closed meanwhile */ }
    });
    return false;
  }

  studioLevel(t, board, now, cx) {
    const job = board.jobs.find((j) => j.id === this.studio.job);
    const pkg = job?.packages.find((p) => p.id === this.studio.pkg);
    if (!pkg) {
      return this.root(t, [message(t, "This package isn't here", "It isn't on this sympp board. It may have been archived, or this studio belongs to another factory.", [
        button(t, "retry-missing", this.reading ? "Reading…" : "Refresh", (cx) => this.retry(cx), { strong: true }),
      ]), O.floatingStatus(this, t, now)]);
    }
    if (!this.studioHere(job, pkg, cx)) return this.root(t, [message(t, "Opening the studio…", null)]);
    this.findWorker(pkg);
    this.landed = pkg.stage === "ended";
    const w = this.worker;
    const live = w.state === "live";
    const paneList = panes();
    const place = live ? S.placement(paneList, this.here.tab, this.here.pane, w.address, this.swapped) : null;
    const dev = S.devName(this.studio.pkg);
    const devPane = paneList.find((p) => p.tab === this.here.tab && p.mod === dev) ?? null;
    if (this.landed) this.endPreview(devPane, cx);
    else if (live) {
      this.arrange(place, w.address, cx);
      const cwd = this.previewSource();
      const restart = this.native.state === "idle" || this.native.cwd !== cwd;
      if ((restart || this.native.state === "none") && this.endPreview(devPane, cx) && restart) this.startPreview(cwd, job, cx);
    }
    const url = live ? S.previewUrlOf(terminals().find((k) => k.address === w.address)) : null;
    const kind = this.landed ? "none" : S.previewKind({ url, native: this.native.state });
    this.studioUrl = kind === "web" ? url : null;
    // Not while it closes: the resize would land on the studio pane once it has the column's place.
    this.fitStrip(Boolean(devPane) && !this.closingDev, cx);
    if (kind === "native") this.previewPane(devPane, cx);
    return this.root(t, [studioView(this, t, {
      pkg, worker: { state: w.state }, place, kind, url,
      native: this.native, landed: this.landed, strip: Boolean(devPane) && !this.closingDev,
    }), O.floatingStatus(this, t, now)]);
  }

  input(placeholder, multiline = false) {
    const state = multiline ? TextareaState.new({ placeholder, rows: 4 }) : InputState.new({ placeholder });
    state.on("change", (_e, cx) => cx.notify());
    return state;
  }

  openIntake(cx) {
    if (!this.draft.repo.value()) {
      const here = this.path.space ? L.spaceById(L.deskOf(this.deskTopics(), this.spaceList()), this.path.space)?.space : null;
      const active = this.spaceList().find((s) => s.active);
      this.draft.repo.set_value((here ?? active)?.folder ?? "");
    }
    this.intake = true;
    this.draft.title.focus();
    cx.notify();
  }

  createRequest(cx) {
    cx.spawn(async (cx) => {
      const submission = C.submitAction(this.creation, async () => {
        const fields = Object.fromEntries(Object.entries(this.draft).map(([key, input]) => [key, input.value()]));
        const payload = await this.send(`${C.OPERATOR}/work-requests`, C.requestBody(fields), cx);
        const id = payload.work_request?.work_request?.id;
        if (!id) throw new Error("The job was submitted but its ID is missing. Refresh before submitting again.");
        return id;
      }, (id) => {
        for (const input of Object.values(this.draft)) input.set_value("");
        this.intake = false;
        this.awaiting = id;
        this.go({ topic: this.path.topic, space: this.path.space, job: id }, cx);
        this.retry(cx);
      });
      cx.notify();
      await submission;
      cx.notify();
    });
  }

  // The recommended choice of a decision prompt starts selected.
  openAnswer(question, cx) {
    if (!this.answers[question.key]) {
      const recommended = question.prompt?.options?.find((o) => o.recommended)?.id ?? null;
      this.answers[question.key] = { input: this.input(question.prompt ? "Optional note" : "Your answer", true), choice: recommended, pending: false, error: null };
    }
    this.answers[question.key].open = true;
    if (!question.prompt) this.answers[question.key].input.focus();
    cx.notify();
  }

  saveAnswer(question, cx) {
    const draft = this.answers[question.key];
    cx.spawn(async (cx) => {
      const submission = C.submitAction(draft,
        async () => this.send(question.route, C.answerBody(question, draft.choice, draft.input.value()), cx),
        (payload) => {
          draft.open = false; draft.saved = true; draft.input.set_value("");
          const note = C.undeliveredNote(payload);
          if (note) notify({ title: "Answer not delivered", body: note, level: "warning" });
          this.retry(cx);
        });
      cx.notify();
      await submission;
      cx.notify();
    });
  }

  // ---------- Operator actions ----------

  // An action that asks again: armed by the first click, for a few seconds.
  arm(key, cx) {
    this.ops[key] = { armed: true, pending: false, error: null };
    cx.timer.after(4000, (cx) => { if (this.ops[key]?.armed && !this.ops[key].pending) { this.ops[key] = { ...this.ops[key], armed: false }; cx.notify(); } });
    cx.notify();
  }

  // A read as drawn: the person's actions still on their way, or agreed and not read yet, shown done. Only a
  // fresh read, begun at `since`, ends the actions it shows; redrawing the last one ends nothing.
  drawn(payload, board = null, since = null) {
    const pending = this.taken.length;
    if (since !== null) C.settle(this.taken, payload, since);
    if (board && payload === this.payload && this.net.data && this.taken.length === pending) return this.net.data;
    this.payload = payload;
    return this.taken.length || !board ? M.parseBoard(C.project(payload, this.taken)) : board;
  }

  redraw(cx) {
    if (this.payload && this.net.data) {
      this.net = { ...this.net, data: this.drawn(this.payload) };
      this.updatePlacement();
    }
    try { cx.notify(); } catch { /* closed meanwhile */ }
  }

  // One operator POST on this factory's native routes. Its outcome shows at once; the read that follows
  // its answer draws the factory's own word.
  send(path, body, cx) {
    const connection = this.connection;
    if (this.needsControlRead()) return Promise.reject(new Error("Refresh the board before trying again."));
    return C.take(this.taken, C.actionOf(path, body), () => this.operatorPost(connection, path, body),
      () => { if (!this.closed && this.connection === connection) this.redraw(cx); });
  }

  async operatorPost(connection, path, body) {
    if (this.connection !== connection || this.needsControlRead()) throw new Error("Refresh the board before trying again.");
    this.seeded = false;
    const { endpoint, factory } = connection;
    factory.writes += 1;
    const finish = () => {
      if (!this.writeFinishes.delete(finish)) return;
      factory.writes -= 1;
      factory.lastWrite = C.readStarts();
    };
    this.writeFinishes.add(finish);
    try { return await C.postAction(endpoint, path, body, this.request); }
    finally { finish(); }
  }

  // One operator action, then a fresh read. A refusal stays beside the control that sent it; `refused`
  // runs too, so a view that moved on can go back to it. Each click is its own attempt: a repeat of the
  // latest action on its task isn't sent again, but the same step after another one is (controls.js).
  operate(key, path, body, cx, refused = null) {
    const op = this.ops[key] = { armed: false, pending: false, error: null };
    cx.spawn(async (cx) => {
      const submission = C.submitAction(op, async () => this.send(path, body, cx), () => { if (this.ops[key] === op) delete this.ops[key]; this.retry(cx); });
      cx.notify();
      await submission;
      if (op.error) refused?.(cx);
      cx.notify();
    });
  }

  openFeedback(decision, cx) {
    if (!this.feedback[decision.key]) this.feedback[decision.key] = { input: this.input("What should change, and why?", true), pending: false, error: null };
    const draft = this.feedback[decision.key];
    draft.open = true;
    draft.input.focus();
    cx.notify();
  }

  // The factory delivers feedback to the decision's terminal. With `focus`, the panel then opens
  // that terminal, only once the factory reports the feedback delivered there.
  sendFeedback(decision, focus, cx) {
    const draft = this.feedback[decision.key];
    const text = draft.input.value().trim();
    if (!text) { draft.error = "Write the feedback first."; cx.notify(); return; }
    cx.spawn(async (cx) => {
      const submission = C.submitAction(draft, async () => this.send(decision.routes.feedback, { text }, cx), (payload) => {
        draft.open = false;
        draft.input.set_value("");
        if (focus && payload?.delivery?.state === "delivered") this.focusTerminal(decision.by.address, cx);
        this.retry(cx);
      });
      cx.notify();
      await submission;
      cx.notify();
    });
  }

  // Whether a terminal runs where Herdr reaches it.
  running(address) {
    const here = this.local(address);
    return terminals().some((k) => k.address === here && k.state === "live");
  }

  // A factory address as Herdr names it here.
  local(address) {
    return M.localAddress(address, this.coreName);
  }

  // The program Herdr says runs in a factory terminal ({ name, icon, tint }), if Herdr shows it.
  programOf(address) {
    const here = this.local(address);
    return terminals().find((k) => k.address === here)?.program ?? null;
  }

  // Focuses a running terminal: its pane when one shows it, else beside the shown space on its
  // machine. Only for the connected factory while it is online: a copied ledger's addresses may name
  // other terminals now.
  focusTerminal(given, cx) {
    const key = `focus:${given}`;
    const address = this.local(given);
    if (this.ops[key]?.pending) return;
    const op = this.ops[key] = { pending: true, error: null };
    cx.spawn(async (cx) => {
      try {
        await C.requireAgentAccess(this.endpoint, this.request);
        if (!this.running(address)) throw new Error("That agent isn't running where Herdr can reach it.");
        const split = address.indexOf("/");
        const destination = M.agentDestination({ address, machine: split < 0 ? null : address.slice(0, split) }, panes(), spaces());
        if (destination.pane) run("pane.focus", { pane: destination.pane });
        else {
          this.companion = destination.alongside;
          run("space.select", { id: destination.space });
          run("terminal.keep", { terminal: address, place: destination.alongside ? "right" : "tab" });
        }
        delete this.ops[key];
      } catch (caught) {
        op.pending = false;
        op.error = caught.message;
        cx.timer.after(5000, (cx) => { if (this.ops[key] === op) delete this.ops[key]; cx.notify(); });
      }
      try { cx.notify(); } catch { /* closed meanwhile */ }
    });
  }

  // Enter on a package opens its review when it has review rounds, else its running terminal.
  openPackage(cx) {
    const pkg = this.currentJob?.packages.find((p) => p.id === this.pkgSel);
    if (!pkg) return false;
    if (R.roundsOf(pkg).length) {
      this.openReview(this.currentJob.id, pkg.id, null, cx);
      return true;
    }
    if (pkg.owner?.liveness !== "live") return false;
    this.focusTerminal(pkg.owner.address, cx);
    return true;
  }

  onKey(e, cx) {
    if (!this.keys.is_focused()) return;
    const key = e.key;
    if (this.studio) {
      if (key === "r") this.retry(cx);
      else if ((key === "o" || key === "enter") && this.studioUrl) this.openPreview(this.studioUrl, cx);
      else return;
      cx.stop_propagation();
      cx.notify();
      return;
    }
    const nav = KEYS[key];
    // On the Job level keys move packages and Esc clears the package first; above it they move
    // through the level's rows. Esc then goes up a level, except in a job's own tab.
    const inJob = this.level === "job";
    const packages = inJob && Boolean(this.currentJob);
    if (key === "escape" && this.intake) {
      if (this.creation.pending) return;
      this.intake = false;
    } else if (this.intake) return;
    else if (packages && nav) this.selectPackage(R.moveRow(this.rowOrder, this.pkgSel, nav === "down" ? 1 : -1) ?? this.pkgSel, cx);
    else if (inJob && nav) return;
    else if (nav) this.cursor = R.moveRow(this.rows.map((r) => r.key), this.cursor, nav === "down" ? 1 : -1) ?? this.cursor;
    else if (key === "enter" && inJob && this.pkgSel?.startsWith("fold:")) this.toggleExpanded(this.pkgSel.slice(5), cx);
    else if (key === "enter" && inJob) { if (!packages || !this.openPackage(cx)) return; }
    else if (key === "enter") {
      const row = this.rows.find((r) => r.key === this.cursor);
      if (!row) return;
      row.open(cx);
    }
    else if (key === "escape" && this.review) this.review = null;
    else if (key === "escape" && inJob && this.pkgSel) this.pkgSel = null;
    else if (key === "escape" && !this.pinned && this.level !== "factory") this.goUp(cx);
    else if (key === "t" && this.currentJob && !this.pinned) this.openInTab(this.currentJob, cx);
    else if (key === "u" && packages && this.studioPackage()) this.openStudio(this.currentJob, this.studioPackage(), cx);
    else if (key === "p" && this.role === "panel" && !this.pinned) this.togglePin(cx);
    else if (key === "r") this.retry(cx);
    else if (key === "o") this.openDashboard(cx);
    else return;
    cx.stop_propagation();
    cx.notify();
  }

  // The selected package when the job view offers it a studio.
  studioPackage() {
    const job = this.currentJob;
    const pkg = job?.packages.find((p) => p.id === this.pkgSel);
    return pkg && this.shown && S.uiPackage(pkg, terminals(), (address) => this.local(address)) ? pkg : null;
  }

  root(t, children) {
    return v_flex().id(`lens-${this.studio ? "studio" : this.pinned ? "job" : this.role}`).size_full().min_h(0).bg(this.role === "panel" ? t.chrome : t.canvas).text_color(t.foreground).text_size(13)
      .track_focus(this.keys)
      .on_mouse_down("left", (_e, cx) => { this.keys.focus(); cx.notify(); })
      .on_key_down((e, cx) => this.onKey(e, cx))
      .on_size_change((size, cx) => { if (size.width !== this.width) { this.width = size.width; cx.notify(); } })
      .children(children.filter(Boolean));
  }

  // The view's own width once drawn; a tab beside Herdr's sidebar is narrower than the window.
  viewportWidth() {
    return this.width ?? window.viewport_size().width;
  }

  // Each render may start a fade (scopeview.js); its next step is a one-shot wake, never a loop.
  render(cx) {
    const drawn = this.draw(cx);
    const wait = Lv.motionStep(this);
    if (wait !== null) cx.timer.after(wait, (cx) => { Lv.advanceMotion(this); cx.notify(); });
    return drawn;
  }

  // The moment ages, time in step and staleness are drawn at; the preview draws at its sample's.
  now() { return Date.now(); }

  draw(cx) {
    if (this.chief) return this.chief.render();
    this.compact = this.role === "panel" || this.companion || this.viewportWidth() < 1000;
    const t = theme();
    const now = this.now();
    this.shown = null;
    this.agentWatch = null;
    this.currentJob = null;
    this.rows = [];
    this.level = this.pinned ? "job" : "factory";
    if (this.resolving && !this.net.data) return this.root(t, []);
    if (!this.endpoint) {
      return this.root(t, [message(t, "sympp isn't connected", "Give this block an endpoint prop with the local sympp address, for example http://127.0.0.1:4000.")]);
    }
    if (!this.net.data) {
      if (!this.net.error) return this.root(t, [message(t, "Reading sympp…", null)]);
      if (!this.given.remote && (this.starting || Date.now() - (shared(STARTING) || 0) < START_WAIT)) return this.root(t, [message(t, "Starting sympp…", null)]);
      return this.root(t, [message(t, this.startFailed ? "Couldn't start sympp" : "Couldn't read sympp", this.startFailed ? null : this.net.error, [
        button(t, "retry-first", this.reading ? "Reading…" : "Retry", (cx) => this.retry(cx), { strong: true }),
        ...(this.dashboard ? [button(t, "dashboard-first", "Open dashboard", (cx) => this.openDashboard(cx))] : []),
      ])]);
    }
    const board = M.withCurrentLanes(this.net.data, now);
    const bindings = this.bindingsOf(board);

    if (this.studio) return this.studioLevel(t, board, now, cx);

    if (this.pinned) {
      this.registerTab(cx, this.pinned);
      const job = board.jobs.find((j) => j.id === this.pinned);
      if (!job) {
        return this.root(t, [message(t, "This job isn't here", "It isn't on this sympp board. It may have been archived, or this tab belongs to another factory.", [
          button(t, "retry-missing", this.reading ? "Reading…" : "Refresh", (cx) => this.retry(cx), { strong: true }),
          ...(this.dashboard ? [button(t, "dashboard-missing", "Open dashboard", (cx) => this.openDashboard(cx))] : []),
        ]), O.floatingStatus(this, t, now)]);
      }
      return this.root(t, Lv.taskLevel(this, t, job, { board, bindings, terminals: terminals(), now, tab: true, topic: null }));
    }

    this.schedulePlacement(cx);
    const { desk } = this.placement;
    if (this.role === "panel" && !this.pin) this.follow(board, desk, cx);
    if (this.awaiting && board.jobs.some((job) => job.id === this.awaiting)) this.awaiting = null;
    const path = this.path = L.resolvePath(this.path, desk, board.jobs, this.awaiting);
    if (this.scoped) this.registerTab(cx, path.job ?? L.scopeTabKey(path));
    this.level = L.levelOf(path);
    const trail = L.crumbs(path, desk, board.jobs);
    const needs = M.verdictCounts(board.jobs, board.cards).needs;

    if (this.level === "job") {
      const job = board.jobs.find((j) => j.id === path.job);
      if (job) {
        const home = desk.find((x) => x.id === (path.topic ?? this.place.home(job)) && x.kind === "topic") ?? null;
        return this.root(t, Lv.taskLevel(this, t, job, { board, bindings, terminals: terminals(), now, topic: home }));
      }
      return this.root(t, [O.levelBar(this, t, trail, { now, needs, slim: true }), message(t, "Reading new job…", null)]);
    }
    if (this.level !== "factory") return this.root(t, Lv.scopeLevel(this, t, { board, desk, path, bindings, terminals: terminals(), now }));
    const top = [O.levelBar(this, t, trail, { now, needs })];
    if (this.intake) return this.root(t, [...top, O.intakeForm(this, t)]);
    const rows = L.factoryRows(board.jobs, desk, this.place, board.cards).map((row) => ({ ...row, chiefs: this.chiefsOf(row, board, desk, bindings, now) }));
    this.watch("factory", rows.flatMap((row) => row.chiefs.flatMap((c) => c.agent.bindings)));
    return this.root(t, [...top, O.factoryLevel(this, t, board, rows, now)]);
  }
}
