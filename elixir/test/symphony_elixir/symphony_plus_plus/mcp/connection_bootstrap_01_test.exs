Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ConnectionBootstrap01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "health redacts credential-bearing ledger identity values", %{repo: repo} do
    sqlite_secret = "sqlite_password_that_must_not_echo"
    sqlite_uri = sqlite_file_uri(current_main_database_path(repo), "password=#{sqlite_secret}&cache=shared")

    sqlite_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sqlite-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo, database: sqlite_uri)
      )

    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "identity", "kind"]) == "sqlite"
    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "identity", "source"]) == "explicit"
    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "reachable"]) == true
    refute inspect(sqlite_response) =~ sqlite_secret
    refute inspect(sqlite_response) =~ "password="

    remote_secret = "remote_secret_that_must_not_echo"
    remote_database = "https://worker:#{remote_secret}@ledger-prod.example.test:9443/mcp?token=#{remote_secret}"

    remote_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo, database: remote_database)
      )

    assert get_in(remote_response, ["result", "structuredContent", "ledger", "reachable"]) == false

    assert get_in(remote_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "https://ledger-prod.example.test:9443"
           }

    refute inspect(remote_response) =~ remote_secret
    refute inspect(remote_response) =~ "worker:"
    refute inspect(remote_response) =~ "token="

    dsn_secret = "dsn_password_that_must_not_echo"
    dsn_database = "Server=tcp:ledger-dsn.example.test,1433;Database=sympp;Password=#{dsn_secret}"

    dsn_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "dsn-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo, database: dsn_database)
      )

    assert get_in(dsn_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "server://ledger-dsn.example.test:1433"
           }

    refute inspect(dsn_response) =~ dsn_secret
    refute inspect(dsn_response) =~ "Password="
    refute inspect(dsn_response) =~ "Server="
  end
end
