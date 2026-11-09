# sympp

sympp is a local planning and delivery cockpit for coding agents. Its
ledger, MCP tools, and dashboard connect WorkRequests, bounded WorkPackages,
decisions, blockers, and GitHub delivery evidence.

A human and agent can explore a problem before creating a WorkRequest. An
architect then slices and oversees tracked delivery. Ordinary workers also work
without a backend; when a chief's or architect's child
works on a branch or PR, the board shows it as a card with no setup. sympp does
not own model accounts or terminal sessions.

Ordinary workers receive an assignment, implement it, run required native checks
and review, and return a PR or evidence. The architect coordinates ownership,
dependencies, explicit blockers, readiness, and delivery; workers make no sympp
MCP calls.

## Install

For an always-on Linux factory shared across devices, see [Linux service](docs/linux-service.md).

Install the skill, then tell Codex or Claude "set up sympp":

```sh
npx skills add JJLiebig/sympp -g
```

The agent asks whether to use this machine or a server and runs setup. Setup
installs the `sympp` command, connects Codex and Claude, and installs the panel
when Herdr-app is available. Open a fresh agent
session afterward.

```sh
sympp --server jjdev
sympp status
sympp update
```

Run `sympp` alone for a local Windows x64 factory. Remote clients also support
Linux and macOS. See [Portable skills](docs/portable-skills.md) for manual setup
and [Install and run](docs/runtime.md) for runtime details.

Direct Tailscale tailnet clients have full board and native Herdr access without
sign-in or a token, including archived requests and operator actions. Browser
writes must use the board's own origin; native clients need no Origin header.
Other remote clients still need a token, board code or board cookie. Forwarded
requests keep the existing restrictions. See [Board access](docs/operator-board-api.md#access).

## Documentation

- [Documentation index](docs/README.md): current system, operations, security,
  development, and recovery.
- [Portable runtime source](packages/sympp/README.md): package boundaries.
- [Product](PRODUCT.md) and [Design](DESIGN.md): purpose and interface principles.
- [Factory workflow](docs/design/factory-workflow.md): approved beta contract
  and editable human diagram.
- [Upstream specification](SPEC.md): upstream Symphony behavior.

## License

Apache 2.0. See [LICENSE](LICENSE).
