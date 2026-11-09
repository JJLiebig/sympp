# sympp in Herdr-next

The optional native view runs inside **herdr-app**. sympp keeps its standalone
backend, ledger, web UI and orchestration workflows. Agent terminals run in
**herdr-core**, independently of the desktop window.

Implementation and delivery status live in the
[sympp × Herdr-next contract](../../docs/design/herdr-next-integration.md).

## Install the view

Use the URL recorded by your running sympp factory, rather than assuming a port:

```powershell
$runtime = Get-Content (Join-Path $env:SYMPP_HOME 'runtime/codex-plugin.json') -Raw | ConvertFrom-Json
$origin = ([Uri]$runtime.frontend.url).GetLeftPart([System.UriPartial]::Authority)
node integrations/herdr-next/install.mjs --endpoint $origin --open overview
```

The view opens at the Factory: what needs you, ranked by how many packages
wait on each answer, the decisions agents flagged for review, then one row per
Herdr topic, whose chevron lists its open tasks in place. A topic shows each
task touching it as its name and a strip of its packages, coloured by progress,
and the small work (cards) on its repositories; a space shows the same for the
tasks on its repository. Only asks show **Needs you**: answer them in place,
with the decision prompt's choices when there is one. A flagged decision takes
**Ack** or **Feedback**; the factory types the feedback into the terminal that
made the call, and **Focus chief** also opens that terminal. A task shows its
phase and the terminal working on it, and its packages at work under their
groups, through Launching ─ Implementing ─ Review/CI ─ Ready, with the PR's
checks and the review's mode and state; landed and planned work is folded.
**Complete**, **Archive**, **Restore** and **Delete** act on the task, **Finish**
ends a package whose PR goes into another repository, and **Release** frees a
task from an owner that stopped answering. Click a terminal's address to focus
it. Click a row, or use ↑/↓ (j/k), Enter and Esc. Each copy remembers where it
was. A toast appears when something newly needs you; click it to open the
job's tab.

Herdr-app must already be open. If its executable is not on `PATH`, pass
`--app <executable>`. `--home <folder>` selects an isolated Herdr-app home;
otherwise the installer follows `HERDR_APP_HOME` or `~/.config/herdr-app`.
For a nondefault local core, pass `--session <name>`; the installer otherwise
retains its `HC_SESSION` when set.
Use `--factory <runtime/codex-plugin.json>` to select the local factory to start;
it defaults to `SYMPP_RUNTIME_FILE`, then `SYMPP_HOME/runtime/codex-plugin.json`, for the view.
Without `--open`, it installs the files and prints the Herdr command to open
them later.

For a native panel beside the focused terminal:

```powershell
node integrations/herdr-next/install.mjs --endpoint $origin --open panel
```

The panel follows what you focus in its tab: an sympp agent's terminal or a job
tab shows that job; otherwise the space, or its topic when no sympp work touches
the space. It never takes focus. Pin (P) keeps it where it is. The expand button
beside the pin opens what the panel shows as a tab, or selects the one already open.

When the factory the view was installed for isn't running, opening sympp starts it. While any sympp
view is open, sympp counts Herdr as a client, so it stays up after the last agent session closes.

The installer adds `mods/sympp` and the agent helper `tools/sympp-herdr.js`.
Updating removes the former HTTP helper and its private request directory.
It leaves layouts, topics, compositions,
settings and terminals intact. Existing edits are protected; use `--replace`
explicitly to install this version over a differing copy. Close an sympp pane
with Herdr's ordinary pane or tab controls.

## Contract for desk mods

sympp ships its view, `mods/sympp` data publishers and icons. The desk mods are
owned by jjstack; setup and `sympp update` never patch them or their layouts.
Old `data/sympp-chrome` backups are left alone. Setup checks only the sympp mod
and restores changed files on failure. Manual installs can request this with
`--check` (requires Herdr-app).

The desk mods currently consume:

- `shared('sympp.agents')`: map keyed by terminal address, including the machine
  prefix for remote terminals (for example `vps/t7`). Each entry has `stage`
  (`build`, `checks`, `review`, `merge`, `landed` or null), `round` (review round,
  otherwise null), `needs` (boolean), `endpoint` (factory origin) and `at`
  (Unix milliseconds). Entries refresh after 45 seconds even when unchanged;
  desk-agents dims stages older than two minutes. Dropped packages have null stage.
- Terminal labels: `sympp.launch_id` with `sympp.work_package_id` or
  `sympp.work_request_id`, or `sympp.session_id` with
  `sympp.session_work_package_id` or `sympp.session_work_request_id`.
  desk-agents uses these to identify sympp terminals even without board data.
  Workers started by a dispatch's launch line carry `sympp.role=worker` and
  `sympp.work_package_id` instead; `sympp.agents` covers them from the board.
- `shared('sympp.chiefs')`: map from topic ID to arrays of `{ domain, terminal }`.
  `terminal` is present only while confirmed running. desk-topics uses it for
  chief marks and navigation. `shared('sympp.chief.spaces')` maps space IDs to
  topic IDs so chief spaces can be hidden from ordinary space rows.
- `shared('workspace.tab_marks')`: array of `{ tab, icon, iconDark?, label }`;
  sympp publishes its studio marks here. desk-tabs reads the first mark per tab.
- `shared('sympp.board')`: array of live jobs `{ id, title, stage, needs, failed }`,
  where stage is the furthest active package stage or null. desk-status renders
  these and writes `shared('sympp.open')` as `{ job, at }` to select a job in sympp.
- `shared('sympp.dashboard_url')`: the web board's address, or null when there is
  none. A sympp view with its own connection publishes it after each good read;
  desk-tabs links to it beside the sympp panel button.
- Icons under `mods/sympp/`: `glyph.svg`, `glyph-dark.svg`,
  `stage-build.svg`, `stage-checks.svg`, `stage-review.svg`, `stage-merge.svg`,
  `stage-landed.svg`, `needs.svg`, `glyph-ui.svg`, `glyph-ui-dark.svg`,
  `mark.svg`, `mark-dark.svg`, `mark.png` and `mark-dark.png`.
  The glyph pair decorates agents, the UI glyph pair marks studios, and the
  mark SVG/PNG pairs serve chief marks and the desk-tabs panel button.

jjstack's desk-tabs owns the `workspace.panel_buttons` registration for sympp
(`id`, `label`, `icon`, `iconDark`) and expects a layout child named `sympp` in
`panel-body`. desk-topics opens sympp overlays with `role: 'chief'` and
`{ topic, name }`, or `role: 'chief-menu'` and `{ topic, name, terminal }`.
These entry points remain part of the desk integration.

Contract changes only add fields. Flag any breaking change to the user before
it ships so the jjstack desk mods can follow.

## UI studio

A UI package gets a studio: a tab named after the package, in the job's local
space, with its worker's terminal on the left and a preview on the right, like a
chat beside its canvas. A package is UI work when its title names UI as a word
("UI studio tab", "Token UI") or its worker has published a preview. Open it with
**Studio** under the selected package in a task view, or U. Opening it again
selects the open studio. An architect launching a UI worker can open the studio
with only the ids, once any sympp view has connected:

```powershell
herdr-app do tab.new '{"name":"<package title>","mod":"sympp","props":{"studio":{"job":"<work request id>","pkg":"<work package id>"}}}'
```

A studio opened outside the job's space moves there; a second one for the same
package hands over to the first. Neither closes a tab that holds a terminal.

The worker is the terminal the factory sees working on the package, while Herdr
runs it; the studio places nothing else. A worker without a pane is brought
into the studio; one shown in another tab stays there until you choose
**Move here** (or **Go to it**).

The preview shows, in order:

- **A web page** the worker published with `sympp.preview_url` on its terminal
  (see the [worker UI collaboration procedure](../../packages/sympp/skills/symphony-worker/SKILL.md#ui-work)),
  as its address with **Open** (O or Enter) for the browser. Herdr mods cannot
  embed a browser; a rendered picture of the page is a later addition.
- **The Herdr view itself** when the worker is local and its folder (its worktree) changes
  `integrations/herdr-next/mods` against the job's base branch. The worktree's own
  `preview.mjs` builds that view on the sample board as `mods/sympp-dev-<package>`
  in the Herdr home and rebuilds on every save, so changes show within seconds. The
  copy makes no sympp reads or writes; your own `sympp` mod is never written. The
  copy goes when the package lands, or about a minute after its studio closes
  while any sympp view is open.
- Otherwise it says the agent hasn't published a preview yet.

For normal installations, follow the
[installed runtime procedure](../../docs/runtime.md); healthy clients retain
their current runtime until a supported cutover.

## Factory-floor lab

A separate prototype shows one job as a factory floor on a built-in sample job.
Packages stand in rooms (Your desk, Yard, Build bay, Checks, Review room,
Merge dock, Shipped), walk the corridor between them and circle the review
track once per round. It needs no sympp backend and never replaces the view:

```powershell
node integrations/herdr-next/install.mjs --lab --open overview
```

`--home`, `--app`, `--open panel` and `--replace` work as above. Without
`--open`, open it later in Herdr with
`herdr-app do tab.new '{"name":"sympp Lab","mod":"sympp-lab"}'`.

The replay bar steps through the job; Motion turns animation off, since Herdr
animations do not follow the system's reduced-motion setting. Keys: ←/→ step,
Home/End jump to the start or now, Space replays, ↑/↓ select a package and M
toggles motion. The same actions are Herdr commands (`sympp-lab.next`,
`.prev`, `.first`, `.last`, `.play`, `.motion`, `.up`, `.down`) for
`keys.json` or `herdr-app do`.

## Machines and access

The endpoint belongs to the sympp factory; it is independent of the machine
hosting a terminal. Native reads and actions use the backend's direct local
consumer policy. A remote core does not make its sympp server local to the app.
Use an explicitly managed authenticated tunnel for a remote factory; do not
expose its loopback API publicly or assume every machine shares a filesystem.

Terminal bindings identify the core and the launched process. Recovered shells
are not resumed agents. The terminal sympp says works on a task is displayed as
an observation, without claiming that its agent is still alive.

Start chief labels the chief's terminal `sympp.role=chief` and
`sympp.domain=<topic>`. The panel finds a topic's chiefs from those labels, and
the sympp bridge forwards them, so the factory attributes the chief's requests
and dispatches to the topic. Labels name a chief; they never make it live.

Focusing a terminal needs an online factory and its own word that the terminal
is the one it records: an address is a link only while the factory sees that
terminal live, and **Focus chief** opens the chief only after the factory has
delivered the feedback to it. An offline copy can retain identical job IDs; it
cannot authorize agent access.

Reads and actions use Herdr's `fetch` directly, without a Node process per
refresh or private request files. The installed Windows Herdr-app 0.1.4 was
qualified for loopback GET and JSON POST without browser or forwarding headers.
Responses retain their real HTTP status; the view never automatically retries
a write.

Native sympp routes do not redirect. Herdr fetch can follow same-origin redirects;
its [redirect policy](https://github.com/herdrdev/herdr-app/blob/b975f5beaa6909cd7806a40096859c5e47938a19/vendor/gpui-kit/crates/shell/src/engine/quickjs/standard/fetch.rs#L341-L355)
refuses cross-origin redirects for non-GET methods (line 341) and requests with
caller-supplied headers (line 351). Every sympp request sends `Accept`, and JSON
POSTs also send `Content-Type`. A redirect flag or changed response URL makes
the request fail before its JSON can be parsed or shown, retaining the returned
status for diagnosis.

Agent navigation and execution still need Node.js and the separate
[optional Herdr-next execution guide](../../docs/herdr-execution.md).
Fresh cross-provider handoffs carry a bounded task and evidence. Continuing an
existing agent depends on its reported status and the core's supported send
conditions; it is not a shared provider transcript.

## Qualification

```text
node --test integrations/herdr-next/*.test.mjs
herdr-app check integrations/herdr-next/mods/sympp
herdr-app check integrations/herdr-next/mods/sympp-lab
```

Use an isolated `HERDR_APP_HOME` and core session when checking native behavior.
Native rendering and real provider launches require their own evidence;
passing model or HTTP tests does not prove either.
