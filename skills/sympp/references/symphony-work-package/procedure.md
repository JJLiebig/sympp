# sympp Work Package

The parent's assignment is the worker contract. Follow
[symphony-worker](../symphony-worker/procedure.md) to implement, check, review, and return
the PR or direct evidence. The architect owns ledger coordination and acceptance.
No worker MCP call is required to start or deliver work.

## MCP Access

Workers make no sympp calls and hold no ledger authority. Every write is owned by
the terminal that owns the WorkRequest, normally the architect; a worker's write
fails `owned_by_other_terminal`. When ledger context helps, any trusted session
may read `read_work_request` (its `plan` and `package` views) or the
`sympp://work-packages/<id>/<document>.md` resources. Return everything else in
the normal handoff.

Questions stay in the conversation. Workers do not declare or resolve work
blockers. Asking, waiting, or escalating to a human does not change blocker state.
The architect explicitly scopes a blocker to affected work, resolves or escalates
it, and clears it when the issue is settled. A chief routes human decisions when
present.

## Parent Reconciliation

The architect verifies the normal handoff and provider-native evidence, reconciles
PR readiness with `sync_pr`, and owns terminal delivery. Candidate input selections
and qualification stay parent-owned; workers report consumed heads in their native
review/handoff. Do not add duplicate review receipts or worker status ceremony.

Optional observations do not grant execution authority. Missing Herdr/OSC evidence
means last-known or unknown, never a work blocker or permission to take over.

## Safety

Workers cannot approve scope, dispatch siblings, merge PRs, or write to the ledger.
Never print, store, commit, or paste bearer/API/GitHub/Linear/MCP tokens or
secret-bearing commands.

## References

- Assignment template: `references/worker_prompt.md`.
- MCP connection setup/repair: `references/mcp_wiring.md`.
- Handoff examples: `references/handoff.md`.
