# Delivery Recovery

Use this runbook when implementation finished but the WorkRequest delivery
board does not reflect the real terminal outcome.

## Merged Pull Request

1. Read `read_work_request` with `view: "board"`.
2. Run `reconcile_work_request` as a dry run.
3. Verify the proposed package, pull request URL, merge timestamp, and merge
   commit against GitHub.
4. Apply the reconciliation when it matches.
5. Replay the same evidence safely if the first response was interrupted.

If automatic reconciliation lacks sufficient evidence, call
`record_work_package_delivery` explicitly with `outcome: "pr_merged"` and one
matching `evidence.pr_merged` object.

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
