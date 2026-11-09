# MCP Connection

The bundle carries the launcher, bridge, contract identity and runtime pointer.
It needs Git, Node.js 22.20+, and PowerShell 7 on Windows.

## Setup

Install with `npx skills add JJLiebig/sympp -g`, then run
`node ~/.agents/skills/sympp/scripts/setup-sympp.js` (Claude-only copies live in
`~/.claude/skills/sympp`). Setup finds Codex and Claude Code on PATH; pick one
with `--host codex|claude|both`. It installs the `sympp` command and, when
Herdr-app is present, its panel. It doesn't add tools to open sessions: open a
fresh agent session and check that the `sympp` tools are there.

- **Existing factory:** `sympp --server <ssh-host>` reads the factory's token
  once over SSH, stores it user-only, and registers the bridge. On the factory
  machine use `--server http://127.0.0.1:19998`.
- **Always-on Linux factory:**
  `SYMPP_SERVICE_HOST=<tailnet-ip> bash ~/.agents/skills/sympp/scripts/setup-sympp-service.sh`;
  see the [Linux service guide](https://github.com/JJLiebig/sympp/blob/main/docs/linux-service.md).
- **Isolated trials:** set `SYMPP_HOME`, `SYMPP_DATABASE`, `SYMPP_RUNTIME_FILE`,
  `SYMPP_BACKEND_PORT`, `CODEX_HOME` or `CLAUDE_CONFIG_DIR` before setup, and
  use a separate ledger and port.

Rerun setup to repair its own registration; it refuses unrelated entries.
Claude local and project entries override user scope, so remove a stale one
with `claude mcp remove --scope local sympp`. Keep tokens out of skills, prompts
and shared config.

`sympp status` shows the selected factory and whether it answers. `sympp board`
opens it in the browser, signed in for 30 days. `sympp update` updates the
skill, reconnects hosts and the panel, and updates the factory over SSH; open
fresh sessions afterwards. Offline copies, rollback and removal are in
[portable skills](https://github.com/JJLiebig/sympp/blob/main/docs/portable-skills.md).

## Herdr identity

The bridge checks the caller's Herdr terminal against its local herdr-core and
sends the core id, terminal address and `sympp.*` labels with each call. Writes
need that identity: outside Herdr sympp is read-only, and writes fail
`read_only_outside_herdr`. Restarting, compacting or clearing an agent in the
same terminal keeps what it owns; `sympp.health` lists it. A worker terminal
(`sympp.role=worker`) gets no sympp tools.

## Recovery

The first client starts the runtime; matching clients attach, and it stops after
the last one closes. When one client fails, keep healthy sessions running and
capture its exact startup error before repairing. After a reconnect, read
current state before retrying an uncertain write.

For source experiments, run
`mix sympp.cockpit --port 19998 --database <isolated-ledger>` from `elixir/` and
point the host at the printed `/mcp` endpoint. A URL-only connection has no
bridge, so it is read-only.
