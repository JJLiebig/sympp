# sympp Worker

Implement your assignment, run its checks and review, and hand the result to
your parent, who owns the ledger. A dispatched WorkPackage worker makes no sympp
MCP calls: its terminal gets no sympp tools.

## Start

A dispatched WorkPackage starts you in its worktree with one instruction: read
the assignment file. It names the branch, base and review step, and carries the
contract: goal, owned and forbidden paths, acceptance, validation, dependencies
and stop conditions. Stay inside that worktree and scope.

Without a WorkPackage, your parent's message is the assignment. If your parent
is a chief or architect, your branch or PR shows on the board as a card. Ask the
operator with `ask` and no `work_request_id`; the answer is typed into your
input without being submitted.

Ask your parent when context is missing or product, architecture, dependency or
scope is unclear, and keep working on what doesn't depend on the answer. Raise
scope growth before you implement it.

Message only your own parent: one final handoff, plus questions or blockers.
Never message a chief or another architect. Keep messages short; never send
status or acknowledgements.

## Checks and review

- Run the repository's required tests and static checks, and get CI green.
  Report exact failures and anything you didn't run.
- When the assignment gives a Review Suite id and mode, run
  `review.py --id <id> --mode <mode> --cd <worktree>` once and wait for it.
  Rerunning the same command resumes it; never start a second run while one is
  going. Fix findings in scope; return product or contract conflicts to your
  parent.

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
Consumed inputs: <prerequisite package and head, when pinned>
Checks: <commands, results, tested head, anything not run>
Review: <Review Suite id and result, or none>
Risks:
```

Work with no PR returns direct evidence and says to close it as
`completed_no_pr`. Never print or commit secrets.
