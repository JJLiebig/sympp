# Delivery Recovery

Use this runbook when implementation finished but the WorkRequest delivery
board does not reflect the real terminal outcome.

## Merged Pull Request

The factory records a merge on its own once GitHub reports the attached PR
merged, usually within a minute. When it doesn't:

1. Read `read_work_request` with `view: "board"`. A `stale` package means the
   factory couldn't read GitHub; it records the merge on its next successful read.
2. If the factory never saw the PR (opened from a fork or in an upstream
   repository), attach it with `sync_pr` and its `url`; the merge is then recorded.
3. If the merge still isn't recorded because its evidence doesn't match the
   package (repository or base branch), call `record_work_package_delivery` with
   `outcome: "pr_merged"` and one matching `evidence.pr_merged` object.

## Other Terminal Outcomes

- `completed_no_pr`: direct evidence for successful work that required no pull
  request.
- `superseded`: successor WorkPackage id and reason.
- `abandoned`: rationale explaining why the package will not be delivered.

Record the terminal outcome directly from the terminal that owns the WorkRequest.
Ending a package resolves its blockers and queues its worktree cleanup.

## Rules

- Delivery evidence, not decisions or chat, determines terminal truth.
- Use stable idempotency keys. Identical replay succeeds; conflicting replay is
  rejected.
- Do not force a WorkRequest status to `completed`; completion is derived.
- Do not invent merge evidence or clear a real blocker merely to close the
  board.
