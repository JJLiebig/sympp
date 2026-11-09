---
name: symphony-worker
description: Use when assigned a bounded implementation, investigation, docs, or PR-sized task; deliver native checks, review, and a normal PR or evidence handoff.
---

# sympp Worker

Implement the assignment, run its native checks and review, and report the PR or
evidence to your parent. Make no sympp MCP calls: in a dispatched worker terminal
the sympp bridge serves no tools, and the parent owns every ledger record.

## Start

A dispatched WorkPackage starts you in its prepared worktree with one instruction:
read the assignment file. It names the WorkPackage, the worktree, branch and base,
the review step, and carries the contract: goal, owned and forbidden paths,
acceptance, validation, dependencies, prior findings and decisions, and stopping
conditions. Read it before coding and stay inside that worktree and scope.

Without a WorkPackage, the parent's task message is the assignment.

## Scope

- Ask the parent when context is missing or material product, architecture,
  dependency or review ambiguity appears. Message the parent only for actionable
  issues, blockers, questions or unclear review or scope guidance; send status
  only when asked. Questions and waits are not blockers. Continue independent
  work while a decision is pending.
- The parent owns dispatch, dependency decisions, blockers and delivery.
- Honor assigned budgets; otherwise keep one cohesive outcome. Escalate material
  scope growth before implementing it. Do not invent product behavior for a review.

## UI Collaboration

For UI work, collaborate directly with the human in your terminal:

- In Herdr, publish the running dev-server URL on your own terminal with
  `hc label $HC_TERMINAL_ID sympp.preview_url=<url>`; clear it with
  `hc label $HC_TERMINAL_ID sympp.preview_url=` when the server stops.
  In PowerShell, use `$env:HC_TERMINAL_ID` for the terminal argument.
- Post screenshots at visual milestones and pause for the human's feedback in
  that terminal before continuing visual iteration.
- Treat direct human input as product direction and record the decisions in
  the handoff. Return scope or authority conflicts to the parent.

Keep ownership of checks, review and the PR. Non-UI work continues autonomously
without these pauses.

## Checks and Review

- Run the repository's native required tests and static checks, and get CI green.
  Preserve required commands and ordering; honor execution bans.
- Reuse still-valid evidence with its tested revision. Rerun when relevant inputs
  change, results fail, or policy requires it. Report exact failures and unrun
  requirements; never infer passing checks or review.
- When the assignment gives a Review Suite id and mode, run the installed Review
  Suite once with exactly that `--id`, `--mode` and `--cd`, then wait for it.
  Repeating the same command resumes the same review, but two starts at once can
  both launch reviewers, so never start it again while it runs. Brief it from the
  assignment's goal, owned scope, acceptance and stopping conditions. When the
  assignment says no review is required, skip this step.
- Resolve findings inside scope; return product or contract conflicts to the
  parent. Finish the review on the current head.

## Delivery

Send your parent one handoff per independently delivered PR. In Herdr, your
parent is the `parent` of `hc get $HC_TERMINAL_ID`; send it with `hc send`.

```markdown
WorkPackage: <id, or not assigned>
PR: <url, or no PR>
Head: <exact head SHA>
What changed: <behavior and files, or direct evidence for no-PR work>
Acceptance: <evidence for each criterion>
Consumed inputs: <prerequisite package and exact head per dependency, when candidate dependencies apply>
Checks and CI: <commands, results, tested head, unrun requirements>
Review: <Review Suite id and result for the head, or none required>
Risks: <remaining risks and unresolved findings, or none>
```

No-PR work returns direct evidence and says it should close as
`completed_no_pr`. The parent verifies the handoff against GitHub and the review
record; never substitute business CLI commands or private state files for it.

## Safety

Never print, store, commit, or paste raw API keys, bearer tokens, GitHub tokens,
Linear tokens, MCP auth tokens, private handoff payloads, or secret-bearing commands.
