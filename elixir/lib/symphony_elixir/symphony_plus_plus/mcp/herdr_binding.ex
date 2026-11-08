defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HerdrBinding do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Server, Session, ToolCatalog}

  @release_tool "release_current_assignment"

  # Role labels come from claims and writes. A read never assigns a role: a
  # bound session keeps reporting its claim, and an unbound read labels nothing.
  # For session locations (`:location`), an unbound read may still refresh a
  # coordinator location its own client recorded through an earlier write.
  @spec response_binding(term(), term(), Server.t(), :label | :location) :: map() | :clear | nil
  def response_binding(payload, response, %Server{} = server, purpose \\ :label) do
    cond do
      stale_unbound?(server) -> :clear
      release_unbound?(payload, server) -> :clear
      not successful_response?(response) -> nil
      match?(%Session{}, server.session) -> bound_binding(server, payload, response)
      true -> unbound_binding(payload, response, purpose)
    end
  rescue
    _error -> nil
  end

  defp unbound_binding(payload, response, :location), do: unbound_response_binding(payload, response)

  defp unbound_binding(payloads, responses, :label) when is_list(payloads),
    do: unbound_response_binding(Enum.reject(payloads, &read_request?/1), responses)

  defp unbound_binding(payload, response, :label),
    do: if(read_request?(payload), do: nil, else: unbound_response_binding(payload, response))

  @spec encode(map() | :clear) :: String.t()
  def encode(:clear), do: "clear"

  def encode(binding) when is_map(binding) do
    binding
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp bound_binding(%Server{session: %Session{assignment: assignment}}, payload, response) do
    role = assignment.grant_role

    %{
      "role" => role,
      "work_request_id" => work_request_scope_id(assignment.scopes) || write_work_request_id(payload, response),
      "work_package_id" => assignment.work_package_id,
      "show_inspector" => role == "architect"
    }
    |> drop_nil_values()
  end

  defp coordinator_binding(work_request_id) do
    %{
      "role" => "coordinator",
      "work_request_id" => work_request_id,
      "show_inspector" => true
    }
  end

  defp unbound_response_binding(payloads, responses) when is_list(payloads) and is_list(responses) do
    Enum.reduce(payloads, nil, fn payload, binding ->
      case response_for_payload(payload, responses) do
        nil -> binding
        response -> unbound_response_binding(payload, response) || binding
      end
    end)
  end

  defp unbound_response_binding(
         %{"method" => "tools/call", "params" => %{"name" => "register_chief"}},
         %{"result" => %{"structuredContent" => %{"chief" => %{"domain" => domain}}}}
       ) do
    %{"role" => "chief", "domain" => domain}
  end

  defp unbound_response_binding(payload, response) do
    cond do
      not successful_response?(response) -> nil
      release_cleared?(payload, response) -> :clear
      work_request_id = work_request_id(payload, response) -> coordinator_binding(work_request_id)
      true -> nil
    end
  end

  defp write_work_request_id(payload, response) do
    if read_request?(payload), do: nil, else: work_request_id(payload, response)
  end

  defp read_request?(payloads) when is_list(payloads), do: payloads != [] and Enum.all?(payloads, &read_request?/1)

  defp read_request?(%{"method" => "tools/call", "params" => %{"name" => name} = params}) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})
    ToolCatalog.read_call?(name, if(is_map(arguments), do: arguments, else: %{}))
  end

  defp read_request?(_payload), do: false

  defp work_request_id(
         %{"method" => "tools/call", "params" => %{"arguments" => arguments}},
         response
       )
       when is_map(arguments) do
    nonblank(Map.get(arguments, "work_request_id")) || response_work_request_id(response)
  end

  defp work_request_id(_payload, _response), do: nil

  defp response_for_payload(%{"id" => id}, responses) do
    Enum.find(responses, &match?(%{"id" => ^id}, &1))
  end

  defp response_for_payload(_payload, _responses), do: nil

  defp response_work_request_id(%{
         "result" => %{"structuredContent" => %{"work_request" => %{"id" => work_request_id}}}
       }),
       do: nonblank(work_request_id)

  defp response_work_request_id(%{
         "result" => %{"structuredContent" => %{"work_request_id" => work_request_id}}
       }),
       do: nonblank(work_request_id)

  defp response_work_request_id(_response), do: nil

  defp work_request_scope_id(scopes) when is_list(scopes) do
    Enum.find_value(scopes, fn
      %Scope{type: :work_request, id: id} when is_binary(id) -> id
      _scope -> nil
    end)
  end

  defp work_request_scope_id(_scopes), do: nil

  defp release_request?(%{"method" => "tools/call", "params" => %{"name" => @release_tool}}), do: true
  defp release_request?(payloads) when is_list(payloads), do: Enum.any?(payloads, &release_request?/1)
  defp release_request?(_payload), do: false

  defp release_cleared?(payload, response) do
    release_request?(payload) and
      get_in(response, ["result", "structuredContent", "binding_cleared"]) == true
  end

  defp successful_response?(%{"result" => _result}), do: true
  defp successful_response?(responses) when is_list(responses), do: Enum.any?(responses, &successful_response?/1)
  defp successful_response?(_response), do: false

  defp stale_unbound?(%Server{session: nil} = server) do
    server.session_refresh_required or is_binary(server.stale_assignment_role)
  end

  defp stale_unbound?(%Server{}), do: false

  defp release_unbound?(payload, %Server{session: nil}), do: release_request?(payload)
  defp release_unbound?(_payload, %Server{}), do: false

  defp nonblank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp nonblank(_value), do: nil

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
