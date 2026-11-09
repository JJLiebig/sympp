# Factory Workflow

**Approved beta contract.** The diagram preserves product intent.
Use [Current system](../system.md), [Operations](../operations.md) and the
[packaged skills](../../packages/sympp/skills/) for current
behavior. record exact tested builds and hosts.

The aim is a lean, agent-agnostic delivery system whose human operator can see
who owns work, what is happening, what is waiting, and who acts next.

![Approved factory workflow](factory-workflow.svg)

[Open the SVG](factory-workflow.svg) or edit the
[Excalidraw source](factory-workflow.excalidraw). Both capture the final human
diagram. Its “Final Sanity Check” happens **after WR fully delivered**.

## Separate The Request, Workflow, And Actor

| Dimension | Choices |
|---|---|
| Request type | Feature, bug fix, refactor. |
| Workflow | Direct delivery for small clear work; architect-led delivery for substantial work; UI collaboration when human design iteration is needed. |
| Actor | Domain chief, feature architect, worker, UI collaborator, optional dedicated UI review owner. |
| Execution configuration | Model, provider, host, and pane are configurable choices, not workflow states or role names. |

A bug fix may need an architect if scope or decisions demand one. A small
refactor may go directly to a worker. Request type does not impose an agent
hierarchy. Existing coordinator/worker delivery supports the small-work loop.

The domain chief is a persistent product/architecture owner and the usual human
entrypoint. Chiefs understand service responsibilities and coordinate decisions
across domains. They do not all need to sit under a machine-wide LLM supervisor.
A current calling agent can own small work without introducing another chief.

Chief attribution comes from terminal labels: the board's chief launcher starts a
chief terminal labelled `sympp.role=chief` and `sympp.domain=<topic>`, and the
bridge forwards those labels with each call. There is no registration step; see
the packaged [chief](../../packages/sympp/skills/symphony-chief/SKILL.md)
procedure.

The feature architect owns one substantial request: clarify intent, review the
plan, slice and dispatch work, resolve findings, integrate, and oversee merges.
The human may keep speaking to the chief or work directly with the architect
when detailed refinement is useful. Direct human/UI collaboration is expected;
the chief receives decisions and an executive recap rather than relaying every
utterance. Durable decisions belong with the request, not only in chat.

## Small Clear Work

```text
Chief / calling coordinator
  -> bounded worker assignment
  -> reading / inventory
  -> implementation
  -> required checks
  -> declared review and fixes
  -> merge-ready handoff
  -> calling owner accepts + merges
  -> delivered
```

Use a WorkRequest/WorkPackage when delivery tracking is wanted. Ordinary
coordinator work does not require persistence; its children's branches and PRs
show as cards without setup. Growing
scope or unresolved product decisions return to the caller, who can introduce
an architect. Do not force a large-work planning ceremony onto a one-PR fix.

## Feature Or Substantial Refactor

| State | Owner and exit |
|---|---|
| Clarify | Chief/architect and human agree on outcome, constraints, acceptance, and meaningful open decisions. |
| Plan | Architect develops the plan and runs Review Suite plan review; verified findings refine it. |
| Slice | Architect creates small, contained WPs (about 100 changed production lines, each one quick-to-review PR) with scope, dependencies, checks, review needs, and stop conditions. Independent WPs are preferred. |
| Execute | Ready workers run concurrently, each branching from the base and targeting it. A dependent starts only after its prerequisite is delivered. Each worker owns implementation, checks, and review convergence. |
| Resolve | Technical findings return to the worker. Product/contract conflicts or oversized slices return to the architect. |
| Integrate | Architect accepts all required slices, verifies combined behavior, and merges in dependency order. |
| Delivered | Required current WPs are delivered and agreed WR acceptance is met. |
| Post-delivery sanity | Architect checks the delivered result and sends the chief/human a brief recap; discovered issues become follow-up work. |

The worker loop is compact: **implemented → required checks green → declared
review settled → merge-ready**. Handoff names the candidate, check outcomes,
provider-native review reference, and remaining limitations. Reuse valid
evidence when its relevant inputs and conditions are unchanged. Do not invent
extra review receipts or have each actor repeat the same checks.

Review findings are hypotheses until their assumptions and reachability are
verified. Technical fixes return to the worker check/review loop. Product
intent, contract changes, and scope expansion go to the architect; significant
human decisions go to the human. Only affected work waits. Long review duration
must be visible; it can prompt reslicing, not endless automatic review rounds.

Reslicing replaces the affected assignment with clear successor scope and
preserves prior evidence. Canceled or superseded packages do not by themselves
prove the product goal was delivered. The post-delivery sanity check is not
another gate between merge and WR completion.

## UI Collaboration Lane

1. The architect dispatches a UI collaborator in a Herdr pane. Human and
   collaborator iterate rapidly on realistic demo data to discover the UI/UX.
   Follow the [worker UI collaboration procedure](../../packages/sympp/skills/symphony-worker/SKILL.md#ui-work)
   for preview publication, screenshot milestones and direct human feedback.
2. The human approves and freezes UX intent. Record interaction behavior,
   states, acceptance, and required data/API shape. Prototype completion alone
   is not a production wiring or merge claim.
3. The architect reslices backend/API and wiring work using what the UI
   discovery established. Backend workers follow the ordinary delivery loop.
4. Land the backend/API work first, as small PRs against the base. The wired
   UI package depends on it and starts only once the backend is delivered;
   nothing is built on an unmerged branch, in one repository or across several.
5. A dedicated review owner runs technical UI review on the wired UI PR, which
   already contains the delivered backend through its base.
6. The architect accepts the result, confirms combined checks, and merges. A
   ready PR is left alone until merge; `main` is merged in or rebased only to
   fix a conflict, and an unchanged PR diff keeps its review.

“Frozen” means product intent is human-approved. Performance, correctness,
authorization, accessibility, and wiring defects still need technical fixes.
If a fix materially changes approved UX, escalate the decision rather than
silently changing it or refusing to repair it. The dedicated reviewer owns
review convergence and handoff; fixes have an explicit implementation owner.

The ordinary worker can own its own Review Suite cycle. Delegating the UI
cycle is a workflow option to avoid spending the UI model's context and tokens
on review orchestration. Opus as UI collaborator and Codex as worker/reviewer
are examples, not hardcoded role constraints.

## Herdr Visibility

For each active request and agent, the operator needs:

- Accountable owner, current actor, role, and pane/thread link when available.
- Current activity: inventory, implementation, checks, review stage/round,
  merge-ready, integration, or finished.
- Time in the activity, especially review, and the latest meaningful update.
- Waiting reason, dependency/decision, and next actor/action.
- Explicit stale, missing, or disconnected signals instead of invented activity.

A milestone percentage may summarize progress, but it must show the current
stage and its basis. It is not an ETA; review rounds and reslicing may change
the remaining work. A “95%” badge cannot replace “waiting on architect decision
for 3 hours.” WR progress reflects current required scope and delivery, not
completed token volume or pane activity.

Symphony owns work/decision state; Herdr owns panes and execution observation;
GitHub and review providers own their outcomes. Link these sources and expose
the next action without making duplicate systems of record. Missing observation
must not authorize a worker takeover or imply delivery.

## Current Procedures

The packaged
[architect procedure](../../packages/sympp/skills/symphony-architect/SKILL.md#deliver)
owns durable approval, reviewer handoff, successor replacement and merge. This contract is not a second agent checklist.
Installed setup and recovery live in [Runtime](../runtime.md); the operator
view lives in [Operations](../operations.md). Completed implementation and
qualification history belongs in Git and release evidence.
