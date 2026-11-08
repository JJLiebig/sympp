defmodule SymphonyElixir.MCPHarness do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}

  @test_core_id "test-core"

  @doc """
  Sends one JSON-RPC payload to a fresh server. `terminal: "t1"` makes every
  tools/call come from that Herdr terminal (the bridge's `_meta.herdr`);
  without it the caller is outside Herdr and read-only.
  """
  @spec request(term(), keyword()) :: map() | [map()] | nil
  def request(payload, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> Config.default(repo: Keyword.fetch!(opts, :repo)) end)
    payload = payload |> normalize_payload() |> put_terminal(Keyword.get(opts, :terminal), Keyword.get(opts, :labels, %{}))
    initialized = Keyword.get_lazy(opts, :initialized, fn -> initialized_default(payload) end)

    server_opts = [initialized: initialized, state_key: Keyword.get(opts, :state_key)]
    Server.handle(payload, Server.new(config, server_opts))
  end

  @doc "The `_meta.herdr` a verified bridge sends for terminal `address`."
  @spec herdr_meta(String.t(), map(), String.t()) :: map()
  def herdr_meta(address, labels \\ %{}, core_id \\ @test_core_id) do
    %{"core_id" => core_id, "core_name" => "testbox", "terminal_id" => address, "labels" => labels}
  end

  @spec test_core_id() :: String.t()
  def test_core_id, do: @test_core_id

  defp put_terminal(payload, nil, _labels), do: payload
  defp put_terminal(payloads, address, labels) when is_list(payloads), do: Enum.map(payloads, &put_terminal(&1, address, labels))

  defp put_terminal(%{"method" => "tools/call"} = payload, address, labels) do
    params = Map.get(payload, "params", %{})
    meta = Map.put(Map.get(params, "_meta", %{}), "herdr", herdr_meta(address, labels))
    Map.put(payload, "params", Map.put(params, "_meta", meta))
  end

  defp put_terminal(payload, _address, _labels), do: payload

  defp normalize_payload(payload) when is_map(payload) or is_list(payload), do: payload

  defp initialized_default(%{"method" => "initialize"}), do: false
  defp initialized_default(_payload), do: true
end
