---
name: sympp
description: Coordinate sympp WorkRequests as a chief or architect, or carry out an assigned task or dispatched WorkPackage as a worker.
---

# sympp

Read the procedure for your role:

- Chief: turns ideas into WorkRequests and settles product calls. [chief](references/symphony-chief/procedure.md)
- Architect: owns one WorkRequest's plan, workers and delivery. [architect](references/symphony-architect/procedure.md)
- Worker: implements one assignment and hands back a PR. [worker](references/symphony-worker/procedure.md)

Ledger work needs the `sympp` MCP tools. If they are missing, the chief asks "This machine
or a server (SSH host)?"; other agents ask their parent. Run `node <installed-skill>/scripts/setup-sympp.js`
(add `--server <ssh-host>` for a server), then open a fresh agent session. Never
fall back to CLI business commands, direct SQLite or private state files.
Setup, updates and recovery: [connection](connection.md).
