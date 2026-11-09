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

  test "tools list returns Codex-compatible top-level input schemas" do
    for tool <- ToolCatalog.tool_specs() do
      schema = Map.fetch!(tool, "inputSchema")

      assert schema["type"] == "object", "#{tool["name"]} inputSchema must be a top-level object"

      forbidden = Map.take(schema, @codex_forbidden_top_level_schema_keys)
      assert forbidden == %{}, "#{tool["name"]} has Codex-rejected top-level schema keys: #{inspect(Map.keys(forbidden))}"
    end
  end
end
