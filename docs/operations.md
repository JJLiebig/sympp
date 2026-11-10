# Operations

This page maps each job to its authoritative entrypoint. Agent procedures live
in packaged skills and are not repeated here.

## Install And Open

Use [Install and run](runtime.md) for Windows setup, both host connections
and upgrades. With the same factory environment, read the active dashboard URL:

```powershell
(Get-Content (Join-Path $env:SYMPP_HOME 'runtime/codex-plugin.json') -Raw | ConvertFrom-Json).frontend.url
```

The installed MCP companion starts or reuses the local backend and serves the
packaged dashboard from the same runtime.

## Work Board

The board lists goals, one per WorkRequest, with the ones that need you first:
a goal whose chief asks you something, then goals with a road bump or
stalled work, then goals on track. Parked, dormant, not-started and settled
goals sit on shelves that open on demand, and recently merged work is listed
under Landed.

Each goal shows a verdict, the architect's brief and ETA, and its packages as
Done, Now and Up next along Build, PR, Checks, Review and Merge. Outline,
Briefing and Phases (keys `1` to `3`) show the same goals in different shapes;
Show sets how much each goal opens. Choose an area to narrow the board.

The header says whether you are needed and names each open question; the tab
title and icon repeat it. A line under the header sums up what changed since
you last looked, and each figure on it takes you to the goals behind it.

Each goal is worked on by at most one Herdr terminal. The board API reports that
terminal and whether it is live, unknown or finished; if an owner crashed on a
machine the factory can't see, release it with the operator Release route so
another terminal can take the goal. See
[worked on by](operator-board-api.md#worked-on-by).

A goal can be marked done, archived or deleted from its menu, and a shelf can
be archived in one go. None of these stops a running worker or merges a pull
request. The board rereads the ledger when it changes and once a minute; if a
read fails it keeps what it last showed and says the connection is lost.

The `sympp` mark opens the settings: after how many days finished and
never-started goals are archived, when archived goals are deleted for good, and
two switches for this machine. Nothing changes until it is saved; a shorter
limit then applies at once.

The board does not create requests. Start one from a trusted local MCP session.

An optional architect report gives the goal a brief, free-text ETA, parking
reason, and explicit question requiring a human decision. The hydrated dashboard
returns it at `work_request_details[].work_request.operator_report`;
`read_work_request` returns the same report. Each brief/ETA has `text` and
`written_at`. Parking has `reason`, `parked_at`, and `resumed_at`. A missing
report/field is absent information; a non-null resume time means that interval
is closed. Questions the chief sends to the operator are asks, which the board shows as Needs
you; worker waits do not. Reports do not change blockers or completion. See the
[architect procedure](../packages/sympp/skills/symphony-architect/SKILL.md#report)
for optional milestone updates.

MCP `read_work_request` defaults to a compact overview: request description,
open asks, package status/PR/next action, and five recent decision previews.
Omission counts point to `detail: "full"` for complete contracts and history.
Its `plan`, `board` and `package` views use the same detail option; the plan
view keeps the execution graph and dependency evidence in both. Large progress documents summarize five
recent events; request full detail with the same document/cursor to read their
evidence bodies. Smaller reads retain their existing payloads. Herdr and the web
board use their own HTTP projections and keep complete detail.

Upgrade the Skills bundle and open fresh MCP sessions to load the updated tool
schemas; an existing session does not acquire the new detail options automatically.

### Herdr Execution Inspector

Install the optional Herdr plugin from the repository root:

```powershell
herdr plugin install JJLiebig/sympp --ref main --yes
```

When a Herdr tab contains an sympp architect that has written to a WorkRequest it
owns, one execution inspector opens to its right. It follows that tab's focused
agent and stays compact for a trivial WorkRequest. Larger or branching work
shows its execution frontier.

- `Up`/`Down` or `k`/`j`: select a WorkPackage.
- `Enter`: focus the one live Codex pane whose session exactly owns it.
- `p`: pin or unpin the current WorkRequest.
- `q`: close the inspector. It stays closed until the owned WorkRequest changes.

The board and inspector detail API carry the owning terminal separately from the
current observed run. Activity includes the actual stage,
native review progress and next action, dependency waits, latest update, and
current, stale, or unknown observation state. Review elapsed time is
available only when the provider supplies a start time; missing timing stays
unknown. Opening inspector details refreshes native review observations directly.
Missing panes or actors do not transfer ownership or prove completion.

The inspector shows these facts for the selected package, with pane connected,
missing or disconnected reported separately from
runtime freshness. Unknown timing and observations remain explicit.

## Choose A Flow

| Need | Entry point |
|---|---|
| Implement one assigned package | [sympp worker](../skills/sympp/references/symphony-worker/procedure.md) |
| Clarify and slice a WorkRequest | [sympp architect](../skills/sympp/references/symphony-architect/procedure.md) |
| Turn an idea into a WorkRequest and settle product calls | [sympp chief](../skills/sympp/references/symphony-chief/procedure.md) |
| Inspect human progress | Work board and Herdr execution inspector |

All agent-facing sympp ledger reads and writes use configured MCP tools.
Workers given ordinary tasks need no backend. Shell commands remain for installation, startup, diagnosis, upgrade,
and recovery; recover MCP before continuing required ledger work.

The packaged skill is the procedure. Assignment text should contain only the
specific goal, scope, evidence, constraints, review requirement, and desired
output.

## WorkRequest Flow

1. Create a WorkRequest from a Herdr terminal (`own: false` when handing it to
   an architect).
2. Give an architect the WorkRequest id; its first plan write makes its terminal
   the owner.
3. Answer the asks the board shows as Needs you, and acknowledge or give
   feedback on the decisions agents flag for review.
4. Let the architect plan WorkPackages, optional group paths and dependencies.
5. Dispatch dependency-ready WorkPackages to isolated workers.
6. Merge reviewed pull requests.
7. Reconcile or record terminal delivery evidence.

Use [delivery recovery](runbooks/delivery-recovery.md) when GitHub and the
ledger disagree after a merge or abandoned execution.

## Developer Visual QA

Create a disposable deterministic ledger with one of `simple`, `multi-repo`,
`superseded`, or `large`:

```powershell
cd elixir
mix sympp.demo_ledger --database .tmp/demo.sqlite3 --scenario large --force
mix sympp.cockpit --database .tmp/demo.sqlite3
```

Open the printed cockpit URL. The scenarios only seed synthetic local ledger
data; production dashboard code does not select or depend on them.

For work on the board itself, `npm run dev:snapshot` in `elixir/assets` serves
it from a captured ledger snapshot without a backend, with replay and sample
goals.

## Runtime Problems

Use [Runtime](runtime.md) for Skills ownership, startup, cache identity,
and diagnostics. Do not repair an installed runtime from a developer checkout.
