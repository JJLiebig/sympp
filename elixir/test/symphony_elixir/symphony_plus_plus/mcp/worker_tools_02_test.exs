Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "package evidence records the writing terminal and archived requests refuse writes", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-ARCH-DESCENDANT-PLANNING",
        status: "sliced",
        repo_scopes: [%{repo: "nextide/secondary-service", base_branch: "release"}]
      )

    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               WorkPackageFactory.attrs(
                 id: "WP-ARCH-DESCENDANT-PLANNING",
                 repo: "nextide/secondary-service",
                 base_branch: "release",
                 status: "dispatched"
               )
             )

    assert {:ok, existing} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Inspect descendant"
             })

    read_response = mcp_tool(repo, nil, "read_task_plan", %{"work_package_id" => package.id})
    version = get_in(read_response, ["result", "structuredContent", "version"])
    assert is_integer(version)

    finding_response =
      mcp_tool(repo, "t1", "append_finding", %{
        "work_package_id" => package.id,
        "title" => "Secondary repository confirmed",
        "body" => "The descendant remains inside the owned WorkRequest.",
        "idempotency_key" => "architect-descendant-finding"
      })

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) ==
             "Secondary repository confirmed"

    progress_response =
      mcp_tool(repo, "t1", "append_progress", %{
        "work_package_id" => package.id,
        "summary" => "Descendant plan supervised",
        "idempotency_key" => "architect-descendant-progress"
      })

    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "status"]) == "recorded"

    assert {:ok, [_finding]} = PlanningRepository.list_findings(repo, package.id)
    assert {:ok, [progress]} = PlanningRepository.list_progress_events(repo, package.id)
    assert {progress.actor_type, progress.actor_id} == {"architect", "testbox/t1"}

    work_request
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:microsecond), archive_reason: "manual")
    |> repo.update!()

    archived =
      mcp_tool(repo, "t1", "update_task_plan", %{
        "work_package_id" => package.id,
        "expected_version" => version,
        "nodes" => [%{"id" => existing.id, "status" => "done"}]
      })

    assert get_in(archived, ["error", "data", "reason"]) == "work_request_archived"
    assert get_in(archived, ["error", "data", "next_action"]) == "restore"
  end
end
