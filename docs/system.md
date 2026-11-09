# Current System

sympp is a local planning and orchestration cockpit. Humans see product
progress while agents receive bounded assignments from the same ledger.
Delivery tracking usually begins after a human and agent have agreed on a
sufficiently concrete goal. Ordinary coordinators and workers can operate
without a backend when persistent planning is not requested.

This guide describes implemented behavior. The approved beta direction is in
[Factory workflow](design/factory-workflow.md).

## Work Model

| Entity | Purpose |
|---|---|
| WorkRequest | Product goal, repository, base branch, constraints, asks, decisions, plan, and delivery state. |
| WorkPackage | Canonical bounded assignment from architect planning through worker execution and delivery. |
| Card | One Herdr terminal's own work outside a WorkPackage (branch, PR, CI, review, asks), observed by the factory with no agent setup. |

A WorkPackage owns its goal, file scope, delivery repository/base, acceptance
criteria, optional validation/stop/review context, optional group path,
worktree, branch, PR, progress, readiness, blockers, and terminal
delivery evidence.
Dispatch activates that record; it does not create a second execution record.

A package's group is a text path such as `Backend / Billing`; the boards nest a
path under its first segment. Groups have no records of their own, and simple
WorkRequests leave packages ungrouped. Dependencies between packages form one
effective graph for cycle detection, unmet prerequisites, and dispatch
readiness. Visual card order and grouping do not create dependencies. The
architect changes the plan with one atomic `edit_plan` call per change and reads
it with `read_work_request` views.

A WorkRequest's phase is derived on read from its packages and their endings;
only the operator overrides are stored. The first match wins: `archived`
(archived by the operator or retention), `done` (completed by the operator),
`intake` (no packages), `active` (a package is dispatched or ready), `planned`
(a package is still planned, even beside ended ones), `unresolved` (every
package ended, but every one was skipped or one does not resolve the goal) and
`done` (every package that was not skipped resolves the goal). Finished,
merged and no-PR endings resolve a goal; abandoned work does not, unless
delivered successors replace it. Superseded work requires every successor from
both its immutable delivery pointer and same-request `superseded_by`/`recut_as`
lineage to resolve; missing or cyclic successors leave the goal unresolved.
Open questions never change the phase. Writes to an archived WorkRequest are
refused until the operator restores it; nothing restores it implicitly.

A terminal gets a card when it is a child of a chief or architect terminal, or
is labelled `sympp.card=1`, and works on a branch other than its base or has a
PR; dispatched workers (`sympp.role=worker`) never do. The factory's Observer
reads the terminal from its herdr-core, the branch from `git` in the terminal's
directory, and the PR, CI and Review Suite state (by the terminal's
`sympp.review_id` label) in the same sweep that watches packages. A card is
`working`, then `review_ci` once a PR is open, and ends `merged`, `done` (PR
closed, or terminal finished without a PR) or `dismissed` by the operator.
Unknown inputs never end a card. Cards create no WorkRequest, WorkPackage, or
dispatch. All ledger operations use MCP. The packaged
[agent skills](../packages/sympp/skills/) own operating procedures.

## Review And Delivery Authority

The owning architect can optionally set a goal brief, free-text ETA and parking
reason with `set_report`; `null` clears a field. The report is stored on the
WorkRequest, and the dashboard and `read_work_request` expose it as
`work_request.operator_report` with server-written times. Partial edits preserve
other fields; resuming parked work keeps the reason and its times. Reports
neither create/clear blockers nor change the WorkRequest phase. There is no
worker reporting cadence.

Asks are the only "Needs you". Any Herdr terminal opens one with `ask` on a
WorkRequest, optionally naming a package and a decision prompt. An ask is
`open` until it is `answered` or `withdrawn`. Both boards show open asks as
Needs you. The operator answers in the Herdr panel or through the operator HTTP
route, and the factory types `Answer: <answer>` into the asking terminal's
input without submitting it. Only terminals the factory's own herdr-core sees
live receive it; for a finished terminal or one on another machine, the answer
stays on the ask. The asker or the WorkRequest owner records an answer given in
conversation, or withdraws the ask, with `resolve_ask`, optionally recording a
decision in the same step. An ask on a package is withdrawn when the package
ends; archiving or completing the WorkRequest withdraws all of its open asks.
Asks never block planning, dispatch or a phase.

A chief or architect that makes an in-scope product call itself records it with
`record_decision(flag: true)`; any Herdr terminal may. The decision starts
`recorded` and waits on the board. The operator acknowledges it or sends
feedback over HTTP, and the factory types `Decision feedback: <text>` into the
recording terminal through the same delivery as answers. Feedback that can't be
typed stays on the decision, marked undelivered with its reason, until the
operator dismisses the marker.

A declared review requirement identifies a provider and optional arguments,
such as `review-suite` with its selected mode. It can also name another plugin
or a human process. Results remain with the provider and worker handoff;
sympp does not require a duplicate review-completion record.

The worker procedure owns required checks and review convergence. MCP readiness
checks ledger prerequisites and current provider-backed PR metadata; a ready
state alone is not proof that every test or review requirement passed. See the
[worker procedure](../packages/sympp/skills/symphony-worker/SKILL.md)
for the authoritative handoff.

GitHub owns commits, PRs, checks, and merge state. sympp records the delivery
outcome so its completion projection is auditable and idempotent.

## Runtime Shape

```text
Codex MCP client
  -> installed plugin bridge
  -> local HTTP MCP endpoint
  -> sympp Elixir runtime
  -> local SQLite ledger
```

The first installed client starts the backend when necessary; later clients
attach to the same singleton. The launcher prefers loopback port `19998`, then
higher available ports. MCP and the packaged dashboard share that endpoint;
the runtime file records both URLs. Port `19999` belongs to source/Vite
development. See [Runtime](runtime.md) for lifecycle and installation details.

## System Boundaries

| Layer | Owns |
|---|---|
| Ledger | Requests, packages, questions, decisions, dependencies, ownership, progress, and delivery evidence. |
| MCP | Discovery, reads, owner-gated mutations, dispatch, readiness, and recovery. |
| Dashboard | Human projection of ledger, GitHub state, and runtime activity. |
| Plugin packages | Installation, launchers, and authoritative agent procedures. |
| GitHub | Branches, commits, PRs, checks, reviews, and merge truth. |

Workers receive a complete assignment, run native checks/review, and return a
normal PR or evidence handoff. The architect owns dispatch, readiness, blockers,
and delivery reconciliation from the Herdr terminal that owns the WorkRequest;
workers make no sympp calls. The server derives repository, base branch and
worktree context from the ledger and validates supplied context against it.
Tool discovery is not authorization: writes still check terminal identity,
WorkRequest ownership and lifecycle state. See [Security](security.md).

`SPEC.md` and the non-sympp parts of `elixir/` describe upstream Symphony:
tracker polling, workspace management, Codex app-server execution, and runtime
observability. sympp adds its local ledger, MCP orchestration, plugin
runtime, dashboard, and GitHub delivery workflow alongside that behavior.

`ToolCatalog` and MCP handlers own live schemas and behavior.
[`mcp_contract.json`](../elixir/priv/symphony_plus_plus/mcp_contract.json) exports
the artifact fingerprint and complete tool-name sets for non-Elixir release
smoke tests. A runtime test keeps those names aligned with `ToolCatalog`; the
artifact does not duplicate schemas.

Every chief, architect or card terminal is served the same 14 tools, one schema
each; worker terminals get none. A refused tool call's `error.data` carries
`code`, `message`, `state` (the actual WorkPackage status, WorkRequest phase or
ask state, or `null` when the call names nothing that exists) and
`next_action`. Protocol and session errors keep their `reason`. Failed tool calls
are counted per day, tool, reason and layer in the ledger, without arguments;
`summarize_failed_mcp_calls` reads the counts.

### Qualified candidate dependencies

An architect can set `candidate_head_sha` with an `edit_plan` `set_dependency`
op after qualifying that exact backend WorkPackage head through its native checks
and review handoff. A current pin plus the backend's `ready` status and matching branch/PR head enables
wiring and technical review before backend merge. Readiness alone does not prove
checks or review passed. Without a pin, dispatch waits for actual delivered scope,
including all required successors; skipped or abandoned attempts do not count.
Set the pin to `null` to remove it.

The architect records which backend selections the dependent's current PR head
consumed with `sync_pr(dependency_inputs)`; a green PR can't prove it. The
[architect procedure](../packages/sympp/skills/symphony-architect/references/operations.md#ui-collaboration-and-candidates)
owns approval, selection, recording and review-owner handoff.

Clearing a previously consumed pin also invalidates that input evidence. Once the
prerequisite has delivered, record fresh qualification with `candidate_head_sha: null`
to qualify the delivered input. Dependencies
that have never carried a candidate pin continue to require only delivery.


The plan view of `read_work_request` exposes each dependency's constraints. A changed pin or candidate head makes affected input provenance stale.
After qualifying the new input, append its selection for the current dependent head;
other edges retain their valid selections. Repinning never refreshes old evidence.
Ready packages remain immutable: create and qualify a successor before retiring the
old candidate, then select that successor and requalify affected wiring. Provider
review results stay with their provider; input provenance is not a review receipt.

A ready-for-merge package can acquire a new integration blocker without changing
its readiness or reviewed evidence. The architect declares and clears it with
`set_blocker`, following the
[architect blocker procedure](../packages/sympp/skills/symphony-architect/SKILL.md#guidance).
An active blocker makes the delivery board's `merge_eligibility.eligible` false.
Workers route human decisions through the architect or chief.

Before merging, the architect checks the delivery board's `merge_eligibility`,
current selections, and native checks/review. Backend delivery must precede UI merge,
and pinned heads must still match after backend delivery. External merges are
recorded truthfully even when out of order; the board flags `delivery_order_violation`
for remediation, including after the backend eventually delivers.

Dispatch takes a review mode (`fast`, `normal`, `deep` or `none`), prepares the
package's factory worktree, writes the worker's assignment file under that
worktree's git dir, mints a Review Suite id (none for mode `none`) and returns a
ready `hc run` launch line labelled `sympp.role=worker`. Dispatching a dispatched
package again reuses its worktree and review id. If the worktree can't be
prepared, the package stays dispatched and the response carries the error and
next action. In a worker terminal the sympp bridge serves no tools. See the
[architect procedure](../packages/sympp/skills/symphony-architect/SKILL.md#dispatch).
The board view of `read_work_request` defaults to compact summaries; `detail: "full"`
restores all nested package and delivery evidence. Structured results remain JSON
and agent text uses TOON.
The factory's Observer watches dispatched packages: worker terminals through the
factory host's herdr-core, PRs, CI and merges through one batched GitHub GraphQL
read per minute, and the Review Suite cycle by its review id on the worker's
machine. It qualifies, unqualifies and records merges itself; `sync_pr` attaches
PRs it can't find and records consumed dependency inputs. A package whose GitHub
or review state can't be read is flagged `stale` and changes nothing.
Terminal packages have no pending merge next action. WorkRequest reads expose
the derived `phase`, plus `next_action` when the operator has to act
(`complete_or_archive` for `unresolved`, `restore` for `archived`). Native Herdr
views show `done` and `unresolved` goals as Done and retain the dropped-package
count.
These contract changes require updated Skills and fresh MCP sessions after upgrade.
