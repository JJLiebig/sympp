# sympp Coordinator

When the user selects Herdr-next execution, use the [optional execution helper](../symphony-worker/references/herdr-execution.md)
for an ordinary untracked task. A WorkPackage launches from the line its
dispatch returns, not from this helper.

Use for ordinary coordination in a dedicated sympp MCP config. For WorkRequests, WorkPackages,
delivery boards, or MCP merge gates, use [symphony-architect](../symphony-architect/procedure.md).
Small clear work stays in this direct worker loop; a chief, WorkRequest or
feature-planning ceremony is optional. A chief delegates each substantial
multi-slice feature to a distinct architect, who owns it end to end:
clarification, architecture, slices and workers, review convergence, authorized
integration and merges, qualification and delivery. That architect follows this
procedure for ordinary work, or the architect procedure for a WorkRequest.
The chief keeps priorities,
cross-feature and domain coordination and product intent, and receives the
final delivery.

## Start

A domain chief runs in a terminal started from the board's chief launcher, which
labels it `sympp.role=chief` and `sympp.domain=<topic>`. The bridge forwards those
labels, so the chief's new WorkRequests and dispatches are attributed to the
domain with no registration call. Ordinary work needs no chief.

Writes need a Herdr terminal; outside Herdr sympp is read-only
(`read_only_outside_herdr`). When a chief creates a WorkRequest for an architect,
pass `create_work_request(own: false)`; the architect's first plan write makes its
terminal the owner. Recording decisions and asking or answering questions stay
open to any Herdr terminal, and any chief or architect may end a package as
`finished`; other writes belong to the owning terminal.

- Optionally attach a coordinator-owned [symphony-solo-session](../symphony-solo-session/procedure.md)
  for parent planning through configured MCP tools. Do not share that session
  with workers. Persistence is optional: ordinary delegation needs no sympp
  backend when no ledger state is requested. Required ledger work needs MCP;
  report missing tools and recover the connection instead of substituting CLI
  business commands or private state files.
- Scout repo context before slicing.
- Identify outcome, base branch, acceptance, owned/forbidden areas, optional
  validation and review context, risk, and any assigned size budget.
- Resolve material ambiguity before dispatch.

## Slice

WorkRequest and WorkPackage titles are their short names: 2–5 words, max 40 characters after trimming (e.g. "Board read access"); put detail in the description or body.

- Prefer one PR-sized slice per worker.
- Use isolated worktrees/branches for implementation or conflicting parallel
  work. Read-only scouts may use the existing checkout.
- Give workers goal, scope, base/branch/worktree, acceptance, optional
  validation, review, and stop-condition context, any assigned budget, and expected
  PR/evidence.
- Honor assigned budgets; otherwise keep one cohesive outcome and escalate
  material scope growth or reviewability risk. Numerical budgets are optional.
- For sympp WorkPackages, dispatch writes the scoped assignment and returns the
  launch line; follow the architect procedure. Workers make no sympp calls.
- Use explorers for reconnaissance only.

## Dispatch

Worker prompts should include:

- [symphony-worker](../symphony-worker/procedure.md).
- Task-specific scope, evidence, constraints, and deviations from the baseline
  worker contract.
- For manual worktrees, use `C:\Code\.worktrees\<repo>\<feature>`. After
  delivery or abandonment, remove only your clean worktree and run
  `git worktree prune`. sympp-managed worktrees use their own lifecycle.

## Supervise

For a WorkRequest your terminal owns, optionally publish a brief/ETA or parking
reason with `set_report`, and raise an explicit human question with `ask_question`,
at meaningful delivery milestones or road bumps; see the
[architect report procedure](../symphony-architect/procedure.md#guidance).
Route decisions to the chief when present, otherwise the user; a conversational
answer is enough to close the question. Do not create a WorkRequest solely
for reporting, require worker receipts, or turn ordinary waits into escalation.

As chief, interpret and apply existing user decisions, resolve scope conflicts,
and give the final check on reviewer-driven expansion an architect is genuinely
unsure about. Bring the human only material product trade-offs or ambiguities
that approved intent cannot settle, and access or authority only the human
holds. Never override explicit user constraints, bypass security or CI, or
silently set new product policy.

Write every human question so it stands alone in plain English: avoid jargon or
briefly explain a necessary term, and focus on what users see and the product
consequences, not implementation detail. State the current situation, why the
decision matters, the realistic options with their impact and trade-offs, your
recommendation, and the concrete question.

- Do not take over worker implementation by default.
- Answer architecture questions in the conversation; escalate human/product
  decisions to a chief when present, otherwise the user. Questions and ordinary
  waits are not blockers. Only the architect or coordinating parent explicitly
  declares/clears blockers for affected work after resolving or escalating it.
- Optional Herdr/OSC observations augment last-known state. Missing observation
  means unknown; it never blocks work or authorizes takeover.
- Treat review findings as hypotheses, not product decisions. Workers verify
  and converge them; the architect or coordinating parent settles findings a
  worker cannot, fixing genuine in-scope defects and declining unsupported
  requests rather than implementing them or asking the human. The chief is the
  final check only when that owner is genuinely unsure.
- Workers message you only with actionable issues or blockers, questions,
  unclear review or scope guidance, and their completion handoff. Request status
  when you need it.
- Stop or reslice when scope grows, workers collide, or PR budget is at risk.

## Integrate

- Verify PR/evidence against the assigned slice.
- Check changed files, acceptance, native validation/review evidence for the
  exact head, CI/check status, and residual risk. Own readiness and delivery
  reconciliation; do not request duplicate worker MCP or review receipts.
- Merge only when authorized.
- Summarize PRs/no-PR evidence and follow-ups.

Human attention is **Needs you**, raised only by the chief or architect with one sentence stating the action: a human question or product/policy approval, access only the human can grant, or recovery exhausted after the system tried. Raise it with `ask_question`.
Read `read_work_request(view: "board")` for workers that need the architect (`next_actor: architect`: `run_launch_line` when no worker terminal has appeared, `inspect_worker` when it exited without a PR or sits idle with failing CI or review findings), blockers and validation evidence; handle silent workers, failing checks and quiet tasks before escalating exhausted recovery. Review rounds, running CI, dependencies, queues and worker-parent questions never need human attention by themselves.
