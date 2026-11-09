Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.FailedCallDiagnosticsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{FailedCall, HTTPTransport}

  defmodule DiagnosticFailureRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    defdelegate insert_all(schema, rows, opts), to: Repo

    def get(_schema, _id) do
      case Process.get({__MODULE__, :failure}) do
        :exit -> exit(:repository_secret_exit)
        _raise -> raise "repository secret exception C:/private/provider-body"
      end
    end
  end

  defmodule CountingFailureRepo do
    def insert_all(_schema, _rows, _opts), do: raise("ledger locked")
  end

  setup %{repo: repo} do
    repo.delete_all(FailedCall.Count)
    :ok
  end

  test "a raised or exited tool call is counted once and still raises", %{repo: repo} do
    on_exit(fn -> Process.delete({DiagnosticFailureRepo, :failure}) end)
    server = Server.new(%{local_mcp_config(DiagnosticFailureRepo) | database: "C:/trusted/ledger.db"}, initialized: true, state_key: "failure-test")
    request = tool_call("read_work_request", %{"work_request_id" => "private-value"})

    Process.put({DiagnosticFailureRepo, :failure}, :raise)

    capture_log(fn ->
      assert_raise RuntimeError, "repository secret exception C:/private/provider-body", fn -> Server.handle(request, server) end
    end)

    Process.put({DiagnosticFailureRepo, :failure}, :exit)
    capture_log(fn -> assert catch_exit(Server.handle(request, server)) == :repository_secret_exit end)

    assert [%{tool: "read_work_request", reason: "unhandled_tool_failure", layer: "tool", count: 2}] = repo.all(FailedCall.Count)
  end

  test "a failure crossing the bridge and tool layers counts once", %{repo: repo} do
    config = local_mcp_config(repo)
    client_key = "failed-call-layers"
    assert {:ok, initialized} = HTTPTransport.handle(config, initialize_request(), client_key: client_key)

    assert {:ok, failed} =
             Task.async(fn -> HTTPTransport.handle(config, failed_health_request("x"), client_key: client_key, state_key: initialized.state_key) end)
             |> Task.await()

    assert failed.response["error"]["data"]["code"] == "invalid_tool_arguments"
    assert [%{layer: "tool", count: 1}] = repo.all(FailedCall.Count)
  end

  test "counting failures never change the protocol response" do
    server = Server.new(Config.default(repo: CountingFailureRepo), initialized: true)
    response = Server.handle(failed_health_request("x"), server)

    assert response["error"]["code"] == -32_602
    assert response["error"]["data"]["code"] == "invalid_tool_arguments"
  end

  defp failed_health_request(secret) do
    %{
      "jsonrpc" => "2.0",
      "id" => "failed-health",
      "method" => "tools/call",
      "params" => %{"name" => "sympp.health", "arguments" => %{"bearer" => secret}}
    }
  end

  defp tool_call(name, arguments) do
    %{"jsonrpc" => "2.0", "id" => "failed-call-test", "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "failed-call-init",
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-03-26", "clientInfo" => %{"name" => "failed-call-test", "version" => "1"}, "capabilities" => %{}}
    }
  end
end
