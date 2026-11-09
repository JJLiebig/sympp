Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerAndLocalOperatorToolsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

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
    assert get_in(implicit_state_response, ["error", "data", "code"]) == "local_mcp_session_required"

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
    assert get_in(remote_response, ["error", "data", "code"]) == "local_database_required"
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
    assert get_in(remote_list_response, ["error", "data", "code"]) == "local_database_required"
    refute inspect(remote_list_response) =~ "ghp_localreadsecret"
  end
end
