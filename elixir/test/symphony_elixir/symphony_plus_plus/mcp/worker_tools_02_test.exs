Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "a blocker on a secondary-repo package records the writing terminal, and archived requests refuse it", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-ARCH-DESCENDANT-PLANNING",
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

    assert {:ok, _node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Inspect descendant"
             })

    read_response = mcp_tool(repo, nil, "read_work_request", %{"work_request_id" => work_request.id, "view" => "package", "work_package_id" => package.id})
    assert [%{"title" => "Inspect descendant"}] = get_in(read_response, ["result", "structuredContent", "task_plan", "steps"])

    blocker_response =
      mcp_tool(repo, "t1", "set_blocker", %{
        "work_package_id" => package.id,
        "blocker_id" => "secondary-access",
        "active" => true,
        "summary" => "Waiting for access to the secondary repository"
      })

    assert get_in(blocker_response, ["result", "structuredContent", "blocker", "active"]) == true
    assert {:ok, [event]} = PlanningRepository.list_progress_events(repo, package.id)
    assert {event.actor_type, event.actor_id} == {"architect", "testbox/t1"}

    work_request
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:microsecond), archive_reason: "manual")
    |> repo.update!()

    archived = mcp_tool(repo, "t1", "set_blocker", %{"work_package_id" => package.id, "blocker_id" => "secondary-access", "active" => false})

    assert get_in(archived, ["error", "data", "reason"]) == "work_request_archived"
    assert get_in(archived, ["error", "data", "recovery", "next_action"]) == "restore"
  end
end
