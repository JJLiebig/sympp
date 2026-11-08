defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HerdrBinding do
  @moduledoc """
  The `sympp-herdr-binding` response header: which WorkRequest the calling
  terminal works on, so the bridge can label its Herdr pane.

  Only a successful owner-gated write (or creating a WorkRequest it owns) sets
  the binding; reads never do.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  @spec response_binding(term(), term()) :: map() | nil
  def response_binding(payloads, responses) when is_list(payloads) and is_list(responses) do
    Enum.reduce(payloads, nil, fn payload, binding ->
      case response_for_payload(payload, responses) do
        nil -> binding
        response -> response_binding(payload, response) || binding
      end
    end)
  end

  def response_binding(%{"method" => "tools/call", "params" => %{"name" => name} = params}, %{"result" => result} = response) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    with false <- Map.get(result, "isError", false),
         %Terminal{} = terminal <- Terminal.from_params(params),
         true <- binds?(name, arguments, response),
         work_request_id when is_binary(work_request_id) <- work_request_id(arguments, response) do
      %{"role" => terminal.role, "work_request_id" => work_request_id, "show_inspector" => true}
    else
      _no_binding -> nil
    end
  rescue
    _error -> nil
  end

  def response_binding(_payload, _response), do: nil

  @spec encode(map()) :: String.t()
  def encode(binding) when is_map(binding) do
    binding
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp binds?("create_work_request", _arguments, response), do: is_map(get_in(response, ["result", "structuredContent", "worked_on"]))
  defp binds?(name, arguments, _response), do: ToolCatalog.owner_gated_call?(name, arguments)

  defp work_request_id(arguments, response) do
    nonblank(Map.get(arguments, "work_request_id")) ||
      nonblank(get_in(response, ["result", "structuredContent", "work_request", "id"])) ||
      nonblank(get_in(response, ["result", "structuredContent", "work_request_id"]))
  end

  defp response_for_payload(%{"id" => id}, responses), do: Enum.find(responses, &match?(%{"id" => ^id}, &1))
  defp response_for_payload(_payload, _responses), do: nil

  defp nonblank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp nonblank(_value), do: nil
end
