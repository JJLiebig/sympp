---
name: sympp
description: Coordinate sympp WorkRequests and execute assigned WorkPackages through MCP; also supports ordinary worker and parent coordination without persistence.
---

# sympp

Read the procedure matching the assignment, then follow its contract:

- WorkRequest or product planning/delivery owner: [architect](references/symphony-architect/procedure.md).
- Assigned WorkPackage: [worker](references/symphony-worker/procedure.md).
- Parent coordinating ordinary repository work: [coordinator](references/symphony-coordinator/procedure.md).
- Bounded implementation without a WorkPackage: [worker](references/symphony-worker/procedure.md).

The parent owns slicing and integration; each worker owns its bounded task,
checks, required review, and merge-ready handoff. A chief's or architect's
child that works on a branch or PR shows on the board as a card with no setup;
it asks the operator with `ask` without `work_request_id`. Persistence is optional for
ordinary work. WorkRequest/WorkPackage and requested ledger operations require
configured `sympp` MCP tools. If those tools are unavailable,
report the missing connection and recover it before ledger work. Do not use
business CLI commands, direct SQLite, or private state files as a fallback.
Operational shell tools remain available for installation, startup, diagnosis,
upgrade, and connection recovery.

Install globally with `npx skills add JJLiebig/sympp -g`; update with
`npx skills update sympp -g` or `sympp update`.

If sympp tools are missing, first ask: "This machine or a server (SSH host)?"
Then run `node <installed-skill>/scripts/setup-sympp.js` for this machine, or
append `--server <ssh-host>`. Setup installs the `sympp` command and, when Herdr-app is present, its panel.
Use `sympp update` later to update the skill, reconnect hosts and panel, and
update the factory over the saved SSH host. Open a fresh
agent session after setup. See [MCP connection](connection.md) for recovery.

Invoke this skill as `$sympp` in Codex or `/sympp` in
Claude Code. Procedure names in linked instructions refer to local files,
not additional skills to install. The connection reference covers the shared bridge for both hosts. Use your
host's delegation tools when available; otherwise report a required worker
dispatch as unavailable instead of taking over an architect's implementation.
