# Operator board API

`GET /api/v1/sympp/herdr/dashboard` is the optional native-client read of the
same hydrated board projection as the browser endpoint below. It includes each
request's packages with their group paths, the execution graph, attention,
package/delivery signals and which terminal
works on each request (`worked_on`, below).
Unlike the browser board, it also lists archived requests in
`work_request_details`, with `phase: "archived"`, `archived_at` and their
packages, so the panel can show them and offer Restore.

## Access

In factory service mode, direct Tailscale peers (`100.64.0.0/10` and
`fd7a:115c:a1e0::/48`, including mapped IPv4) have full board, operator and
native Herdr access without a login, code or token. This includes archived
requests (`/dashboard?surface=archived`) and all human actions below.
Credential-free tailnet authority requires a Host that is a tailnet IP literal,
a `*.ts.net` name, a loopback address/name, or the factory machine's own hostname.
Other Host values fall back to normal credential rules, even if Origin matches
Host, preventing an arbitrary rebound hostname from gaining tailnet authority.
Tailnet writes carrying an `Origin` header must match the request's scheme,
host and port; foreign origins receive HTTP 403. Native clients and curl need
no Origin header. Forwarded requests retain the existing credential and proxy
restrictions. Other non-loopback peers still require a bearer token, board
sign-in code or board cookie, within each credential's existing route scope.

Each `work_request_details[]` includes `asks`, the request's open asks: the
only thing that needs the operator ("Needs you"). Each ask has `{id, kind: "ask",
text, work_package_id, decision_prompt, asked_by, asked_at, answer_route}`.
`work_package_id` names the package the ask is about, or is null.
`answer_route` is the native POST path below. Answered and withdrawn asks leave
the list on the next read.

Each `work_request_details[]` also includes `decisions_to_review`: decisions an
agent flagged with `record_decision(flag: true)` that still need the operator,
oldest first. Each has `{id, work_request_id, decision, rationale, scope_impact,
recorded_by, created_at, review_state, feedback, undelivered_reason,
next_action}`. A `recorded` decision waits for an ack or feedback; a `feedback`
decision is listed only while `undelivered_reason` is set, until the operator
dismisses it. The native board adds `ack_route` and `feedback_route` to recorded
decisions and `dismiss_route` to undelivered ones that are no longer being typed.

Package `activity_signal.observation_state` distinguishes `queued` (planned,
created or prepared, without a current worker observation), `current` (current
agent run), and `stale` (expired worker heartbeat). `unknown`
remains available for packages without conclusive runtime evidence. Worker freshness
uses the existing runtime heartbeat policy, independent of actor display labels;
package edits and dispatch timestamps do not prove a fresh worker.

Attributed request cards and request/package details carry optional
`dispatched_by: {kind: "chief", domain}`, captured when a terminal labelled
`sympp.role=chief` and `sympp.domain=<topic>` creates a request or dispatches a
package. The board's chief launcher sets those labels; there is no registration.

Both hydrated routes include `runtime: {offline: boolean}` from the running
backend's sandbox mode. A Copy-and-View snapshot reports `true` even though its
request/package ids match the live ledger. Native clients must disable agent
navigation when `runtime.offline` is true or unavailable; copied identities must
not focus live sessions. An online backend reports `false`. This field reports
context; it grants no mutation or session authority. The Herdr route's `runtime`
also carries `repos_root`: the factory's `SYMPP_REPOS_ROOT`, or `null` without
one. Herdr's Start chief uses it to place a chief on the factory's machine.

The Herdr detail/event reads accept direct tailnet peers and authenticated
remote clients as described under [Access](#access). Unauthenticated local
clients require a loopback peer, a local Host, and no `Forwarded`,
`X-Forwarded-*` or `X-Real-IP` headers. Native clients need no Origin or browser
fetch metadata. Unauthorized requests return HTTP 401; other methods return
HTTP 405. The read itself grants no operator mutation authority. It reads an initialized
ledger without running migrations, registering a dashboard opener, or writing
ownership, audit or business state. Subscribe to
`/api/v1/sympp/herdr/events` and refetch after invalidation.

`GET /api/v1/sympp/herdr/work-requests/:work_request_id` uses the same native
read authority and never runs ledger migrations. It returns the request's
asks, packages, execution graph,
attention keys and current worker sessions. `decision_logs` contains every
decision for that request, newest first, with the existing decision entry shape;
`summary.decision_count` remains the total. Browser detail enrichment still
returns only the newest three decisions. An uninitialized ledger returns HTTP
503 with `{error:{code:"storage_failed",message}}`; a busy ledger returns HTTP
503 with `{error:{code:"database_busy",message}}`. These reads do not initialize
or repair the ledger.

## Native human actions

These optional native POST routes use the same canonical input validation,
services, response shapes and dashboard invalidation as their operator siblings:

| Route suffix under `/api/v1/sympp/herdr` | Input and result |
| --- | --- |
| `/work-requests` | Intake fields below; HTTP 201 with `{ok:true, work_request:<request detail>, refresh:{dashboard:true, work_request_id}}`. The new id is `work_request.work_request.id`. |
| `/asks/:ask_id/answer` | Answer fields below; HTTP 200 with `{ok:true, ask_id, work_request_id, delivery, refresh:{dashboard:true, work_request_id}}`. |
| `/decisions/:decision_id/ack` | No input; HTTP 200 with `{ok:true, decision_id, work_request_id, review_state, refresh:{dashboard:true, work_request_id}}`. |
| `/decisions/:decision_id/feedback` | `{"text":"…"}`; HTTP 200 with the ack result plus `delivery`. |
| `/decisions/:decision_id/dismiss` | No input; HTTP 200 with the ack result. |
| `/cards/:card_id/dismiss` | No input; HTTP 200 with `{ok:true, card_id, state:"dismissed", refresh:{dashboard:true}}`. Dismissing again returns the same; an unknown card returns HTTP 404. |
| `/work-packages/:work_package_id/finish` | Finish, as under [Operator actions](#operator-actions). No input; HTTP 200 with `{ok:true, work_package_id, status:"ended", refresh:{dashboard:true, work_package_id}}`. |
| `/work-requests/:work_request_id/release` | Release. No input; HTTP 200 with `{ok:true, work_request_id, released:<worked_on>, refresh:{dashboard:true, work_request_id}}`; no live owner returns HTTP 409 `not_owned`. |
| `/work-requests/:work_request_id/complete` | Complete. No input; HTTP 200 with `{ok:true, work_request:<request>, refresh:{dashboard:false, work_request_id}}`. |
| `/work-requests/:work_request_id/archive` | Archive. No input; HTTP 200 with `{ok:true, work_request:<request>, refresh:{dashboard:true, work_request_id}}`. |
| `/work-requests/:work_request_id/restore` | Restore. No input; HTTP 200 with the archive result. |
| `/work-requests/:work_request_id/delete` | Delete. No input; HTTP 200 with `{ok:true, work_request:{id}, refresh:{dashboard:true, work_request_id}}`. |

The last six run the operator routes' handlers: same preconditions, refusals
and operator audit entry, with the native path in the audit's request metadata.

Native human authority trusts the direct local process or tailnet peer,
not a Herdr application identity. All native POSTs require JSON. For
unauthenticated local requests, require a loopback peer and local Host,
`Content-Type: application/json` (a charset parameter is accepted), and no
`Origin`, `Sec-Fetch-*`, `Forwarded`, `X-Forwarded-*` or `X-Real-IP` headers.
Invalid native authority returns HTTP 401. These POST routes grant no CORS access
or OPTIONS preflight: other methods return HTTP 405. Browser forms cannot send
JSON, script JSON requests require preflight, and browser fetch metadata is
refused for unauthenticated local clients. Direct tailnet clients have the full
authority described under [Access](#access), including same-origin browser writes.
This does not protect against an untrusted process already running locally.

Minimal intake JSON is
`{"title":"Widget","repo":"example/service","base_branch":"beta","human_description":"Build the agreed widget."}`.
Optional fields use existing operator defaults: `work_type: "feature"`,
`desired_dispatch_shape: "architect_led_feature_branch"` and `constraints: {}`. Intake creates the request with no
owner and starts no agent. Unknown request fields are ignored.

Hydrated and detail reads list every ask in `work_request_details[].asks[]`:
`id`, `work_request_id`, `work_package_id`, `question`, `decision_prompt`,
`state` (`open`, `answered` or `withdrawn`), `asked_by`, `asked_at`, `answer`,
`answered_by`, `resolved_at` and `delivered_at`. Only `state: "open"` is
answerable.

A structured `decision_prompt` has `tl_dr`, `details`, 1–4 `options` with `id`,
`label` and `answer` (optional `description`, `pros` and `cons`), and an optional
`custom_redirect_label`. Render the persisted options. Submit
`{"answer_choice":"<option id>","answer_note":"optional note"}`; a structured
prompt does not accept `answer` alone. The custom choice `__custom_redirect__`
requires a nonblank `answer_note`. Without a structured prompt, submit
`{"answer":"the human's answer"}`. The backend records `operator` as the answer
author, then types `Answer: <answer>` into the asking terminal's input without
submitting it. `delivery` reports the outcome: `{state: "delivered", to}`, or
`{state: "not_delivered", reason}` with `reason` `terminal_finished`,
`terminal_unreachable` (the factory's own herdr-core doesn't see that terminal live; answers are not typed into other machines yet),
`no_asking_terminal` or `send_failed`; the answer stays on the ask either way.
An answer does not resume or unblock work by itself.

Flagged decisions move `recorded → acknowledged` (ack) or `recorded → feedback`
(feedback). Feedback is stored, then typed into the recording terminal's input
as `Decision feedback: <text>` without submitting it, through the same delivery
as answers, with the same `delivery` result (`no_recording_terminal` replaces
`no_asking_terminal`). Feedback that wasn't delivered stays on the decision with
its reason in `undelivered_reason`; dismiss clears that marker and keeps the
text. While the factory is still typing it the reason is `delivering`, with
`next_action` `wait: the feedback is being typed` and no dismiss; a send that
never finished reads as `delivery_interrupted` after a minute and can be
dismissed. Any other transition returns HTTP 409
`{error:{code:"decision_transition_refused",message,state,next_action}}`, where
`state` is the decision's review state (or `not_flagged`). Blank feedback returns
HTTP 422 `missing_feedback`. Hydrated and detail reads also carry `flagged`,
`review_state`, `feedback`, `reviewed_at` and `undelivered_reason` on every
`decision_logs[]` entry.

Refetch the native board after success or its event-stream invalidation. Errors
use `{error:{code,message}}`: malformed input/choice returns HTTP 422,
absent targets return HTTP 404, and an ask that is no longer open returns HTTP
409 `ask_not_open`. No draft-edit or dispatch is exposed by these native
routes.

## Hydrated board

`GET /api/v1/sympp/operator/dashboard/hydrated` returns the current board in one
response. Existing fields retain their meaning. Read each entry of
`work_request_details[].work_packages[]` for these additive fields:

| Field | Meaning |
| --- | --- |
| `board_state.stage` | `queued`, `build`, `checks`, `review`, `merge`, or `done`. |
| `board_state.entered_at` | Evidence-backed stage time, or `null` when unavailable. |
| `board_state.source` | `dispatched`, `recorded_status`, `recorded_delivery`, `created`, `recorded_pr`, or `provider`. |
| `board_state.track` | `pr` when a PR exists or the package contract requires merging; otherwise `no_pr`. |
| `board_state.outcome` | Canonical recorded delivery outcome, when present. |
| `board_state.delivered` | Whether the package merged or completed without a PR. |
| `repo_signal.has_ci` | `true` when the factory checkout has a `.github/workflows/*.yml` or `*.yaml` file; `false` without one. Omitted when no checkout can be resolved. |
| `ci_override` | The architect's `sync_pr` CI override for the package's current head: `reason`, `by` (terminal) and `head`. Omitted when there is none; a new head clears it. |
| `pr_signal.created_at` | GitHub PR creation time, when available. |
| `pr_signal.updated_at` | GitHub PR update time; this is not a stage-change time. |
| `pr_signal.observed_at` | Stored provider snapshot observation time, when available. |
| `pr_signal.head_changed_at` | First observed time of the current PR/head, recorded on snapshot append. |
| `pr_signal.checks.changed_at` | First observed time of the current check status for that PR/head. |
| `review_signal.mode` | Native provider mode, falling back to the configured requirement. |
| `review_signal.round` | Integer count from Review Suite's `rounds`, including zero before its first round. |
| `review_signal.provider_status` | Review Suite's raw stage; `status` keeps its existing normalized meaning. |
| `review_signal.steps` | Optional ordered ladder of `{index, name, state}` entries (`done`, `current`, or `pending`). |
| `review_signal.round_history` | Optional oldest-first list of the latest 20 provider rounds. |
| `worker_terminal` | The package's worker terminal as the Observer last saw it, `{address, state, status}`: `state` is `live` or `finished`; for a live terminal `status` is the core's agent state (such as `working` or `idle`), `live` when the core reports none, or `unknown` when the factory's core can't see it; for a finished one it is `finished`. `null` when no worker terminal was seen. |
| `observation_stale` | Inputs the Observer couldn't read on its last sweep (`github`, `review`, `stacking`); `[]` when none. |
| `stacked_on` | Packages whose unmerged commits the PR carries; it keeps the PR from qualifying. `[]` when none. |
| `progress` | For a `dispatched` package: `launching`, `implementing`, `worker_exited` or `review_ci` (an open PR). `null` otherwise. |

Repository signals use only existing local checkouts under the factory repos root,
with the same identity and ambiguity rules as checkout resolution. They never
clone or call GitHub. Results (including unresolved checkouts) are cached per
repository in a shared repos-root inventory for 30 seconds.

Review progress remains in `review_signal.step`, `current`, `total`, `round`,
`evidence_id`, `accepted_head`, `reviewed_head` (only when it differs from
`accepted_head`), `started_at`, `round_started_at`, `observed_at` and
`observation_state`. `pr_signal.checks.status` remains `passing`, `pending`,
`failing`, or `unavailable`; missing checks never imply success.

Each round-history entry contains `number`, `round_id`, `lane`, `step`, `status`,
`outcome` (`findings`, `clean`, `blocked`, or `null`), `findings` (integer or
`null`), `started_at`, and `finished_at`. Provider strings are trimmed and capped
at 240 characters; steps are capped at 20 entries. Round timestamps must be ISO
8601; unavailable or invalid history timestamps are `null`. Top-level
`started_at` and `round_started_at` follow the same timestamp validation and are
omitted when unavailable. Older Review Suite versions that omit `steps` or
`round_history` leave those fields absent from the signal.

Review observations come from the factory's Observer, which reads each
package's Review Suite cycle by the `review_id` dispatch minted, on the worker's
machine (directly on the factory host, else through `hc exec --on`). It runs the
portable skills bundle's `~/.agents/skills/review-suite/plugins/review-suite/scripts/review.py`,
else the Codex marketplace plugin under `$CODEX_HOME/plugins/cache/review-suite`;
it does not search PATH or a package's worktree for a provider script. A host
that can't be read leaves the last observation and marks the package stale.

A dispatched package is building from `dispatched_at`, without worker reports,
runtime observations, or a reporting cadence. Native review observations augment
this state. A recorded `superseded`, `abandoned` or `skipped` outcome has a null
stage and `delivered: false`; `finished` is done but not delivered. Review uses the
known round/start time. Checks stage entry remains null because a status snapshot
cannot establish review-to-checks re-entry; read `checks.changed_at` separately. These are
observations, not reconstructed transition history. Repeated snapshots with the
same PR/head/check status preserve timestamps; a changed head or PR resets them.
Existing snapshots acquire these times on their next append. Reads never write
observations or complete a WorkRequest.

Example package fragment (invented repository):

```json
{
  "id": "wp-widget",
  "board_state": {
    "stage": "checks", "entered_at": null,
    "source": "provider", "track": "pr", "outcome": null, "delivered": false
  },
  "pr_signal": {
    "status": "open", "repository": "example-org/widget-service", "number": 42,
    "created_at": "2026-10-01T09:05:00Z", "head_sha": "abc123",
    "head_changed_at": "2026-10-01T09:10:00Z",
    "checks": {"status": "pending", "changed_at": "2026-10-01T09:10:00Z"}
  }
}
```

Each package's `group` is its group path, such as `Backend / Billing`, or null.
Path segments are separated by `" / "`; a path nests under its first segment,
and groups appear in the order their first planned package does.
`work_request_details[].product_tree.execution_graph` holds the effective
dependency edges. Each `work_request` carries its derived `phase`
(`intake`, `planned`, `active`, `unresolved`, `done` or `archived`),
`completed_at` (when its work became done: the operator's completion or its
latest package ending, otherwise null), `operator_completed_at`, `archived_at`
and `archive_reason`. Deploy observations and repository default branches are not
included by this change.

`GET /api/v1/sympp/operator/events` is a notification-only server-sent event
stream for the same locally authorized browser as the dashboard. It emits
`ready` on connection, `invalidated` after known dashboard changes, and heartbeat
comments. Refetch the hydrated endpoint after either event. Connecting does not
register a dashboard opener or mutate business state. The existing
`/api/v1/sympp/herdr/events` consumer endpoint remains available. Notifications
are hints, not durable history; compare saved client-side timestamps and heads
for best-effort "since last looked" indicators.

The packaged board subscribes to `GET /api/v1/sympp/operator/dashboard/events`
instead. That stream emits `dashboard_changed` after the same changes and
registers the open board, so the backend does not open a second one when a
client attaches.

## Finished goal retention and operator actions

`settings.work_request_archive_after_days` stays an integer day setting, now
defaulting to `3` (72 elapsed hours after `completed_at`, or after the
operator's last restore if that is later, including the exact boundary). Only
goals in phase `done` qualify. The background retention pass runs
every 30 minutes; saving operator settings forces an immediate pass. Dashboard
reads do not run retention. Archiving happens on the next successful pass
after the threshold, rather than on an exact per-goal timer. The existing limit
of ten visible completed goals per repository/base branch can archive older
completed goals sooner.

On upgrade, the normal ledger migrations convert stored archive settings of
`14` to `3`, preserving all other values (including `1`) and settings. An explicitly chosen
`14` is indistinguishable from the former default and also converts; choose
`14` again after upgrading to retain it. The migration cannot safely reverse
that data conversion. No manual database edit is required. Already overdue
completed goals qualify on the next retention pass. The same setting also
controls hiding terminal packages without a parent goal. Completed archived goals
retain their history until deletion; the deletion setting `card_retention_days`
(default 30 days) governs those archives and ended cards.

## Never-started goal retention

`settings.work_request_never_started_archive_after_days` defaults to `30` elapsed
days, configurable from 1 to 3650. A goal qualifies only if it never started:
its phase is `intake` (no packages), or `planned` with no package ever
dispatched or ended. An operator-completed goal never qualifies.

Age starts at goal creation; edits do not reset it. At the exact threshold the
next successful retention pass archives the goal with `archive_reason:
"never_started"`, leaving `completed_at` null. It leaves
the board and appears in `archived_work_requests`; its archive card operational state
is `archived` / `Archived`, rather than completed. Restore clears the archive and
starts a fresh full threshold window from restoration. Changing a retention
setting never restores an archive; only the operator's restore does.

This rule neither queues worktree cleanup nor deletes ledger history. Archives
with this reason are excluded from subsequent automatic archived-goal deletion,
so they remain restorable indefinitely. Explicit operator deletion retains its
existing destructive behavior. Finished-goal retention, the ten-visible-completed
limit, and the existing deletion threshold are unchanged.

Change the setting through the local operator API (replace the base URL with
the running dashboard's origin):

```powershell
$origin = "http://127.0.0.1:4000"
Invoke-RestMethod -Method Post -Uri "$origin/api/v1/sympp/operator/settings" `
  -Headers @{Origin = $origin} -ContentType "application/json" `
  -Body '{"work_request_never_started_archive_after_days":45}'
```

Saving settings forces an immediate pass; otherwise the background cadence is
30 minutes. Dashboard reads remain read-only. The board's settings menu saves
through this route.

## Operator actions

These existing POST routes require local operator authorization:

| Route suffix under `/api/v1/sympp/operator/work-requests/:id` | Preconditions and consequences |
| --- | --- |
| `/complete` | Operator override; no delivery or inactive-worker precondition. Sets `operator_completed_at`, so the phase is `done`; withdraws open asks, clears package blockers and queues terminal package worktree cleanup. Does not stop workers or merge PRs. Confirm the override when work is still running. An archived goal returns `work_request_archived` (409) with `next_action: "restore"`. |
| `/archive` | Requires phase `done` or `unresolved`; otherwise returns `not_completed`. Hides the goal, withdraws its open asks and queues terminal package worktree cleanup. History remains. Archiving again is a no-op. |
| `/delete` | Requires only that the goal exists; archive and completion are **not** backend prerequisites. Permanently removes the goal and dependent ledger history and ownership rows and queues linked worktree cleanup, including nonterminal packages. Confirm deletion and finish or stop active work first; it is not a safe unconditional one-click action. |
| `/release` | Ends the goal's live ownership (`finish_reason: released_by_operator`) so another Herdr terminal's next owner-gated write takes it. Use it for an owner that crashed on a machine the factory can't see. HTTP 200 with `{ok:true, work_request_id, released:<worked_on>, refresh}`; a goal with no live owner returns `{error:{code:"not_owned",message}}` (409). |
| `/restore` | Requires an existing goal. Clears the archive and records `restored_at`, which starts a fresh retention window for both finished and never-started goals. Does not restore deleted worktrees or undo queued cleanup. |

`POST /api/v1/sympp/operator/work-packages/:id/finish` ends a `dispatched` or
`ready` WorkPackage as `finished`: its PR waits on someone else, so sympp stops
watching it. The goal can complete; packages that depend on it stay blocked
until their dependency is removed. Repeating the call returns the same result.
A package that is still `planned` returns `ending_not_allowed`; one that already
ended another way returns `already_ended` (409).

`POST /api/v1/sympp/operator/asks/:id/answer` answers an open ask with the
answer fields and `delivery` result described under
[Native human actions](#native-human-actions).

`POST /api/v1/sympp/operator/decisions/:id/ack`, `…/feedback` and `…/dismiss`
review flagged decisions as described under
[Native human actions](#native-human-actions).

`POST /api/v1/sympp/operator/cards/:id/dismiss` dismisses a card, as described
under [Cards](#cards).

Finish and the five request actions above also have native routes under
`/api/v1/sympp/herdr`, listed under [Native human actions](#native-human-actions).

Worktree cleanup runs asynchronously and defers active workers while
their package records exist. Deleting those records removes that activity check,
so deletion must not be treated as a way to stop a running worker.

## Worked on by

Each `work_requests.work_requests[]` card and `work_request_details[].work_request`
carries `worked_on` when a Herdr terminal owns the goal; it is absent otherwise.

| Field | Meaning |
| --- | --- |
| `address` | Display address of the owning terminal, such as `jjdev/t1q1`. |
| `role` | `architect` or `chief` (from the terminal's `sympp.role` label). |
| `domain` | The chief's `sympp.domain`, when the owner is a chief. |
| `liveness` | `live` when the factory's herdr-core sees the terminal live or its bridge heartbeat is fresh; `finished` when the core reports it finished; otherwise `unknown`. |
| `since` | When this terminal took ownership. |

`unknown` keeps the owner: only a finished terminal, a clean bridge `detach` on a
machine the factory's core can't see, operator Release, or archiving the goal ends
ownership. Use Release on an `unknown` owner that you know has crashed.

`work_request_details[].work_packages[].session_location` remains the configured
machine `label` and `kind` for a package's current agent run, from the
`operator-board.json` `machines` map.

## Cards

The hydrated, deferred and Herdr board reads include `cards`: the work of
terminals the operator talks to, outside WorkPackages. A terminal on the
factory's herdr-core gets a card when it is a child of a chief or architect
terminal, or carries the label `sympp.card=1`, and works on a branch other than
its base or has a PR. Dispatched workers never get cards. Open cards come first,
then the most recently changed.

| Field | Meaning |
| --- | --- |
| `id` | Card id, derived from the terminal. |
| `state` | `working` (branch, no PR), `review_ci` (PR open), `merged`, `done` (PR closed, or the terminal finished without a PR) or `dismissed`. |
| `title` | The terminal's title or name. |
| `worked_on` | The terminal, in the [Worked on by](#worked-on-by) shape with `role: "card"`. |
| `repository`, `base_branch`, `branch` | From `git` in the terminal's directory. |
| `pr` | `{repository, number, url, state, draft, head_sha, ci:{status, completed, total}, github_review}` once a PR is found. |
| `review` | `{id, state, status}` when the terminal labels `sympp.review_id`; `state` is `done`, `pending` or `unknown` for the PR head. |
| `stale` | Inputs the last sweep couldn't read (`github`, `review`). They never end a card. |
| `asks` | The card's open asks, in the ask shape above with `card_id` instead of `work_request_id`. |
| `since`, `ended_at`, `updated_at` | Timestamps. |

A card agent opens an ask with `ask` and no `work_request_id`; the operator
answers it through the same answer routes, and the answer is typed into the
card's terminal. The answer result names `card_id` instead of
`work_request_id`. Ending a card withdraws its open asks. A dismissed, merged or
done card opens again as `working` or `review_ci` when its live terminal starts
work on another branch. `merged`, `done` and `dismissed` cards leave the list
`card_retention_days` after they ended. They leave the ledger then too, once the
factory's herdr-core reports their terminal finished; until then the ended card
stays recorded so its branch isn't taken for new work.

## Review across head changes

A review counts for a package only when Review Suite reports it done with
`accepted_head` equal to the PR's current head. Review Suite carries a review
to a new head when a merge from the base or a rebase leaves the PR's own patch
unchanged, so `main` moving doesn't send a ready package back. The review
signal shows `accepted_head`, plus `reviewed_head` when the head Review Suite
actually reviewed differs. CI must still pass on the new head.

`review_signal.status` is `inspection_needed`, and the package doesn't qualify,
when the PR's patch changed after review (`head_changed_after_review`), or when
a carried review reports a base change that touched the PR's paths or changed
files structurally (`base_interaction`). The caller reviews only what changed,
on the same review id. The web board and Herdr show the inspection needed state.
