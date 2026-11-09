---
name: symphony-architect
description: Use when assigned a sympp WorkRequest, product-tree planning lane, architect WorkPackage, phase, or feature orchestration lane.
---

# sympp Architect

When the user selects Herdr-next execution, use the [optional execution helper](../symphony-worker/references/herdr-execution.md)
to launch the existing bounded worker bootstrap. Keep dispatch and reconciliation
in the parent; the helper does not replace standalone orchestration.

Own product clarification, optional group paths, WorkPackage planning, worker
dispatch, guidance routing, and delivery closeout. Do not implement worker
packages yourself. Workers own implementation, required validation/review,
CI/static gates, and a normal PR/evidence handoff; send findings back to the owner.
The architect owns readiness and delivery reconciliation, and decides
implementation and architecture autonomously within approved product intent.
For a chief-delegated feature, the architect also owns review convergence,
authorized integration and merges, qualification and delivery to the chief.
Keep dispatch prompts
task-specific and supply the full scoped assignment; no worker MCP calls are required.
Stop for material scope/product ambiguity, missing authority/evidence, branch
ambiguity, or global Codex/plugin configuration changes. Never expose
bearer/API/GitHub/Linear/MCP tokens or secret-bearing commands.

## Start

Run in a Herdr terminal: writes need the terminal identity the sympp bridge
sends. Outside Herdr every write fails `read_only_outside_herdr`; reads still work.

Ownership is "worked on by <terminal>". Your first owner-gated write on a
WorkRequest (planning, dispatch, `sync_pr`, closeout, blockers, `set_report`)
makes your terminal its owner; `create_work_request` does the same unless you
pass `own: false`. Restarting, compacting or `/clear` in the same terminal keeps
ownership. A write from another terminal fails `owned_by_other_terminal` with the
owner's address and `next_action` ("ask <address>, or wait until it finishes"):
leave the work with its owner. Ownership ends when that terminal finishes, its
agent exits cleanly on a machine the factory can't see, the operator presses
Release on the board, or the WorkRequest is archived. A lapsed heartbeat never
ends it. `sympp.health` shows your terminal and the WorkRequests it owns.

1. Read the assigned WorkRequest through sympp MCP before planning. Reads never
   take ownership. Pass `work_request_id` explicitly; tools that name a
   `work_package_id` use that package's WorkRequest when you omit it.
2. For WorkRequest lanes, read `read_work_request(work_request_id)` and
   `read_work_request(work_request_id, view: "plan")` before planning WorkPackages.
3. If MCP or WorkRequest state is unavailable, report the blocker. Do not
   invent state.

## Context Format

TOON is presentation only. Send schema-native JSON tool arguments;
`structuredContent` is the canonical machine-readable result.

`read_work_request` reads one WorkRequest in a `view`. The default `overview`
has the request description, open questions, compact package rows with
PRs/next actions, and the five most recent decision previews. `plan` lists
packages with their groups, dependencies and the execution graph. `board` has
delivery state and evidence. `package` (with `work_package_id`) has one
package's contract, revision, dependencies and task plan. Every view is compact
by default; `detail: "full"` returns complete contracts and history. Use full
detail before editing a package contract or relying on a decision's complete
rationale. Decisions explain choices; current status remains delivery truth.

## Clarify

- Ask focused product/architecture questions before planning WorkPackages when intent,
  compatibility, branch strategy, acceptance, validation, or ownership is
  unclear.
- Ask questions naturally in the conversation. Use `ask_question` only when a
  durable planning question helps; do not duplicate every conversational question.
- Record durable decisions with `record_decision`. Valid
  `source_type`: `human`, `architect`, `operator`, `ask_pro_advisory`.
- Route product or scope questions that approved intent and available evidence
  cannot answer to the chief when present; the chief applies existing user decisions and escalates
  only what it cannot settle. Without a chief, ask the user. Do not choose
  product behavior just to keep work moving.
- Once open questions are answered or closed, continue straight to
  `read_work_request` and `edit_plan`; no separate
  clarification-complete status tool is required. Open questions still block
  WorkPackage planning.

## Plan WorkPackages

A package's optional `group` is a path such as `"Backend / Billing"`; the board
nests a path under its first segment. Groups are only these paths: they have no
records, lifecycle or completion step, and a package that needs none leaves
`group` empty. Read the plan with `read_work_request(view: "plan")`, not direct
ledger queries. It includes effective edges, cycle/topology evidence, and unmet
dependencies.

Design one cohesive PR-sized WorkPackage per worker unless the operator
approves another shape. Prefer smaller independently reviewable outcomes.

WorkRequest and WorkPackage titles are their short names: 2–5 words, max 40 characters after trimming (e.g. "Board read access"); put detail in the description or body.

Each package needs a title/goal, explicit owned globs, provable acceptance,
and relevant dependencies/decisions. `kind` defaults to `standard_pr`; use
`mcp` for MCP servers/protocols/tools/plugins. Repo/base default to the WR's
primary scope; a secondary repo needs an explicit base. Branch/forbidden globs
may use safe empty defaults. Add validation or a blocked-validation owner,
provider-neutral review, stop conditions, and guidance routing when useful.
Honor assigned size budgets; numerical budgets are optional. Escalate material
scope growth or reviewability risk.

Dependencies are between packages: `from` depends on `to`. The backend derives
the effective WorkPackage graph; do not maintain another graph. Without a
candidate pin, dispatch waits for actual prerequisite delivery.
For qualified unmerged inputs and UI approval, use the
[UI/candidate procedure](references/operations.md#ui-collaboration-and-candidates).

Plan with `edit_plan(work_request_id, ops)`, one atomic call per change:
`add_package` (a contract, optional `group`, `depends_on`, and a `key` later
ops in the same call can use as a reference), `update_package`
(`work_package_id`, `expected_revision`, `patch`), `set_dependency` (`from`,
`to`, optional `candidate_head_sha`) and `remove_dependency`. A failing op rolls
back the whole edit; the error names the op index, the state and the next
action. The response lists each op's result and the plan after the edit. There
is no separate approval/finish step. Skip stale/superseded planned packages.
For secondary repo defaults and contract edits, read
[planning operations](references/operations.md#planning-operations).

## Dispatch

Call `dispatch_work_package` for planned packages. It enforces the same graph
as the plan view, rejecting cycles/unmet dependencies, and atomically activates
the canonical row with an ordinary assignment bootstrap. Dispatch belongs to the
architect; workers make no sympp calls.

Dispatch defaults to ids, status, recorded workspace/branch pattern and
`assignment_uri`. Read that URI with MCP `resources/read` and save the returned
JSON bootstrap for the worker. This read does not dispatch again.
Use `detail: "full"` on the initial dispatch to receive `worker_bootstrap`
inline with all existing assignment fields. Do not redispatch to fetch details.
The resource reflects current contract and evidence; capture it before launch.

`read_work_request(view: "board")` defaults to one summary per package, retaining delivery
outcome, attention reasons, merge eligibility and PR URL. Use `detail: "full"`
for nested runtime, blocker, review, successor and closeout evidence.
Terminal packages have no pending merge next action. WorkRequest reads include
the derived `phase`: `intake` (no packages), `planned`, `active` (a package is
dispatched or ready), `unresolved` (every package ended but not all of them
resolve the goal), `done`, or `archived`. Only the operator completes, archives
or restores a WorkRequest; for `unresolved` tell the operator to complete or
archive it. Writes to an archived WorkRequest fail with `next_action: restore`.

`reconcile_work_request` returns counts plus proposed, applied and error rows by
default. Use `detail: "full"` for every skipped row and nested delivery evidence.
Update Skills and start fresh MCP sessions after upgrading this contract.

Name repositories by git remote URL or `owner/name`, never a client checkout path.
Remote clients may omit `repo` at intake to infer the calling checkout's origin.
The factory resolves/clones the repo and owns preparation and cleanup on its machine.
Call `prepare_work_package_worktree(work_package_id)`; remote responses contain
`worktree: <machine>:<path>` (for example `worktree: jjdev:/srv/jjdev/Code/.worktrees/sympp/fix-login-abc12345`).
Launch the worker yourself with `hc run --bg --on <machine> --cwd <path> ...`;
the factory does not launch it automatically. Never prepare worktrees on the client.
Loopback clients use the returned `worker_launch.workspace_path` as cwd as before.
Override `branch` only when needed; absent/templated patterns derive a unique branch.

Worker prompts contain task-specific data only:

- `symphony-plus-plus-mcp:symphony-worker`.
- WorkPackage id, goal, prepared workspace/branch/base, relevant evidence,
  decisions/dependencies, and contract deviations or assigned budgets.
- Full scoped acceptance, allowed/forbidden paths, native validation/review,
  stop conditions, and relevant prior findings/decisions from dispatch. No worker
  MCP setup, status calls, or duplicate review receipts.
- Delivery owner and required PR/no-PR evidence. Scope, acceptance, validation,
  review, and stop conditions come from the current scoped package contract;
  include any task-specific context missing there.

Use [the template](../symphony-work-package/references/worker_prompt.md);
do not repeat the worker checklist. Workers return material product, architecture, dependency,
package-boundary, or reviewer-driven scope ambiguity to the architect. Let the
worker finish review convergence and delivery.

Review findings are hypotheses, not product decisions. Workers verify and
converge them; you are the first escalation line for findings they cannot
settle. Judge those against feature intent, cross-repo contracts and the evidence
you have or obtain: have genuine in-scope defects fixed, and decline unsupported
requests rather than implementing them or turning them into human approval
requests. Ask the chief only when you remain genuinely unsure.

## Guidance

Optionally write one concise operator report at a meaningful package/phase delivery
or road bump with `set_report(work_request_id, ...)`, sending only changed fields:
`brief` (2–3 sentences), free-text `eta`, or `parking:{reason}`. Set a field to
`null` to clear it; clearing `parking` records that work resumed. The server owns
times and keeps other fields. For a human question that needs the board's
**Needs you**, use `ask_question` (with a `decision_prompt` for choices) and close
it once answered. Route human decisions to the chief when present, otherwise the
user. Questions and ordinary waits are not blockers. No report cadence is required.

- Answer worker questions in the conversation when recorded intent decides them.
  Do not require a duplicate sympp question record. Ordinary waits are not blockers.
- Workers message you only with actionable issues or blockers, questions,
  unclear review or scope guidance, and their completion handoff. Request status
  when you need it.
- Only the architect (or coordinating parent for direct work) explicitly declares
  and clears work blockers after resolving or escalating the issue. Scope each
  blocker to affected work; do not automatically block the whole WorkRequest.
  Declare with scoped `append_progress` and explicit payload
  `{"type":"blocker","active":true,"blocker_id":"<id>"}`; clear with `resolve_blocker`.
  Asking, escalation, and answering do not create or clear these blockers.
- Optional Herdr/OSC observations augment last-known state. Missing observation
  means unknown and never blocks work or grants takeover authority.
- Write every human question so it stands alone in plain English: avoid jargon
  or briefly explain a necessary term, and focus on what users see and the
  product consequences, not implementation detail. State the current situation,
  why the decision matters, the realistic options with their impact and
  trade-offs, your recommendation, and the concrete question.
- For human choices, carry that in a compact `decision_prompt`: `tl_dr`, `details`,
  concrete options with labels, exact answer text, descriptions, and useful
  pros/cons.

## Delivery Closeout

After the worker returns, verify acceptance and the required native checks/review
for the exact PR head once. Then call architect `sync_pr` with `work_package_id`,
`url` (or `number` and `repository`) from the normal handoff. Optional `head_sha`
must match when supplied. It fetches GitHub evidence and
applies existing readiness and dependency gates without worker receipts.
Readiness does not independently prove native checks/review passed; unknown provider
fields stay unknown. Missing optional observations do not prevent this workflow.
Once GitHub reports the attached PR merged, sync, reconciliation and periodic PR
observation record `pr_merged` from its merge timestamp and commit without a head
handoff or readiness transition. Pre-merge readiness and dependency gates still apply.
For selected candidate inputs, reconcile qualification from the native handoff
using existing scoped `append_progress` dependency provenance for the dependent head.

Use `read_work_request(view: "board")` for lifecycle evidence.

Before an authorized GitHub merge, require the package's `merge_eligibility.eligible`
and current candidate selections on that board, plus the worker's exact-head
checks/review and combined acceptance. Merge backend before wired UI. Board
eligibility checks dependencies; it does not perform a GitHub merge or prove
native checks/review. Recheck when a relevant head or selection changes.

For merged PR evidence, use `reconcile_work_request` first, then
`reconcile_work_request(apply: true)` when the proposed repair matches the
delivery board. That path uses attached/synced PR evidence and avoids repeating
PR URL or package facts. If you choose explicit PR closeout instead of
`apply: true`, replay the dry-run result's `action` payload through
`record_work_package_delivery`.

A WorkPackage is `planned`, `dispatched`, `ready` or `ended`. `sync_pr` moves a
dispatched package to `ready` when its PR is open and not a draft, CI is green
for the current head and dependency inputs are current; any of those turning
false moves it back to `dispatched` and lists the reasons. A ready contract is
frozen: supersede it with a successor instead of editing it. An ended package
has exactly one ending record, written by `record_work_package_delivery`
(`skip_work_package` writes `skipped`). For explicit `pr_merged`,
`completed_no_pr`, `superseded`, `abandoned`, `finished` or `skipped` endings,
read [terminal evidence](references/operations.md#terminal-evidence).
`finished` means the PR waits on someone else: the WorkRequest can complete but
dependents stay blocked. Any chief or architect may record it.

Do not infer delivery from prose decisions or chat. Ending a package resolves its
blockers and queues worktree cleanup; no separate worker or runtime step is needed.
If package evidence is missing or ambiguous, do not record WorkRequest delivery
closeout; repair evidence first.
Record external GitHub merges truthfully even when out of order. Reconciliation
does not erase merge history: route `delivery_order_violation` attention to
remediation, even if the backend later delivers.

Retirement is not delivery. Create all replacement packages before retiring the
predecessor and preserve its evidence with `superseded` successor linkage.
Every current successor must deliver; existing immutable successor pointers and
same-request `superseded_by`/`recut_as` lineage are cumulative, not alternatives.
Missing/cyclic successor scope stays unresolved. Planned skipped tombstones may
retire obsolete scope but cannot satisfy dependencies or deliver an all-skipped WR.
After required delivery and WR acceptance, optional sanity checks create follow-up
work; they are not another completion gate.

Human attention is **Needs you**, raised only by the chief or architect with one sentence stating the action: a human question or product/policy approval, access only the human can grant, or recovery exhausted after the system tried. Raise it with `ask_question`.
Read `read_work_request(view: "board")` for stale workers (`next_actor: architect`, `inspect_runtime`), blockers and validation evidence; handle silent workers, failing checks and quiet tasks before escalating exhausted recovery. Review rounds, running CI, dependencies, queues and worker-parent questions never need human attention by themselves.
