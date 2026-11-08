Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerAndLocalOperatorToolsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "architect resolve_blocker clears explicit and default-scope descendant blockers", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-ARCH-PACKAGE-SURFACES",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-ARCH-PACKAGE-SURFACES", base_branch: work_request.base_branch)
             )

    work_package = repo.update!(Ecto.Changeset.change(work_package, status: "dispatched"))

    {_handoff_anchor, handoff_session, _handoff_grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    assert {:ok, _blocker_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, handoff_session.assignment, work_package.id, %{
               "summary" => "Waiting for architect",
               "idempotency_key" => "arch-policy-blocker",
               "payload" => %{
                 "type" => "blocker",
                 "source_tool" => "report_blocker",
                 "blocker_id" => "arch-policy-blocker",
                 "active" => true
               }
             })

    resolve_blocker_response =
      mcp_tool(repo, handoff_session, "resolve_blocker", %{
        "work_package_id" => work_package.id,
        "blocker_id" => "arch-policy-blocker",
        "resolution" => "Architect supplied the missing decision.",
        "summary" => "Cleared architect blocker",
        "idempotency_key" => "arch-policy-blocker-resolved"
      })

    resolve_event_id = get_in(resolve_blocker_response, ["result", "structuredContent", "progress_event", "id"])
    refute Map.has_key?(get_in(resolve_blocker_response, ["result", "structuredContent", "progress_event"]), "payload")
    assert repo.get!(ProgressEvent, resolve_event_id).payload["active"] == false
    assert repo.get!(WorkPackage, work_package.id).status == "dispatched"

    anchor_blocker_id = "arch-policy-anchor-blocker"

    assert {:ok, _anchor_blocker_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               handoff_session.assignment,
               handoff_session.assignment.work_package_id,
               %{
                 "summary" => "Waiting for anchor decision",
                 "idempotency_key" => anchor_blocker_id,
                 "payload" => %{
                   "type" => "blocker",
                   "source_tool" => "report_blocker",
                   "blocker_id" => anchor_blocker_id,
                   "active" => true
                 }
               }
             )

    default_scope_response =
      mcp_tool(repo, handoff_session, "resolve_blocker", %{
        "blocker_id" => anchor_blocker_id,
        "resolution" => "Architect supplied the anchor decision.",
        "summary" => "Cleared anchor blocker",
        "idempotency_key" => "arch-policy-anchor-blocker-resolved"
      })

    assert get_in(default_scope_response, ["result", "structuredContent", "progress_event", "idempotency_key"]) ==
             ["resolve_blocker", handoff_session.assignment.work_package_id, "arch-policy-anchor-blocker-resolved"] |> Enum.join(":")

    default_scope_event_id = get_in(default_scope_response, ["result", "structuredContent", "progress_event", "id"])
    refute Map.has_key?(get_in(default_scope_response, ["result", "structuredContent", "progress_event"]), "payload")
    assert repo.get!(ProgressEvent, default_scope_event_id).payload["active"] == false
  end

  test "unclaimed WorkRequest reads require trusted local HTTP with explicit state", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-READ-DENIED")
    arguments = %{"work_request_id" => work_request.id}

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    stdio_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-work-request-list-denied",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_list_response, ["error", "code"]) == -32_001
    assert get_in(stdio_list_response, ["error", "data", "reason"]) == "local_mcp_required"

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
          "params" => %{"name" => "read_delivery_board", "arguments" => arguments}
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

  test "local operator decision tool rejects nonlocal and remote database modes", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-NOTES-DENIED")

    arguments = %{
      "work_request_id" => work_request.id,
      "decision" => "Keep the safe default",
      "rationale" => "Operator note",
      "scope_impact" => "None",
      "created_by" => "operator"
    }

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "record_work_request_operator_decision", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_remoteoperatorsecret"}

    implicit_state_tools =
      local_mcp_config(repo)
      |> Server.new(initialized: true, local_daemon_trusted: true)
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    remote_tools =
      remote_config
      |> local_mcp_server("remote-local-operator-list-state")
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(implicit_state_tools, "record_work_request_operator_decision")
    assert Map.has_key?(remote_tools, "record_work_request_operator_decision")

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "record_work_request_operator_decision", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-local-operator-denied-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_remoteoperatorsecret"

    memory_configs = [
      %{local_mcp_config(repo) | database: ":memory:"},
      %{local_mcp_config(repo) | database: "file:sympp_local_operator_notes?mode=memory&cache=shared"}
    ]

    Enum.with_index(memory_configs, fn memory_config, index ->
      memory_tools =
        memory_config
        |> local_mcp_server("memory-local-operator-list-state-#{index}")
        |> tools_for_server()
        |> Map.new(&{&1["name"], &1})

      assert Map.has_key?(memory_tools, "record_work_request_operator_decision")

      memory_response =
        Server.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => "memory-local-operator-denied-#{index}",
            "method" => "tools/call",
            "params" => %{"name" => "record_work_request_operator_decision", "arguments" => arguments}
          },
          local_mcp_server(memory_config, "memory-local-operator-denied-state-#{index}")
        )

      assert get_in(memory_response, ["error", "code"]) == -32_001
      assert get_in(memory_response, ["error", "data", "reason"]) == "file_backed_database_required"
    end)
  end
end
