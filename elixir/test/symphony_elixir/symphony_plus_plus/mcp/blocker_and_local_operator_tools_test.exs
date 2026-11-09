Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerAndLocalOperatorToolsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard

  test "set_blocker declares, updates and clears a blocker on a package the caller owns", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-SET-BLOCKER", repo: "nextide/symphony-plus-plus", base_branch: "main")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-SET-BLOCKER", base_branch: work_request.base_branch)
             )

    work_package = repo.update!(Ecto.Changeset.change(work_package, status: "dispatched"))
    set = fn terminal, arguments -> mcp_tool(repo, terminal, "set_blocker", Map.put(arguments, "work_package_id", work_package.id)) end
    active_blockers = fn -> Enum.filter(Dashboard.OperationalProjection.blockers(progress_events!(repo, work_package.id)), & &1.active) end

    declared = set.("t1", %{"blocker_id" => "needs-key", "active" => true, "summary" => "Waiting for the staging key"})
    assert %{"blocker" => %{"id" => "needs-key", "active" => true, "summary" => "Waiting for the staging key"}, "changed" => true} = get_in(declared, ["result", "structuredContent"])
    assert [%{id: "needs-key"}] = active_blockers.()

    # Setting the state it already has changes nothing.
    again = set.("t1", %{"blocker_id" => "needs-key", "active" => true, "summary" => "Waiting for the staging key"})
    assert get_in(again, ["result", "structuredContent", "changed"]) == false

    updated = set.("t1", %{"blocker_id" => "needs-key", "active" => true, "summary" => "Waiting for the production key"})
    assert get_in(updated, ["result", "structuredContent", "changed"]) == true
    assert [%{summary: "Waiting for the production key"}] = active_blockers.()

    missing_summary = set.("t1", %{"blocker_id" => "other", "active" => true})
    assert get_in(missing_summary, ["error", "data", "reason"]) == "missing_summary"

    # Another terminal does not own the WorkRequest.
    foreign = set.("t2", %{"blocker_id" => "needs-key", "active" => false})
    assert get_in(foreign, ["error", "data", "reason"]) == "owned_by_other_terminal"
    assert [_still_active] = active_blockers.()

    cleared = set.("t1", %{"blocker_id" => "needs-key", "active" => false})
    assert get_in(cleared, ["result", "structuredContent", "blocker", "active"]) == false
    assert active_blockers.() == []
    event = repo.get_by!(ProgressEvent, work_package_id: work_package.id, status: "resolved")
    assert {event.actor_id, event.actor_type} == {"testbox/t1", "architect"}

    assert get_in(set.("t1", %{"blocker_id" => "needs-key", "active" => false}), ["result", "structuredContent", "changed"]) == false
    unknown = set.("t1", %{"blocker_id" => "never-declared", "active" => false})
    assert get_in(unknown, ["error", "data", "reason"]) == "blocker_not_found"

    assert get_in(set.("t1", %{"blocker_id" => "needs-key"}), ["error", "data", "reason"]) =~ "active"
  end

  test "ending a package clears its blockers and withdraws its asks; neither can be set on it afterwards", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-END-CLEARS", repo: "nextide/symphony-plus-plus", base_branch: "main")

    assert {:ok, ending} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_request_work_package_attrs(id: "WRS-MCP-END-CLEARS", base_branch: work_request.base_branch))

    assert {:ok, sibling} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_request_work_package_attrs(id: "WRS-MCP-END-SIBLING", base_branch: work_request.base_branch))

    ending = repo.update!(Ecto.Changeset.change(ending, status: "dispatched"))

    refute mcp_tool(repo, "t1", "set_blocker", %{"work_package_id" => ending.id, "blocker_id" => "b1", "active" => true, "summary" => "Blocked"})["error"]
    package_ask = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "work_package_id" => ending.id, "question" => "Keep this package?"})
    package_ask_id = get_in(package_ask, ["result", "structuredContent", "ask", "id"])
    sibling_ask = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "work_package_id" => sibling.id, "question" => "And this one?"})
    sibling_ask_id = get_in(sibling_ask, ["result", "structuredContent", "ask", "id"])

    assert {:ok, _delivery} =
             CanonicalWorkPackageFixtures.end_work_package(repo, work_request.id, ending.id, %{outcome: "abandoned", abandoned_rationale: "Rehomed."})

    refute Enum.any?(Dashboard.OperationalProjection.blockers(progress_events!(repo, ending.id)), & &1.active)
    assert %{state: "withdrawn", answered_by: "subject_ended"} = repo.get!(SymphonyElixir.SymphonyPlusPlus.Asks.Ask, package_ask_id)
    assert %{state: "open"} = repo.get!(SymphonyElixir.SymphonyPlusPlus.Asks.Ask, sibling_ask_id)

    refused_blocker = mcp_tool(repo, "t1", "set_blocker", %{"work_package_id" => ending.id, "blocker_id" => "b2", "active" => true, "summary" => "Late"})
    assert get_in(refused_blocker, ["error", "data"]) |> Map.take(["reason", "state"]) == %{"reason" => "work_package_ended", "state" => "ended"}

    refused_ask = mcp_tool(repo, "t3", "ask", %{"work_request_id" => work_request.id, "work_package_id" => ending.id, "question" => "Too late?"})
    assert get_in(refused_ask, ["error", "data", "reason"]) == "work_package_ended"
  end

  defp progress_events!(repo, work_package_id) do
    assert {:ok, events} = PlanningRepository.list_progress_events(repo, work_package_id)
    events
  end

  test "HTTP WorkRequest reads require a trusted local connection with explicit state", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-READ-DENIED")
    arguments = %{"work_request_id" => work_request.id}

    implicit_state_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "implicit-state-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)
      )

    assert get_in(implicit_state_response, ["error", "code"]) == -32_001
    assert get_in(implicit_state_response, ["error", "data", "reason"]) == "local_mcp_session_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_localreadsecret"}

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => Map.put(arguments, "view", "board")}
        },
        local_mcp_server(remote_config, "remote-work-request-read-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_localreadsecret"

    remote_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-work-request-list-denied",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        local_mcp_server(remote_config, "remote-work-request-list-state")
      )

    assert get_in(remote_list_response, ["error", "code"]) == -32_001
    assert get_in(remote_list_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_list_response) =~ "ghp_localreadsecret"
  end
end
