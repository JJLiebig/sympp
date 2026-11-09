Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  test "WorkRequest creation rejects implicit state and non-file-backed trusted configurations", %{repo: repo} do
    arguments = %{
      "repo" => "nextide/symphony-plus-plus",
      "base_branch" => "main",
      "title" => "Denied WorkRequest",
      "description" => "This should not be created outside trusted local HTTP.",
      "request_kind" => "investigation"
    }

    implicit_state_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "implicit-state-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)
      )

    assert get_in(implicit_state_response, ["error", "code"]) == -32_001
    assert get_in(implicit_state_response, ["error", "data", "reason"]) == "local_mcp_session_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_createworksecret"}

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-create-work-request-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_createworksecret"

    memory_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "memory-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        local_mcp_server(%{local_mcp_config(repo) | database: ":memory:"}, "memory-create-work-request-state")
      )

    assert get_in(memory_response, ["error", "code"]) == -32_001
    assert get_in(memory_response, ["error", "data", "reason"]) == "file_backed_database_required"
  end

  test "WorkRequest read tools list every WorkRequest, redact output and never write", %{repo: repo} do
    in_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-IN",
        title: "Read WorkRequests",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        human_description: "Use Bearer raw-secret-value for validation",
        constraints: %{"safe" => "visible", "token" => "raw-secret-value"}
      )

    _other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-REPO",
        repo: "nextide/other",
        base_branch: "symphony-plus-plus/beta"
      )

    _other_phase =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-PHASE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      )

    base = ~U[2026-11-01 10:00:00.000000Z]
    insert_ask!(repo, in_scope.id, id: "ask-mcp-wr-open", inserted_at: base, updated_at: base)

    insert_ask!(repo, in_scope.id,
      id: "ask-mcp-wr-answered",
      state: "answered",
      answer: "Bearer raw-secret-value",
      answered_by: "operator",
      inserted_at: DateTime.add(base, 2),
      updated_at: DateTime.add(base, 2)
    )

    insert_ask!(repo, in_scope.id, id: "ask-mcp-wr-withdrawn", state: "withdrawn", inserted_at: DateTime.add(base, 1), updated_at: DateTime.add(base, 1))

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(
               repo,
               in_scope.id,
               work_request_decision_attrs(id: "WRD-MCP-WR-1", decision: "Use https://example.test/path?sig=raw-secret-value")
             )

    assert {:ok, _planned} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_request_work_package_attrs(id: "WRS-MCP-WR-PLANNED"))
    assert {:ok, approved} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_request_work_package_attrs(id: "WRS-MCP-WR-APPROVED"))
    assert {:ok, skipped} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_request_work_package_attrs(id: "WRS-MCP-WR-SKIPPED"))
    repo.update!(Ecto.Changeset.change(approved, status: "approved"))
    assert {:ok, _skipped} = CanonicalWorkPackageFixtures.end_work_package(repo, in_scope.id, skipped.id, %{outcome: "skipped"})

    counts_before = {
      repo.aggregate(WorkRequest, :count),
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(WorkedOn, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    list_response = mcp_tool(repo, nil, "list_work_requests", %{"phase" => "planned"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["filters"] == %{"phase" => "planned"}
    assert list_payload["total_count"] == 1

    assert [
             %{
               "id" => "WR-MCP-WR-IN",
               "title" => "Read WorkRequests",
               "repo" => "nextide/symphony-plus-plus",
               "base_branch" => "symphony-plus-plus/beta",
               "phase" => "planned"
             } = listed_work_request
           ] = list_payload["work_requests"]

    assert listed_work_request["open_asks"] == 1
    refute Map.has_key?(listed_work_request, "decision_count")
    refute Map.has_key?(listed_work_request, "work_package_count")

    read_response = mcp_tool(repo, nil, "read_work_request", %{"detail" => "full", "work_request_id" => in_scope.id})
    read_payload = get_in(read_response, ["result", "structuredContent"])

    assert read_payload["work_request"]["id"] == in_scope.id
    assert read_payload["work_request"]["constraints"]["safe"] == "visible"
    assert read_payload["work_request"]["constraints"]["token"] == "[REDACTED]"
    # Open asks first, then newest first.
    assert Enum.map(read_payload["asks"], & &1["id"]) == ["ask-mcp-wr-open", "ask-mcp-wr-answered", "ask-mcp-wr-withdrawn"]
    assert Enum.at(read_payload["asks"], 1)["answer"] == "[REDACTED]"
    assert Enum.map(read_payload["decision_log_entries"], & &1["id"]) == ["WRD-MCP-WR-1"]
    assert Enum.at(read_payload["decision_log_entries"], 0)["decision"] =~ "[REDACTED]"

    assert Enum.map(read_payload["work_packages"], & &1["id"]) == [
             "WRS-MCP-WR-PLANNED",
             "WRS-MCP-WR-APPROVED",
             "WRS-MCP-WR-SKIPPED"
           ]

    assert Enum.at(read_payload["work_packages"], 0)["review"] == nil

    assert read_payload["summary"] == %{
             "open_ask_count" => 1,
             "decision_count" => 1,
             "work_package_count" => 3,
             "planned_work_package_count" => 1,
             "dispatched_work_package_count" => 0,
             "ended_work_package_count" => 1
           }

    refute inspect(read_response) =~ "raw-secret-value"

    missing_response = mcp_tool(repo, nil, "read_work_request", %{"detail" => "full", "work_request_id" => "WR-MCP-WR-MISSING"})
    assert get_in(missing_response, ["error", "code"]) == -32_004
    assert get_in(missing_response, ["error", "data", "reason"]) == "not_found"

    assert {
             repo.aggregate(WorkRequest, :count),
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(WorkedOn, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "WorkRequest list rejects repository scope arguments and unknown statuses", %{repo: repo} do
    repo_argument_response = mcp_tool(repo, nil, "list_work_requests", %{"repo" => "nextide/other"})
    assert get_in(repo_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(repo_argument_response, ["error", "data", "arguments"]) == ["repo"]

    branch_argument_response = mcp_tool(repo, nil, "list_work_requests", %{"base_branch" => "other"})
    assert get_in(branch_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(branch_argument_response, ["error", "data", "arguments"]) == ["base_branch"]

    invalid_phase_response = mcp_tool(repo, nil, "list_work_requests", %{"phase" => "merged"})
    assert get_in(invalid_phase_response, ["error", "data", "reason"]) == "invalid_phase"
  end
end
