defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryCloseoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
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
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "delivery evidence remains terminal truth after package status drift", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-terminal-truth",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/130",
        pr_number: 130,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 13:00:00.000000Z],
        merge_commit_sha: "abc130"
      })

    assert {:ok, _delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert {:ok, _drifted} = WorkPackageRepository.update(repo, linked_package.id, %{status: "dispatched"})

    assert {:error, :work_package_terminal} =
             AgentRunRepository.start_run(repo, %{work_package_id: linked_package.id, status: "starting"})

    assert {:error, :work_package_terminal} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:error, :work_package_terminal} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:delivery-residue",
                 "actor_display_name" => "delivery-residue"
               },
               stale_after_ms: 60_000
             )
  end

  test "PR merged recovery closeout merges stale linked package and retires worker grant", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "dispatched")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "stale-worker")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-stale-worker",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/124",
        pr_number: 124,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:30:00.000000Z],
        merge_commit_sha: "abc124"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"

    assert repo.get!(WorkPackage, linked_package.id).status == "ended"
    assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)

    assert [event] = repo.all(ProgressEvent)
    assert event.status == "ended"
    assert event.payload["previous_status"] == "dispatched"
    assert event.payload["retired_worker_grant_ids"] == [minted.grant.id]
    assert "worker_grant_active" in event.payload["runtime_reason_codes_before_closeout"]

    assert {:ok, %{counts: %{"delivered" => 1}, work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "delivered"
    assert slice.work_package.raw_status == "ended"
  end

  test "PR merged recovery closeout ignores stale agent runtime rows that are not operationally active", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready")

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    assert {:ok, %{work_packages: [before_closeout]}} = DeliveryBoard.project(repo, work_request.id)
    assert before_closeout.operational_state.key == "merge_ready"
    assert before_closeout.work_package.runtime_state.active? == false
    assert before_closeout.work_package.runtime_state.stale? == true
    assert before_closeout.work_package.runtime_state.stale_agent_run_ids == [agent_run.id]
    assert "agent_run_stale" in before_closeout.work_package.runtime_state.reason_codes

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-stale-agent-runtime",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/131",
        pr_number: 131,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:57:00.000000Z],
        merge_commit_sha: "abc131"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "ended"

    assert [event] = repo.all(ProgressEvent)
    assert "agent_run_stale" in event.payload["runtime_reason_codes_before_closeout"]
    assert event.payload["ignored_stale_agent_run_ids"] == [agent_run.id]

    assert {:ok, %{counts: %{"delivered" => 1}, work_packages: [after_closeout]}} = DeliveryBoard.project(repo, work_request.id)
    assert after_closeout.operational_state.key == "delivered"
    refute "work_package_active_after_delivery" in after_closeout.attention_reason_codes
  end

  test "PR merged recovery closeout releases the current claim lease", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "dispatched")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:pr-recovery", "actor_display_name" => "current-worker"},
               stale_after_ms: 60_000
             )

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-current-claim-lease",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/130",
        pr_number: 130,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:56:00.000000Z],
        merge_commit_sha: "abc130"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "ended"

    assert %ClaimLease{status: "released", release_reason: "pr_merged_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  test "abandoned closeout retires current worker authority on an already-abandoned package", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-DELIVERY-ABANDONED-CURRENT-RUNTIME",
        status: "dispatched"
      )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "current-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:current-worker",
                 "actor_display_name" => "current-worker"
               },
               access_grant_id: minted.grant.id,
               stale_after_ms: 60_000
             )

    assert {:ok, _runtime_cleanup_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Prior cleanup evidence exists, but current authority remains.",
               status: "cleaned",
               idempotency_key: "abandoned-current-runtime-cleanup-evidence",
               payload: %{
                 "source_tool" => "cleanup_work_request_work_package_runtime",
                 "delivery_evidence" => %{"outcome" => "abandoned"}
               }
             })

    assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

    attrs =
      delivery_attrs(%{
        outcome: "abandoned",
        idempotency_key: "delivery-abandoned-current-runtime",
        abandoned_rationale: "The architect is retiring the remaining worker authority."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "abandoned"
    assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)

    assert %ClaimLease{status: "released", release_reason: "abandoned_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  test "a replayed closeout returns the recorded delivery and keeps the request complete", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-legacy-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/790",
        pr_number: 790,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 14:30:00.000000Z],
        merge_commit_sha: "legacy-790"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert repo.get!(WorkPackage, linked_package.id).status == "ended"

    assert {:ok, replay} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert replay.id == delivery.id
    assert {:ok, %{phase: "done"}} = Phase.load_one(repo, repo.get!(WorkRequest, work_request.id))
  end

  test "colliding closeout progress does not bypass validation or terminal mutation", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready")
    delivery_idempotency_key = "delivery-progress-collision"

    assert {:ok, _colliding_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Manual event with a colliding closeout key",
               status: "merged",
               idempotency_key: "work_request_delivery_closeout:#{work_request.id}:#{work_package.id}:#{delivery_idempotency_key}",
               payload: %{
                 type: "manual",
                 source_tool: "operator_note",
                 work_request_id: work_request.id,
                 work_package_id: work_package.id,
                 delivery_id: "not-this-delivery",
                 outcome: "pr_merged",
                 next_status: "merged"
               }
             })

    assert {:error, :idempotency_key_conflict} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: delivery_idempotency_key,
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/999",
                 pr_number: 999,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 15:00:00.000000Z],
                 merge_commit_sha: "fed999"
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.aggregate(ProgressEvent, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "ready"
  end

  test "investigation no-PR closeout releases stale claim leases and closes the linked package", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-INVESTIGATION-NO-PR",
        work_package_id: "wp_o3kgjdl7gausbmqi",
        kind: "investigation",
        status: "ready"
      )

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-investigation", "actor_display_name" => "stale-worker"},
               stale_after_ms: 1
             )

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)
    repo.update!(Ecto.Changeset.change(claim_lease, last_seen_at: stale_at, updated_at: stale_at))

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-investigation-no-pr-stale-lease",
        no_pr_evidence: "Investigation completed without a PR."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "ended"

    assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)

    closeout_event = Enum.find(repo.all(ProgressEvent), &(&1.payload["type"] == "work_request_delivery_closeout"))
    assert closeout_event.payload["retired_claim_lease_ids"] == [claim_lease.id]
    assert "claim_lease_stale" in closeout_event.payload["runtime_reason_codes_before_closeout"]
  end

  test "stale agent runs do not block normal closeout and remain audited", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-STALE-AGENT-RUN",
        status: "ready"
      )

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-stale-agent-run",
        no_pr_evidence: "The only runtime evidence is stale."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "completed_no_pr"

    assert [event] = repo.all(ProgressEvent)
    assert event.payload["previous_status"] == "ready"
    assert "agent_run_stale" in event.payload["runtime_reason_codes_before_closeout"]
    assert event.payload["ignored_stale_agent_run_ids"] == [agent_run.id]
  end

  defp linked_slice!(repo, overrides) do
    kind = Keyword.get(overrides, :kind, "mcp")
    status = Keyword.get(overrides, :status, "dispatched")
    request_id = Keyword.get_lazy(overrides, :work_request_id, fn -> "WR-DELIVERY-#{System.unique_integer([:positive])}" end)

    work_request = create_work_request!(repo, id: request_id)
    work_package_id = Keyword.get(overrides, :work_package_id, "WP-#{request_id}")
    work_package = create_work_package!(repo, work_request, id: work_package_id, kind: kind)

    work_package =
      repo.update!(
        Ecto.Changeset.change(work_package,
          status: status,
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

    {work_request, work_package, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    attrs = work_package_attrs(overrides)
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, attrs)
    work_package
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Close delivered WorkRequest slices",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record closeout truth for delivered slices.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Close delivered slice",
      goal: "Record terminal delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-closeout",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery closeout is transactional."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_closeout_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not bypass delivery semantics."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-closeout-test"
    }

    Enum.into(overrides, defaults)
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-request-delivery-closeout-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
