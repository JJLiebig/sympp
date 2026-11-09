defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryCloseoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
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
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
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
