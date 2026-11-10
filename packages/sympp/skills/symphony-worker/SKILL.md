---
name: symphony-worker
description: Use when assigned a bounded task or a dispatched sympp WorkPackage: implement it, run its checks and review, and hand back a PR.
---

# sympp Worker

Implement your assignment, run its checks and review, and hand the result to
your parent, who owns the ledger. A dispatched WorkPackage worker makes no sympp
MCP calls: its terminal gets no sympp tools.

## Start

A dispatched WorkPackage starts you in its worktree with one instruction: read
the assignment file. Your assignment opens with what the WorkRequest is
building and how your package fits into it. It names the branch, base and
review step, and carries the contract: goal, owned and forbidden paths,
acceptance, validation, dependencies and stop conditions. Stay inside that
worktree and scope, and keep the PR small.
Branch from the base and target it; never merge or cherry-pick another unmerged
branch. Once handed off, leave the branch alone unless your parent asks.

Without a WorkPackage, your parent's message is the assignment. If your parent
is a chief or architect, your branch or PR shows on the board as a card. Only the chief can use `ask`; send your chief the question directly instead.

You own your package. Within its paths and constraints, decide and fix without
asking: implementation, CI, lint, tests, merge conflicts, and review findings
that point at real defects.

Ask your parent once, with evidence and a recommendation, and keep working on
the rest, when:

- a reviewer asks for features, abstractions or cleanups beyond the acceptance;
- the work needs files outside your paths, a new dependency, or access you
  don't have;
- the change would alter product behaviour beyond what the assignment
  describes;
- the acceptance itself looks wrong (propose the fix; don't quietly reinterpret
  it).

If a check fails for a reason your change didn't cause, such as a flaky test or
a failure that's already on the base, send your parent the evidence; don't fix,
skip or waive it yourself. Never weaken security or checks to get green.

Message only your own parent, whatever its role: one final handoff, plus
questions or blockers. Never message any other chief or architect. Keep
messages short; never send status or acknowledgements.

## Checks and review

- Run the repository's required tests and static checks, and get CI green.
  Report exact failures and anything you didn't run.
- When the assignment gives a Review Suite id and mode, run
  `review.py --id <id> --mode <mode> --cd <worktree>` once and wait for it.
  Rerunning the same command resumes it; never start a second run while one is
  going. Fix findings in scope; return product or contract conflicts to your
  parent.
- `main` moving never blocks work. Leave a ready branch alone until merge;
  merge `main` in or rebase only to fix a conflict. If the PR's own diff is
  unchanged after that, its review still counts. If it changed, review only
  what changed. Never restart a whole review because `main` moved.

## UI work

Publish your dev server on your terminal with
`hc label $HC_TERMINAL_ID sympp.preview_url=<url>`, and clear it with an empty
value; in PowerShell, write `$env:HC_TERMINAL_ID`. Post screenshots at
milestones and wait for the human's feedback in your terminal. Record their
decisions in the handoff.

## Handoff

Send one message per PR to your parent (the `parent` in
`hc get $HC_TERMINAL_ID`) with `hc send`:

```text
WorkPackage: <id, or none>
PR: <url, or none>   Head: <exact sha>
What changed:
Acceptance: <evidence per criterion>
Checks: <commands, results, tested head, anything not run>
Review: <Review Suite id and result, or none>
Risks:
```

Work with no PR returns direct evidence and says to close it as
`completed_no_pr`. Never print or commit secrets.
