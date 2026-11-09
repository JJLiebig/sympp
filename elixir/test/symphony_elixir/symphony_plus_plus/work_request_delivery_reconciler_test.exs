defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryReconcilerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    for schema <- [
          ProgressEvent,
          WorkPackageDelivery,
          WorkPackage,
          DecisionLogEntry,
          AgentRun,
          WorkPackage,
          WorkRequest,
          Phase
        ] do
      repo.delete_all(schema)
    end

    :ok
  end

  test "apply leaves active blockers unchanged when delivery recording fails", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-BLOCKER-DELIVERY-FAILS",
        work_package_id: "WP-RECONCILE-BLOCKER-DELIVERY-FAILS",
        status: "ready"
      )

    append_merged_pr_evidence!(repo, linked_package, 919, "head-919")
    append_active_blocker!(repo, linked_package.id, "delivery-failure-blocker")
    test_pid = self()

    record_delivery = fn callback_repo, callback_work_request_id, callback_work_package_id, attrs ->
      send(test_pid, {
        :record_delivery_called,
        callback_repo,
        callback_work_request_id,
        callback_work_package_id,
        attrs
      })

      {:error, :concurrent_closeout}
    end

    assert {:error, {:delivery_reconciliation_failed, "concurrent_closeout"}} =
             DeliveryReconciler.reconcile_work_package(repo, linked_package.id, record_work_package_delivery: record_delivery)

    assert_received {
      :record_delivery_called,
      ^repo,
      callback_work_request_id,
      callback_work_package_id,
      attrs
    }

    assert callback_work_request_id == work_request.id
    assert callback_work_package_id == work_package.id
    assert attrs.outcome == "pr_merged"

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert WorkPackageActivity.context(repo, linked_package.id).blocker_state.active?
  end

  test "historical sync PR evidence can use merge reconciliation strong fields", %{repo: repo} do
    {_work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-HISTORICAL-MERGE",
        work_package_id: "WP-RECONCILE-HISTORICAL-MERGE",
        status: "ready"
      )

    append_legacy_merged_pr_evidence!(repo, linked_package, 906, "head-906")

    assert {:ok, %{status: "applied", reason: "github_pr_merged", applied_count: 1}} = DeliveryReconciler.reconcile_work_package(repo, linked_package.id)

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert DateTime.compare(delivery.pr_merged_at, ~U[2026-05-24 12:00:00Z]) == :eq
    assert delivery.merge_commit_sha == "merge-sha-906"
  end

  test "repaired sync PR evidence can drive merged delivery reconciliation", %{repo: repo} do
    {_work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-REPAIRED-SYNC-MERGE",
        work_package_id: "WP-RECONCILE-REPAIRED-SYNC-MERGE",
        status: "ready"
      )

    append_repaired_merged_pr_evidence!(repo, linked_package, 907, "head-907")

    assert {:ok, %{status: "applied", reason: "github_pr_merged", applied_count: 1}} = DeliveryReconciler.reconcile_work_package(repo, linked_package.id)
    assert repo.get_by!(WorkPackageDelivery, work_package_id: linked_package.id).merge_commit_sha == "merge-sha-907"
  end

  test "later sync for a replaced PR does not become the active closeout PR", %{repo: repo} do
    {_work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-REPLACED-PR",
        work_package_id: "WP-RECONCILE-REPLACED-PR",
        status: "ready"
      )

    append_replaced_pr_evidence!(repo, linked_package)

    assert {:ok, %{applied_count: 0, status: "skipped", reason: "no_structured_pr_merge_evidence"}} =
             DeliveryReconciler.reconcile_work_package(repo, linked_package.id)

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready"
  end

  test "decision-log prose does not infer no-PR completion", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-NO-PR-PROSE",
        work_package_id: "WP-RECONCILE-NO-PR-PROSE",
        status: "dispatched"
      )

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(repo, work_request.id, %{
               source_type: "architect",
               created_by: "architect-1",
               decision: "Slice completed without PR.",
               rationale: "Operator prose only.",
               scope_impact: "Advisory note."
             })

    assert {:ok, %{applied_count: 0, status: "skipped", reason: "no_structured_pr_merge_evidence"}} =
             DeliveryReconciler.reconcile_work_package(repo, linked_package.id)

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "dispatched"
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_id = Keyword.fetch!(overrides, :work_package_id)
    status = Keyword.get(overrides, :status, "dispatched")
    work_request = create_work_request!(repo, id: request_id)
    work_package = create_work_package!(repo, work_request, id: "WRS-#{request_id}")

    assert {:ok, approved_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    work_package =
      create_matching_work_package!(
        repo,
        work_request,
        approved_slice,
        id: work_package_id,
        status: status
      )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               work_package.id
             )

    {work_request, dispatched_slice, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(overrides))
    work_package
  end

  defp create_matching_work_package!(repo, work_request, work_package, overrides) do
    attrs =
      [
        kind: work_package.kind,
        title: work_package.title,
        repo: work_request.repo,
        base_branch: work_package.base_branch,
        branch_pattern: work_package.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: work_package.allowed_file_globs,
        acceptance_criteria: work_package.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp append_merged_pr_evidence!(repo, work_package, number, attached_head_sha, opts \\ []) do
    synced_head_sha = Keyword.get(opts, :synced_head_sha, attached_head_sha)
    repository = Keyword.get(opts, :repository, "nextide/repo")
    url = Keyword.get(opts, :url, "https://github.com/#{repository}/pull/#{number}")
    base_branch = Keyword.get(opts, :base_branch, "main")
    merge_commit_sha = Keyword.get(opts, :merge_commit_sha, "merge-sha-#{number}")

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: attached_head_sha}
             })

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: base_branch
               }
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: synced_head_sha,
                 base_branch: base_branch,
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: merge_commit_sha,
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_legacy_merged_pr_evidence!(repo, work_package, number, attached_head_sha) do
    url = "https://github.com/nextide/repo/pull/#{number}"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: attached_head_sha}
             })

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: "main"
               }
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: "main",
                 merge_state: %{merged: true}
               }
             })

    assert {:ok, _reconciled} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "GitHub PR merge reconciled",
               status: "github_pr_merged",
               payload: %{
                 type: "github_pr_merge_reconciliation",
                 source_tool: "operator_sync_prs",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 merged: true,
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-#{number}"
               }
             })
  end

  defp append_repaired_merged_pr_evidence!(repo, work_package, number, head_sha) do
    url = "https://github.com/nextide/repo/pull/#{number}"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: head_sha}
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR repaired and merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 attachment_repair: true,
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: head_sha,
                 base_branch: "main",
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-#{number}",
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_replaced_pr_evidence!(repo, work_package) do
    old_url = "https://github.com/nextide/repo/pull/100"
    new_url = "https://github.com/nextide/repo/pull/101"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "new-head"}
             })

    assert {:ok, _old_attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: old_url,
                 repository: "nextide/repo",
                 number: 100,
                 head_sha: "old-head",
                 base_branch: "main"
               }
             })

    assert {:ok, _new_attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Replacement PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: new_url,
                 repository: "nextide/repo",
                 number: 101,
                 head_sha: "new-head",
                 base_branch: "main"
               }
             })

    assert {:ok, _old_synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old PR merged after replacement",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: old_url,
                 repository: "nextide/repo",
                 number: 100,
                 head_sha: "old-head",
                 base_branch: "main",
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-100",
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_active_blocker!(repo, work_package_id, blocker_id, opts \\ []) do
    assert {:ok, event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Review scope blocker",
               status: "blocked",
               idempotency_key: Keyword.get(opts, :idempotency_key, blocker_id),
               payload: %{
                 type: "blocker",
                 source_tool: "set_blocker",
                 blocker_id: blocker_id,
                 active: true
               }
             })

    event
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-RECONCILE-#{System.unique_integer([:positive])}",
      title: "Reconcile delivered WorkRequest slices",
      repo: "nextide/repo",
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
      title: "Reconcile delivered slice",
      goal: "Record terminal delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-reconciler",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery reconciler is deterministic."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_reconciler_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not infer no-PR completion from prose."]
    }

    Enum.into(overrides, defaults)
  end
end
