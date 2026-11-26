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
is a chief or architect, your branch or PR shows on the board as a card.

You settle implementation and review fixes within the approved outcome, paths
and constraints, including CI, lint, tests and merge conflicts. Architects
settle in-scope technical disputes. Chiefs decide changes to product intent or
authority. Scopes state constraints by outcome. An intentional narrow stop
names the decision to escalate.

Record check failures your change didn't cause in the evidence. Leave fixes,
skips and waivers to your parent. Never weaken security or checks to get green.

## Messages

Send short messages only when someone must decide or act, or for one final
handoff. Keep progress and receipts on the board or in the evidence record.
Reply to reports, acknowledgements and notices only to decide, unblock or
redirect. After handoff, message only for a material correction or a new
caller-requested action.

Message only your own parent.

Ask your parent once, with evidence and a recommendation, for a decision or
action you need outside the assignment. This includes changes to acceptance,
product behaviour or owned paths, a new dependency, missing access, and an
out-of-scope review request that blocks delivery. Keep working on independent
parts.

## Checks and review

- Run the repository's required tests and static checks, and get CI green.
  Record exact failures and unrun checks in the evidence.
- Run checks yourself, with your own containers, ports and databases. Never
  share them or wait on a lock. Run locally while the workstation has headroom,
  otherwise on CI (wait with `gh run watch`).
- When the assignment gives a Review Suite id and mode, run
  `review.py --id <id> --mode <mode> --cd <worktree>` once and wait for it.
  Resume with the same command. Run one review at a time. Fix in-scope findings.
- `main` moving never blocks work. Leave a ready branch alone until merge;
  merge `main` in or rebase only to fix a conflict. If the PR's own diff is
  unchanged after that, its review still counts. If it changed, review only
  what changed. Never restart a whole review because `main` moved.

## UI work

Bind the dev server to `0.0.0.0` and publish a URL with this machine's reachable hostname, never `localhost`.

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
