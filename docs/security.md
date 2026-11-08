# Security

The MCP server is the permission boundary. Skills, prompts, hooks, and the
dashboard improve workflow but cannot grant authority.

## Ownership

- Any trusted caller may read. Writes need the Herdr terminal identity the sympp
  bridge sends; callers outside Herdr are read-only (`read_only_outside_herdr`).
- A WorkRequest is worked on by at most one terminal at a time (one live row per
  WorkRequest, enforced by a unique index). Owner-gated writes (planning,
  dispatch, `sync_pr`, closeout, blockers, `set_report`) take ownership of an
  unowned WorkRequest and are refused `owned_by_other_terminal` from any other
  terminal. Recording decisions, asking or answering questions, creating a
  WorkRequest and recording `finished` are open to any Herdr terminal.
- Ownership ends only when the terminal finishes, its bridge detaches cleanly on
  a machine the factory's core can't see, the operator presses Release, or the
  WorkRequest is archived. A lapsed heartbeat or unreachable core keeps the owner.
- Workers make no sympp calls and hold no ledger authority. No secrets are minted
  for agents.
- Repository, branch and worktree values are derived from the ledger and treated
  as validation context when supplied.

## Remaining Boundary

1. Non-loopback MCP and operator HTTP require factory-access authentication;
   loopback is trusted.
2. Operator actions (Finish, Release, answering questions on the board,
   completion, archive, restore) are HTTP-only and need the same trust.
3. Terminal identity is asserted by the bridge, which verifies it against its
   local herdr-core. When the factory's own core can see the terminal, it must be
   live. Anyone who can reach the endpoint can still assert any terminal address:
   the same trust as a trusted local daemon, stated plainly.

## Secret Hygiene

Never place raw API keys, bearer tokens, GitHub or Linear tokens, MCP tokens,
secret hashes, private handoff payloads, or secret-bearing commands in:

- Agent prompts or durable ledger prose.
- Documentation, comments, pull requests, or reviews.
- Dashboard payloads or normal tool output.
- Logs, fixtures, or copied plugin assets.

Report missing secret-dependent validation as blocked. Do not substitute real
credentials into examples.

## Incidents

For suspected permission widening or secret exposure, follow
[Security incident response](runbooks/security-incident.md).
