defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ProgressEvent)
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(RepoScope)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "primary repo updates preserve existing secondary repo scopes", %{repo: repo} do
    assert {:ok, request} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-MULTI-REPO-UPDATE",
                 repo: "service-a",
                 base_branch: "main",
                 repo_scopes: [
                   %{repo: "service-a", base_branch: "main"},
                   %{repo: "service-b", base_branch: "release"}
                 ]
               )
             )

    assert {:ok, scopes} = Repository.list_repo_scopes(repo, request.id)
    primary_scope = Enum.find(scopes, &(&1.repo == "service-a"))
    repo.update!(Ecto.Changeset.change(primary_scope, base_branch: "origin/main", scope_key: "repo:service-a:origin/main"))

    repo.insert!(%RepoScope{
      id: "WR-MULTI-REPO-UPDATE-LEGACY-ALIAS",
      work_request_id: request.id,
      repo: "service-a",
      base_branch: "refs/heads/main",
      scope_key: "repo:service-a:refs/heads/main"
    })

    request = repo.update!(Ecto.Changeset.change(request, base_branch: "origin/main"))

    assert {:ok, updated} =
             Repository.update(repo, request.id, %{repo: "service-a-renamed", base_branch: "origin/main"})

    assert updated.base_branch == "main"

    assert {:ok, scopes} = Repository.list_repo_scopes(repo, request.id)
    assert Enum.map(scopes, &{&1.repo, &1.base_branch}) == [{"service-a-renamed", "main"}, {"service-b", "release"}]
    refute Enum.any?(scopes, &(&1.repo == "service-a"))
  end

  test "rejects duplicate caller-provided ids", %{repo: repo} do
    attrs = attrs(id: "WR-DUPLICATE")

    assert {:ok, request} = Repository.create(repo, attrs)
    assert request.id == "WR-DUPLICATE"
    assert {:error, :id_already_exists} = Repository.create(repo, attrs)
  end

  test "every phase row is reached, and open questions never change the phase", %{repo: repo} do
    phase = fn id -> phase!(repo, id) end

    assert {:ok, intake} = Repository.create(repo, attrs(id: "WR-PHASE-INTAKE"))
    assert {:ok, _question} = Repository.ask_question(repo, intake.id, question_attrs(id: "WRQ-PHASE-INTAKE"))
    assert phase.(intake.id) == "intake"

    planned = request_with_packages!(repo, "WR-PHASE-PLANNED", [:planned])
    assert phase.(planned.id) == "planned"

    mixed = request_with_packages!(repo, "WR-PHASE-PLANNED-ENDED", [:planned, :completed_no_pr])
    assert phase.(mixed.id) == "planned"

    dispatched = request_with_packages!(repo, "WR-PHASE-DISPATCHED", [:dispatched, :planned, :completed_no_pr])
    assert phase.(dispatched.id) == "active"

    ready = request_with_packages!(repo, "WR-PHASE-READY", [:ready, :abandoned])
    assert phase.(ready.id) == "active"

    done = request_with_packages!(repo, "WR-PHASE-DONE", [:completed_no_pr, :pr_merged, :finished, :skipped])
    assert {:ok, _question} = Repository.ask_question(repo, done.id, question_attrs(id: "WRQ-PHASE-DONE"))
    assert phase.(done.id) == "done"

    abandoned = request_with_packages!(repo, "WR-PHASE-ABANDONED", [:completed_no_pr, :abandoned])
    assert phase.(abandoned.id) == "unresolved"

    all_skipped = request_with_packages!(repo, "WR-PHASE-ALL-SKIPPED", [:skipped, :skipped])
    assert phase.(all_skipped.id) == "unresolved"

    operator_done = request_with_packages!(repo, "WR-PHASE-OPERATOR", [:planned])
    assert {:ok, _completed} = Service.complete(repo, operator_done.id)
    assert phase.(operator_done.id) == "done"

    assert {:ok, archived} = Service.archive(repo, done.id)
    assert phase.(archived.id) == "archived"

    assert {:ok, summaries} = Phase.load(repo, [repo.get!(WorkRequest, abandoned.id)])
    assert Phase.next_action(summaries[abandoned.id].phase) == "complete_or_archive"
    assert Phase.next_action("archived") == "restore"

    assert {:ok, listed} = Repository.list(repo, %{phase: "unresolved"})
    assert Enum.map(listed, & &1.id) == [abandoned.id, all_skipped.id]
    assert {:ok, [%WorkRequest{id: archived_id}]} = Repository.list(repo, %{phase: "archived"})
    assert archived_id == done.id
  end

  test "writes to an archived WorkRequest are refused, nothing restores it implicitly, and restore does", %{repo: repo} do
    request = request_with_packages!(repo, "WR-ARCHIVED-WRITES", [:completed_no_pr])
    assert {:ok, question} = Repository.ask_question(repo, request.id, question_attrs(id: "WRQ-BEFORE-ARCHIVE"))
    assert {:ok, archived} = Service.archive(repo, request.id)
    [package] = repo.all(from(package in WorkPackage, where: package.work_request_id == ^request.id))

    assert {:error, :work_request_archived} = Repository.ask_question(repo, request.id, question_attrs(id: "WRQ-ARCHIVED"))
    assert {:error, :work_request_archived} = Repository.record_decision(repo, request.id, decision_attrs(id: "WRD-ARCHIVED"))
    assert {:error, :work_request_archived} = Repository.answer_question(repo, question.id, "open", %{answer: "Late.", answered_by: "operator"})

    assert {:error, :work_request_archived} =
             PlanningRepository.append_progress_event(repo, %{work_package_id: package.id, summary: "Late note", status: "recorded", idempotency_key: "late"})

    assert {:error, :work_request_archived} = Repository.slice_work_request(repo, request.id, [work_package_attrs(id: "WRS-ARCHIVED-NEW")])
    assert {:error, :work_request_archived} = Service.complete(repo, request.id)
    assert {:ok, ^archived} = Repository.get(repo, request.id)
    assert {:ok, [_only_package]} = Repository.list_work_packages(repo, request.id)
    assert {:ok, [%ClarificationQuestion{status: "open"}]} = Repository.list_questions(repo, request.id)
    assert {:ok, []} = Repository.list_decisions(repo, request.id)

    assert {:ok, restored} = Service.restore(repo, request.id)
    assert restored.archived_at == nil
    assert restored.archive_reason == nil
    assert %DateTime{} = restored.restored_at
    assert phase!(repo, request.id) == "done"
    assert {:ok, ^restored} = Service.restore(repo, request.id)
  end

  test "a worker left running on an archived WorkRequest can still be released, and only through the trusted path", %{repo: repo} do
    request = request_with_packages!(repo, "WR-ARCHIVED-RUNNING", [:dispatched])
    [package] = repo.all(from(package in WorkPackage, where: package.work_request_id == ^request.id))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _completed} = Service.complete(repo, request.id)
    assert {:ok, _archived} = Service.archive(repo, request.id)

    release = %{"summary" => "Worker claim released", "status" => "worker_claim_released", "idempotency_key" => "release-after-archive"}

    assert {:error, :work_request_archived} = PlanningRepository.append_progress_event(repo, Map.put(release, "work_package_id", package.id))
    assert {:error, :work_request_archived} = PlanningRepository.append_audit_progress_event_for_work_package(repo, assignment, package.id, release)

    assert {:ok, %ProgressEvent{status: "worker_claim_released"}} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, assignment, package.id, release, runtime_authority: true)
  end

  test "the operator archives only done or unresolved work, and completes any work", %{repo: repo} do
    assert {:ok, intake} = Repository.create(repo, attrs(id: "WR-ARCHIVE-INTAKE"))
    planned = request_with_packages!(repo, "WR-ARCHIVE-PLANNED", [:planned])
    active = request_with_packages!(repo, "WR-ARCHIVE-ACTIVE", [:dispatched])

    for request <- [intake, planned, active] do
      assert {:error, :not_completed} = Service.archive(repo, request.id)
      assert repo.get!(WorkRequest, request.id).archived_at == nil
    end

    unresolved = request_with_packages!(repo, "WR-ARCHIVE-UNRESOLVED", [:abandoned])
    assert {:ok, archived} = Service.archive(repo, unresolved.id)
    assert archived.archive_reason == "manual"
    assert {:ok, ^archived} = Service.archive(repo, unresolved.id)

    assert {:ok, _question} = Repository.ask_question(repo, planned.id, question_attrs(id: "WRQ-ARCHIVE-PLANNED"))
    assert {:ok, completed} = Service.complete(repo, planned.id)
    assert %DateTime{} = completed.operator_completed_at
    assert {:ok, [%ClarificationQuestion{status: "closed"}]} = Repository.list_questions(repo, planned.id)
    assert {:ok, again} = Service.complete(repo, planned.id)
    assert again.operator_completed_at == completed.operator_completed_at
    assert phase!(repo, planned.id) == "done"
    assert {:ok, _archived} = Service.archive(repo, planned.id)
  end

  test "retention archives done work at exactly seventy-two hours and preserves unfinished goals and history", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    old_completed_at = utc_usec(~U[2026-05-20 12:00:00Z])
    recent_completed_at = DateTime.add(old_completed_at, 1, :microsecond)

    old_request = completed_delivered_request!(repo, "WR-RETENTION-OLD", old_completed_at)
    recent_request = completed_delivered_request!(repo, "WR-RETENTION-RECENT", recent_completed_at)
    unresolved = request_with_packages!(repo, "WR-RETENTION-UNRESOLVED", [:abandoned])
    assert {:ok, unfinished} = Repository.create(repo, attrs(id: "WR-RETENTION-UNFINISHED"))

    assert {:ok, _decision} =
             Repository.record_decision(repo, old_request.id, decision_attrs(id: "WRD-RETENTION-OLD"))

    assert {:ok, before_boundary} = Service.retention_pass(repo, now: DateTime.add(now, -1, :microsecond))
    assert before_boundary.archived_ids == []

    assert {:ok, summary} = Service.retention_pass(repo, now: now)
    assert summary.archived_ids == [old_request.id]
    assert summary.archived_count == 1

    assert {:ok, archived} = Repository.get(repo, old_request.id)
    assert archived.archive_reason == "age"
    assert %DateTime{} = archived.archived_at

    assert {:ok, [_slice]} = Repository.list_work_packages(repo, old_request.id)
    assert {:ok, [_decision]} = Repository.list_decisions(repo, old_request.id)

    assert {:ok, visible} = Repository.list(repo)
    assert Enum.map(visible, & &1.id) == [recent_request.id, unresolved.id, unfinished.id]
    assert {:ok, all_requests} = Repository.list(repo, %{include_archived: true})
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id, unresolved.id, unfinished.id]

    assert {:ok, all_requests} = Repository.list(repo, %{"include_archived" => "true"})
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id, unresolved.id, unfinished.id]

    assert {:ok, all_requests} = Repository.list(repo, include_archived: true)
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id, unresolved.id, unfinished.id]
  end

  test "an operator restore restarts the age window, and a longer window restores age archives", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    request = completed_delivered_request!(repo, "WR-RETENTION-RESTORE", utc_usec(~U[2026-05-01 00:00:00Z]))

    assert {:ok, %{archived_ids: [id]}} = Service.retention_pass(repo, now: now)
    assert id == request.id
    assert {:ok, %{archived_ids: []}} = Service.retention_pass(repo, now: now, archive_after_days: 3650)
    assert repo.get!(WorkRequest, id).archived_at == nil

    assert {:ok, %{archived_ids: [^id]}} = Service.retention_pass(repo, now: now)
    assert {:ok, restored} = Service.restore(repo, id)
    window_end = DateTime.add(restored.restored_at, 3, :day)
    assert {:ok, %{archived_ids: []}} = Service.retention_pass(repo, now: DateTime.add(window_end, -1, :microsecond))
    assert {:ok, %{archived_ids: [^id]}} = Service.retention_pass(repo, now: window_end)
  end

  test "retention emits no writes when no WorkRequest is eligible", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    recent_completed_at = now |> DateTime.add(-72 * 60 * 60, :second) |> DateTime.add(1, :microsecond)

    assert {:ok, _draft} = Repository.create(repo, attrs(id: "WR-RETENTION-INELIGIBLE-DRAFT"))
    completed_delivered_request!(repo, "WR-RETENTION-INELIGIBLE-RECENT", recent_completed_at)

    assert {{:ok, summary}, queries} = capture_queries(fn -> Service.retention_pass(repo, now: now) end)
    assert summary.archived_count == 0
    assert summary.deleted_count == 0
    assert Enum.filter(queries, &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/i, &1)) == []
  end

  test "never-started retention uses the exact age boundary and a fresh restore window", %{repo: repo} do
    now = DateTime.utc_now(:microsecond)
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-NEVER-STARTED", repo: "example-org/retention"))
    old = repo.update!(Ecto.Changeset.change(request, inserted_at: DateTime.add(now, -30, :day)))
    assert {:ok, _edited} = Repository.update(repo, old.id, %{title: "Recent edit does not reset retention"})

    assert {:ok, %{archived_ids: []}} = Service.retention_pass(repo, now: DateTime.add(now, -1, :microsecond))
    assert {:ok, %{archived_ids: [id]}} = Service.retention_pass(repo, now: now)
    assert id == request.id
    assert {:ok, archived} = Repository.get(repo, id)
    assert archived.archive_reason == "never_started"
    assert archived.operator_completed_at == nil
    assert archived.archived_at == now
    assert {:ok, []} = Repository.list(repo)

    assert {:ok, restored} = Service.restore(repo, id)
    assert restored.archived_at == nil
    assert restored.inserted_at == old.inserted_at
    assert %DateTime{} = restored.restored_at
    next_boundary = DateTime.add(restored.restored_at, 30, :day)
    assert {:ok, %{archived_ids: []}} = Service.retention_pass(repo, now: DateTime.add(next_boundary, -1, :microsecond))
    assert {:ok, %{archived_ids: [^id]}} = Service.retention_pass(repo, now: next_boundary)
  end

  test "never-started retention archives intake and planned work and keeps everything else", %{repo: repo} do
    now = DateTime.utc_now(:microsecond)

    requests =
      Map.new(
        [
          intake: [],
          planned: [:planned],
          planned_after_endings: [:planned, :completed_no_pr],
          active: [:dispatched],
          done: [:completed_no_pr],
          unresolved: [:abandoned]
        ],
        fn {name, packages} ->
          request = request_with_packages!(repo, "WR-NEVER-#{name}", packages)
          {name, repo.update!(Ecto.Changeset.change(request, inserted_at: DateTime.add(now, -90, :day)))}
        end
      )

    assert {:ok, summary} = Service.retention_pass(repo, now: now, archive_after_days: 3650, delete_after_days: 1)
    expected = Enum.map([:intake, :planned, :planned_after_endings], &requests[&1].id)
    assert MapSet.new(summary.archived_ids) == MapSet.new(expected)

    for {name, request} <- Map.take(requests, [:active, :done, :unresolved]) do
      assert repo.get!(WorkRequest, request.id).archived_at == nil, "#{name} must remain visible"
    end
  end

  test "retention deletes expired archived work requests and their grant scopes", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    stale_at = utc_usec(~U[2026-05-20 12:00:00Z])
    recent_at = utc_usec(~U[2026-05-22 12:00:00Z])

    expired = completed_delivered_request!(repo, "WR-RETENTION-DELETE-EXPIRED", stale_at)
    assert {:ok, expired_archived} = Service.archive(repo, expired.id)
    set_archived_at!(repo, expired_archived, stale_at)
    expired_slice_id = "WRS-#{expired.id}"

    active = completed_delivered_request!(repo, "WR-RETENTION-DELETE-ACTIVE", recent_at)

    scope_owner = create_activity_work_package!(repo, "WP-RETENTION-SCOPE-OWNER", status: "ended")
    grant = insert_claimed_activity_grant!(repo, scope_owner, "worker", "retention-worker")
    insert_grant_scope!(repo, grant.id, "work_request", expired.id)
    insert_grant_scope!(repo, grant.id, "work_package", expired_slice_id)

    completed = completed_delivered_request!(repo, "WR-RETENTION-DELETE-COMPLETED", stale_at)
    assert {:ok, open} = Repository.create(repo, attrs(id: "WR-RETENTION-DELETE-OPEN"))

    recent_archived = completed_delivered_request!(repo, "WR-RETENTION-DELETE-RECENT", stale_at)
    assert {:ok, recent_archived} = Service.archive(repo, recent_archived.id)
    recent_archived = set_archived_at!(repo, recent_archived, recent_at)

    assert {:ok, summary} =
             Service.retention_pass(repo,
               now: now,
               archive_after_days: 3650,
               delete_after_days: 1
             )

    assert summary.deleted_ids == [expired.id]
    assert summary.deleted_count == 1
    assert {:error, :not_found} = Service.get(repo, expired.id)
    assert grant_scope_count(repo, "work_request", expired.id) == 0
    assert grant_scope_count(repo, "work_package", expired_slice_id) == 0

    assert {:ok, ^active} = Service.get(repo, active.id)
    assert {:ok, ^completed} = Service.get(repo, completed.id)
    assert {:ok, ^open} = Service.get(repo, open.id)
    assert {:ok, ^recent_archived} = Service.get(repo, recent_archived.id)
  end

  test "historical cyclic, missing and foreign lineage cannot resolve delivery" do
    packages =
      Map.new(["original", "pointer", "recut", "leaf", "foreign"], fn id ->
        {id, %WorkPackage{id: id, work_request_id: if(id == "foreign", do: "other", else: "wr"), status: "ended"}}
      end)

    deliveries = %{
      "original" => %{outcome: "superseded", successor_work_package_id: "pointer"},
      "pointer" => %{outcome: "pr_merged"},
      "recut" => %{outcome: "superseded", successor_work_package_id: "leaf"}
    }

    successors = %{"original" => ["recut", "pointer"]}
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, successors)
    deliveries = Map.put(deliveries, "leaf", %{outcome: "completed_no_pr"})
    assert DeliveryResolution.resolves_work_request?("original", packages, deliveries, successors)
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, Map.put(successors, "recut", ["original"]))
    refute DeliveryResolution.resolves_work_request?("original", packages, deliveries, Map.put(successors, "recut", ["missing"]))
    refute DeliveryResolution.resolves_work_request?("original", packages, Map.put(deliveries, "foreign", %{outcome: "pr_merged"}), %{"original" => ["foreign"]})

    # Historical actual delivery remains factual even after contradictory retirement annotations.
    delivered = Map.put(deliveries, "original", %{outcome: "pr_merged"})
    assert DeliveryResolution.resolves_work_request?("original", packages, delivered, %{"original" => ["missing", "original"]})
  end

  test "the phase follows same-request recuts alongside the immutable successor pointer", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-SUCCESSOR-UNION"))

    [original, pointer, recut] =
      for id <- ["original", "pointer", "recut"] do
        assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-UNION-#{id}"))
        package
      end

    end_package!(repo, original, %{outcome: "superseded", successor_work_package_id: pointer.id, superseded_reason: "Replace the original scope."})
    end_package!(repo, pointer)
    end_package!(repo, recut, %{outcome: "skipped"})
    assert phase!(repo, request.id) == "done"

    assert {:ok, _lineage} = OperationalLineage.record_recut_as(repo, original.id, recut.id, %{reason: "Additional required branch.", decision: %{work_request_id: request.id}})
    assert {:ok, foreign_request} = Repository.create(repo, attrs(id: "WR-FOREIGN-SUCCESSOR"))
    assert {:ok, foreign} = CanonicalWorkPackageFixtures.add_work_package(repo, foreign_request.id, work_package_attrs(id: "WRS-FOREIGN-SUCCESSOR"))
    assert {:ok, _foreign_lineage} = OperationalLineage.record_recut_as(repo, original.id, foreign.id, %{reason: "Another request is not successor scope.", decision: %{work_request_id: request.id}})
    assert phase!(repo, request.id) == "unresolved"

    assert {:ok, _missing_lineage} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: original.id,
               summary: "Historical recut points to missing work.",
               status: "operational_lineage_recorded",
               idempotency_key: "missing-recut",
               payload: %{type: "operational_lineage", source_tool: "record_operational_lineage", relationship: "recut_as", target_work_package_id: "missing"}
             })

    assert phase!(repo, request.id) == "unresolved"
  end

  test "abandoned scope stays unresolved while explicit operator completion remains authoritative", %{repo: repo} do
    request = request_with_packages!(repo, "WR-RETIRED-SCOPE", [:abandoned])
    assert phase!(repo, request.id) == "unresolved"

    assert {:ok, accepted} = Service.complete(repo, request.id)
    assert %DateTime{} = accepted.operator_completed_at
    assert phase!(repo, request.id) == "done"
  end

  test "activity context derives active stale recycled and terminal runtime state", %{repo: repo} do
    now = DateTime.utc_now(:microsecond)
    stale_seen_at = DateTime.add(now, -10, :second)

    active_package = create_activity_work_package!(repo, "WP-ACTIVITY-ACTIVE", status: "dispatched")
    stale_package = create_activity_work_package!(repo, "WP-ACTIVITY-STALE", status: "dispatched")
    mixed_package = create_activity_work_package!(repo, "WP-ACTIVITY-MIXED", status: "dispatched")
    recycled_package = create_activity_work_package!(repo, "WP-ACTIVITY-RECYCLED", status: "dispatched")
    ready_package = create_activity_work_package!(repo, "WP-ACTIVITY-READY", status: "ready")
    terminal_package = create_activity_work_package!(repo, "WP-ACTIVITY-TERMINAL", status: "dispatched")
    agent_package = create_activity_work_package!(repo, "WP-ACTIVITY-AGENT-STALE", status: "dispatched")

    assert {:ok, _active_lease} =
             ClaimLeaseService.claim(repo, active_package.id, activity_actor("active-worker"), stale_after_ms: 60_000)

    insert_claimed_activity_grant!(repo, active_package, "architect", "active-architect")

    assert {:ok, _stale_lease} =
             ClaimLeaseService.claim(repo, stale_package.id, activity_actor("stale-worker"), now: stale_seen_at, stale_after_ms: 1)

    assert {:ok, _mixed_stale_lease} =
             ClaimLeaseService.claim(repo, mixed_package.id, activity_actor("mixed-worker"), now: stale_seen_at, stale_after_ms: 1)

    insert_claimed_activity_grant!(repo, mixed_package, "architect", "mixed-architect")

    assert {:ok, _reclaimed_lease} =
             ClaimLeaseService.claim(repo, recycled_package.id, activity_actor("old-worker"), now: stale_seen_at, stale_after_ms: 1)

    assert {:ok, replacement_lease} =
             ClaimLeaseService.reclaim_stale(repo, recycled_package.id, activity_actor("replacement-worker"),
               reason: "worker_recycled",
               stale_after_ms: 60_000
             )

    insert_claimed_activity_grant!(repo, ready_package, "worker", "ready-worker")

    assert {:ok, ready_lease} =
             ClaimLeaseService.claim(repo, ready_package.id, activity_actor("ready-worker"), stale_after_ms: 60_000)

    assert {:ok, _released_ready_lease} = ClaimLeaseService.release(repo, ready_lease.id, reason: "worker finished")

    assert {:ok, _completed_ready_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: ready_package.id,
               status: "completed",
               started_at: DateTime.add(now, -60, :second),
               last_seen_at: now,
               finished_at: now
             })

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: agent_package.id,
               status: "running",
               last_seen_at: DateTime.add(now, -301, :second)
             })

    assert {:ok, _terminal_lease} =
             ClaimLeaseService.claim(repo, terminal_package.id, activity_actor("terminal-worker"), now: stale_seen_at, stale_after_ms: 1)

    insert_claimed_activity_grant!(repo, terminal_package, "architect", "terminal-architect")

    assert {:ok, _terminal_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: terminal_package.id,
               status: "running",
               last_seen_at: DateTime.add(now, -301, :second)
             })

    terminal_package = set_work_package_status!(repo, terminal_package, "ended")

    contexts =
      WorkPackageActivity.contexts(repo, [
        active_package.id,
        stale_package.id,
        mixed_package.id,
        recycled_package.id,
        ready_package.id,
        terminal_package.id,
        agent_package.id
      ])

    assert get_in(contexts, [active_package.id, :runtime_state, :lifecycle_state]) == "active"
    assert get_in(contexts, [active_package.id, :runtime_state, :reason_codes]) == ["claim_lease_active", "architect_grant_active"]

    stale_runtime = get_in(contexts, [stale_package.id, :runtime_state])
    assert stale_runtime.active? == true
    assert stale_runtime.stale? == true
    assert "claim_lease_stale" in stale_runtime.reason_codes
    assert DateTime.compare(stale_runtime.latest_gate_at, DateTime.add(stale_seen_at, 1, :millisecond)) == :eq

    mixed_runtime = get_in(contexts, [mixed_package.id, :runtime_state])
    assert mixed_runtime.active? == true
    assert mixed_runtime.stale? == true
    assert mixed_runtime.lifecycle_state == "stale"
    assert "claim_lease_stale" in mixed_runtime.reason_codes
    assert "architect_grant_active" in mixed_runtime.reason_codes

    recycled_runtime = get_in(contexts, [recycled_package.id, :runtime_state])
    assert recycled_runtime.active? == true
    assert recycled_runtime.recycled? == true
    assert recycled_runtime.lifecycle_state == "active"
    assert "worker_recycled" in recycled_runtime.reason_codes
    assert DateTime.compare(recycled_runtime.latest_gate_at, DateTime.add(stale_seen_at, 1, :millisecond)) == :gt
    assert get_in(contexts, [recycled_package.id, :worker_signal, :active_since]) == replacement_lease.lease_started_at

    ready_context = contexts[ready_package.id]
    assert ready_context.runtime_state.active? == false
    assert ready_context.runtime_state.lifecycle_state == "idle"
    assert ready_context.worker_signal.status == "idle"

    terminal_runtime = get_in(contexts, [terminal_package.id, :runtime_state])
    assert terminal_runtime.active? == true
    assert terminal_runtime.stale? == true
    assert terminal_runtime.terminal? == true
    assert terminal_runtime.lifecycle_state == "stale"
    assert "claim_lease_stale" in terminal_runtime.reason_codes
    assert "agent_run_stale" in terminal_runtime.reason_codes
    assert "architect_grant_active" in terminal_runtime.reason_codes
    assert "package_terminal" in terminal_runtime.reason_codes

    agent_runtime = get_in(contexts, [agent_package.id, :runtime_state])
    assert agent_runtime.active? == false
    assert agent_runtime.stale? == true
    assert agent_runtime.lifecycle_state == "stale"
    assert "agent_run_stale" in agent_runtime.reason_codes
    assert agent_runtime.active_agent_run_ids == []
    assert agent_runtime.stale_agent_run_ids == [agent_run.id]
  end

  defp attrs(overrides) do
    defaults = %{
      title: "Improve intake flow",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Complete WorkRequest state",
      goal: "Track completed WorkRequests.",
      kind: "mcp",
      base_branch: "main",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: [],
      acceptance_criteria: ["Completion state is explicit."],
      validation_steps: ["mix test"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: []
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "product",
      question: "Is the WorkRequest done?",
      why_needed: "Open human questions keep the WorkRequest visible."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Archive only after completion.",
      rationale: "The ledger remains the audit source.",
      scope_impact: "No hard delete.",
      created_by: "retention-test"
    }

    Enum.into(overrides, defaults)
  end

  defp phase!(repo, id) do
    assert {:ok, %{phase: phase}} = Phase.load_one(repo, repo.get!(WorkRequest, id))
    phase
  end

  # Ends a package the way the lifecycle does: one ending row, then status `ended`.
  defp end_package!(repo, package, evidence \\ %{}) do
    defaults = %{
      work_request_id: package.work_request_id,
      work_package_id: package.id,
      outcome: "completed_no_pr",
      idempotency_key: "delivered-#{package.id}",
      no_pr_evidence: "Historical direct completion evidence."
    }

    defaults = if Map.get(evidence, :outcome) in ["completed_no_pr", nil], do: defaults, else: Map.delete(defaults, :no_pr_evidence)
    {recorded_at, evidence} = Map.pop(evidence, :recorded_at)
    assert {:ok, delivery} = defaults |> Map.merge(evidence) |> WorkPackageDelivery.create_changeset() |> repo.insert()
    if recorded_at, do: repo.update!(Ecto.Changeset.change(delivery, recorded_at: recorded_at))
    repo.update!(Ecto.Changeset.change(package, status: "ended"))
  end

  @ending_evidence %{
    completed_no_pr: %{},
    pr_merged: %{
      outcome: "pr_merged",
      pr_url: "https://github.com/nextide/example/pull/7",
      pr_number: 7,
      pr_repository: "nextide/example",
      pr_merged_at: ~U[2026-05-01 00:00:00.000000Z],
      merge_commit_sha: "abc1234"
    },
    finished: %{outcome: "finished"},
    skipped: %{outcome: "skipped"},
    abandoned: %{outcome: "abandoned", abandoned_rationale: "The operator dropped this scope."}
  }

  # One package per state: :planned, :dispatched, :ready, or an ending outcome.
  defp request_with_packages!(repo, id, states) do
    assert {:ok, request} = Repository.create(repo, attrs(id: id))

    states
    |> Enum.with_index(1)
    |> Enum.each(fn {state, index} ->
      assert {:ok, package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-#{id}-#{index}"))

      case state do
        :planned -> package
        open when open in [:dispatched, :ready] -> set_work_package_status!(repo, package, Atom.to_string(open))
        outcome -> end_package!(repo, package, Map.fetch!(@ending_evidence, outcome))
      end
    end)

    repo.get!(WorkRequest, request.id)
  end

  defp completed_delivered_request!(repo, id, completed_at, overrides \\ []) do
    assert {:ok, request} = Repository.create(repo, attrs(Keyword.merge([id: id], overrides)))

    assert {:ok, slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-#{id}", base_branch: request.base_branch))

    end_package!(repo, slice, %{recorded_at: completed_at})
    repo.get!(WorkRequest, request.id)
  end

  defp create_activity_work_package!(repo, id, overrides) do
    attrs =
      overrides
      |> Map.new()
      |> Map.merge(%{
        id: id,
        kind: "mcp",
        title: id,
        repo: "nextide/example",
        base_branch: "main",
        acceptance_criteria: ["Activity context is projected."]
      })

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp activity_actor(name) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "agent:#{name}",
      "actor_display_name" => name
    }
  end

  defp insert_claimed_activity_grant!(repo, work_package, role, claimed_by) do
    suffix = System.unique_integer([:positive]) |> Integer.to_string(36)

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               id: "grant-#{work_package.id}-#{suffix}",
               work_package_id: work_package.id,
               display_key: suffix |> String.pad_leading(4, "0") |> String.slice(-4, 4),
               secret_hash: :crypto.hash(:sha256, "activity-#{work_package.id}-#{suffix}") |> Base.encode16(case: :lower),
               grant_role: role,
               capabilities: []
             })

    now = DateTime.utc_now(:microsecond)

    grant
    |> Ecto.Changeset.change(claimed_at: now, claimed_by: claimed_by, updated_at: now)
    |> repo.update!()
  end

  defp insert_grant_scope!(repo, access_grant_id, scope_type, scope_id) do
    now = DateTime.utc_now(:microsecond)

    assert {1, _rows} =
             repo.insert_all("sympp_access_grant_scopes", [
               %{
                 id: "ags-retention-#{access_grant_id}-#{scope_type}",
                 access_grant_id: access_grant_id,
                 scope_type: scope_type,
                 scope_key: "#{scope_type}:#{scope_id}",
                 scope_id: scope_id,
                 inserted_at: now,
                 updated_at: now
               }
             ])
  end

  defp grant_scope_count(repo, scope_type, scope_id) do
    %{rows: [[count]]} =
      SQL.query!(
        repo,
        "SELECT COUNT(*) FROM sympp_access_grant_scopes WHERE scope_type = ? AND scope_id = ?",
        [scope_type, scope_id]
      )

    count
  end

  defp utc_usec(%DateTime{} = datetime), do: %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

  defp set_archived_at!(repo, %WorkRequest{} = work_request, %DateTime{} = archived_at) do
    work_request
    |> Ecto.Changeset.change(archived_at: archived_at, updated_at: archived_at)
    |> repo.update!()
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, to_string(metadata.query || "")}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp set_work_package_status!(repo, work_package, status) do
    repo.update!(
      Ecto.Changeset.change(work_package,
        status: status,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-requests-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
