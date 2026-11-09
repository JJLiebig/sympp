# Operator board API

`GET /api/v1/sympp/herdr/dashboard` is the optional native-client read of the
same hydrated board projection as the browser endpoint below. It includes each
request's packages with their group paths, the execution graph, attention,
package/delivery signals and which terminal
works on each request (`worked_on`, below).
The normal standalone web board and its authorization are unchanged.

Each `work_request_details[]` includes `asks`, the outstanding clarification and
architect questions. Each ask has `{id, kind, text, work_package_id,
answer_route}`. `kind` is `clarification` or `architect`; an `architect` ask is a
pending architect question carried over in the request's operator report. IDs
remain stable while the ask is open. Asks have
`work_package_id: null`. `answer_route` is the existing native POST path,
accepting `{answer: "..."}` and the other answer fields documented below. Only
clarification questions are answerable there; architect escalations have
`answer_route: null`. Send those to the topic's chief. Answered/resolved asks
leave the list on the next read.

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

Like the existing Herdr detail/event routes, this read requires a loopback peer,
a local Host, and no `Forwarded`, `X-Forwarded-*` or `X-Real-IP` headers. Native
clients need no Origin or browser fetch metadata. This existing native policy
does not validate Origin; it is not the browser operator policy. The route
returns HTTP 401 for nonlocal or forwarded requests and HTTP 405 for other
methods. It grants no operator mutation authority. It reads an initialized
ledger without running migrations, registering a dashboard opener, or writing
ownership, audit or business state. Subscribe to
`/api/v1/sympp/herdr/events` and refetch after invalidation.

`GET /api/v1/sympp/herdr/work-requests/:work_request_id` uses the same native
read authority and never runs ledger migrations. It returns the request's
clarification questions, packages, execution graph,
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
| `/work-requests/:id/questions/:question_id/answer` | Answer fields below; HTTP 200 with `{ok:true, work_request_id, question_id, refresh:{dashboard:true, work_request_id}}`. |

Native human authority means a trusted direct local process, not an authenticated
Herdr application identity. Requests require a loopback peer and local Host,
`Content-Type: application/json` (a charset parameter is accepted), and no
`Origin`, `Sec-Fetch-*`, `Forwarded`, `X-Forwarded-*` or `X-Real-IP` headers.
Invalid native authority returns HTTP 401. These POST routes grant no CORS access
or OPTIONS preflight: other methods return HTTP 405. Browser forms cannot send
JSON, script JSON requests require preflight, and browser fetch metadata is
refused. The native read policy above and browser operator policy stay unchanged.
This does not protect against an untrusted process already running locally.

Minimal intake JSON is
`{"title":"Widget","repo":"example/service","base_branch":"beta","human_description":"Build the agreed widget."}`.
Optional fields use existing operator defaults: `work_type: "feature"`,
`desired_dispatch_shape: "architect_led_feature_branch"` and `constraints: {}`. Intake creates the request with no
owner and starts no agent. Unknown request fields are ignored.

Read persisted questions from
`work_request_details[].clarification_questions[]`: `id`, `work_request_id`,
`question`, `why_needed`, `decision_prompt`, `status`, `answer`, `answered_by`
and `answered_at`. Only `status: "open"` is answerable.

A structured `decision_prompt` has `tl_dr`, `details`, 1–4 `options` with `id`,
`label` and `answer` (optional `description`, `pros` and `cons`), and an optional
`custom_redirect_label`. Render the persisted options. Submit
`{"answer_choice":"<option id>","answer_note":"optional note"}`; a structured
prompt does not accept `answer` alone. The custom choice `__custom_redirect__`
requires a nonblank `answer_note`. Without a structured prompt, submit
`{"answer":"the human's answer"}`. The backend records `local-operator` as the
answer author; a successful answer does not automatically resume or unblock work.

Refetch the native board after success or its event-stream invalidation. Errors
use `{error:{code,message}}`: malformed input/choice returns HTTP 422,
absent/wrong-scope targets return HTTP 404, and an already answered/closed
clarification question returns HTTP 409. No draft-edit, deletion, dispatch or
ownership mutation is exposed by these native routes.

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

Repository signals use only existing local checkouts under the factory repos root,
with the same identity and ambiguity rules as checkout resolution. They never
clone or call GitHub. Results (including unresolved checkouts) are cached per
repository in a shared repos-root inventory for 30 seconds.

Review progress remains in `review_signal.step`, `current`, `total`, `round`,
`evidence_id`, `reviewed_head`, `started_at`, `round_started_at`, `observed_at` and
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
retain their history until deletion; the existing deletion setting
`solo_session_delete_after_days` also governs those archives (default 30 days).

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
| `/complete` | Operator override; no delivery or inactive-worker precondition. Sets `operator_completed_at`, so the phase is `done`; closes open questions, clears package blockers and queues terminal package worktree cleanup. Does not stop workers or merge PRs. Confirm the override when work is still running. An archived goal returns `work_request_archived` (409) with `next_action: "restore"`. |
| `/archive` | Requires phase `done` or `unresolved`; otherwise returns `not_completed`. Hides the goal and queues terminal package worktree cleanup. History remains. Archiving again is a no-op. |
| `/delete` | Requires only that the goal exists; archive and completion are **not** backend prerequisites. Permanently removes the goal and dependent ledger history and ownership rows and queues linked worktree cleanup, including nonterminal packages. Confirm deletion and finish or stop active work first; it is not a safe unconditional one-click action. |
| `/release` | Ends the goal's live ownership (`finish_reason: released_by_operator`) so another Herdr terminal's next owner-gated write takes it. Use it for an owner that crashed on a machine the factory can't see. HTTP 200 with `{ok:true, work_request_id, released:<worked_on>, refresh}`; a goal with no live owner returns `not_owned` (409). |
| `/restore` | Requires an existing goal. Clears the archive and records `restored_at`, which starts a fresh retention window for both finished and never-started goals. Does not restore deleted worktrees or undo queued cleanup. |

`POST /api/v1/sympp/operator/work-packages/:id/finish` ends a `dispatched` or
`ready` WorkPackage as `finished`: its PR waits on someone else, so sympp stops
watching it. The goal can complete; packages that depend on it stay blocked
until their dependency is removed. Repeating the call returns the same result.
A package that is still `planned` returns `ending_not_allowed`; one that already
ended another way returns `already_ended` (409).

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

## Review descendants

A Review Suite `head_changed_after_review` observation becomes
`review_signal.status: "inspection_needed"`, with the original provider status
and stale observation preserved. It means the reviewed head changed and the caller
must inspect the delta; it is neither a failed review nor exact-head approval.
The signal retains `reviewed_head`, `current_head` and the provider's validation
summary when supplied. The web board and Herdr show the inspection needed state
even when a qualified package is already awaiting integration.

For an eligible no-repeat descendant, the architect records acceptance of the
reviewed/current head pair, inspected delta and validation evidence in the package
handoff. Follow the installed Review Suite recovery procedure to decide whether
a repeat is needed; file extensions alone do not establish eligibility. This
acceptance does not rewrite the native verdict or fabricate a passed exact-head
review: the board continues to show inspection needed while the provider reports
it. Merge eligibility remains a separate canonical gate, including current input
and qualification requirements. Behavioral changes retain their required review
and validation.
