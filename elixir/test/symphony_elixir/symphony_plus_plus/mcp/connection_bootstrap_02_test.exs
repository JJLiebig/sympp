Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ConnectionBootstrap02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog

  @repo_root Path.expand("../../../../../", __DIR__)
  @contract_path Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")

  test "published MCP contract identity matches the runtime" do
    contract = @contract_path |> File.read!() |> Jason.decode!()
    tool_sets = Map.fetch!(contract, "tool_sets")

    tools = ToolCatalog.tools()

    assert Map.keys(contract) |> Enum.sort() == ["mcp_contract_fingerprint", "tool_sets", "version"]
    assert Map.fetch!(contract, "version") == 8
    assert Map.fetch!(contract, "mcp_contract_fingerprint") == Server.mcp_contract_identity()["fingerprint"]

    assert tool_sets == %{
             "tools" => tools,
             "read_tools" => Enum.filter(tools, &(ToolCatalog.tool_access(&1) == :read)),
             "owner_gated_tools" => Enum.filter(tools, &ToolCatalog.owner_gated_call?(&1, %{}))
           }
  end

  test "mix task reuses an already-started repo for the exact SQLite URI" do
    database = "file:sympp_mcp_#{System.unique_integer([:positive])}?mode=memory&cache=shared"
    original_repo = Repo.get_dynamic_repo()
    original_logger_config = Application.fetch_env(:logger, :console)
    {:ok, pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)

    input =
      [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        })
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    try do
      output =
        capture_io(input, fn ->
          McpTask.run(["--database", database])
        end)

      responses = decode_json_lines(output)

      assert Enum.any?(responses, fn response ->
               get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
             end)

      assert Process.alive?(pid)
      assert Repo.get_dynamic_repo() == original_repo
      assert Application.fetch_env(:logger, :console) == original_logger_config
    after
      GenServer.stop(pid)
    end
  end

  test "tools list returns Codex-compatible top-level input schemas" do
    for tool <- ToolCatalog.tool_specs() do
      schema = Map.fetch!(tool, "inputSchema")

      assert schema["type"] == "object", "#{tool["name"]} inputSchema must be a top-level object"

      forbidden = Map.take(schema, @codex_forbidden_top_level_schema_keys)
      assert forbidden == %{}, "#{tool["name"]} has Codex-rejected top-level schema keys: #{inspect(Map.keys(forbidden))}"
    end
  end
end
