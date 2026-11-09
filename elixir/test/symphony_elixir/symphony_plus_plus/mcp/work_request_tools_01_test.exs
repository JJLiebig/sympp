Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "WorkRequest creation rejects implicit state and non-file-backed trusted configurations", %{repo: repo} do
    arguments = %{
      "repo" => "nextide/symphony-plus-plus",
      "base_branch" => "main",
      "title" => "Denied WorkRequest",
      "description" => "This should not be created outside trusted local HTTP.",
      "work_type" => "investigation"
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
    assert get_in(implicit_state_response, ["error", "data", "code"]) == "local_mcp_session_required"

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
    assert get_in(remote_response, ["error", "data", "code"]) == "local_database_required"
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
    assert get_in(memory_response, ["error", "data", "code"]) == "file_backed_database_required"
  end
end
