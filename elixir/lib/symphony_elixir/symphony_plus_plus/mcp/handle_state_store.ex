defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HandleStateStore do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{LedgerNamespace, Server}

  @server Server
  @agent Module.concat(Server, HandleState)
  @handle_state_ttl_ms 86_400_000
  @explicit_handle_state_ttl_ms 604_800_000

  @spec cleanup_default_handle_states() :: :ok
  def cleanup_default_handle_states do
    now = monotonic_ms()

    update(fn store ->
      Map.reject(store, fn
        {_state_key, {%{__struct__: @server}, timestamp_ms, false}} -> now - timestamp_ms > @handle_state_ttl_ms
        {_state_key, {%{__struct__: @server}, timestamp_ms, true}} -> now - timestamp_ms > @explicit_handle_state_ttl_ms
        _entry -> false
      end)
    end)

    :ok
  end

  @doc "Restores whether an explicit state key was initialized."
  @spec restore(term(), Server.t()) :: Server.t()
  def restore(payload, %{__struct__: @server} = server) do
    cond do
      initialize_request?(payload) and not server.initialized ->
        if not server.state_key_explicit, do: delete(server)
        server

      true ->
        case lookup(server) do
          {%{__struct__: @server} = stored, _timestamp_ms, _explicit?} ->
            %{server | initialized: server.initialized or stored.initialized, state_key_version: stored.state_key_version}

          _missing ->
            server
        end
    end
  end

  @doc "Remembers a successful initialize, and keeps a known state key fresh."
  @spec persist(term(), map() | [map()] | nil, Server.t(), Server.t()) :: Server.t()
  def persist(payload, response, %{__struct__: @server} = server, %{__struct__: @server} = updated_server) do
    cond do
      initialize_request?(payload) and match?(%{"result" => _result}, response) ->
        %{updated_server | state_key_version: put(updated_server)}

      initialize_request?(payload) and server.state_key_explicit and not match?(%{"error" => %{"data" => %{"reason" => "already_initialized"}}}, response) ->
        delete(server)
        %{updated_server | state_key_version: nil}

      lookup(updated_server) != nil ->
        refresh(updated_server)
        updated_server

      true ->
        updated_server
    end
  end

  @spec repo_query(term(), String.t(), list(), keyword()) :: term()
  def repo_query(repo, sql, params, opts) when is_atom(repo) do
    if repo_module_query?(repo) do
      repo.query(sql, params, opts)
    else
      case dynamic_repo_identity(repo) do
        pid when is_pid(pid) -> SQL.query(pid, sql, params, opts)
        dynamic_repo when is_atom(dynamic_repo) and dynamic_repo != repo -> SQL.query(dynamic_repo, sql, params, opts)
        _repo -> SQL.query(repo, sql, params, opts)
      end
    end
  end

  def repo_query(repo, sql, params, opts), do: SQL.query(repo, sql, params, opts)

  defp put(%{__struct__: @server} = server) do
    key = key(server)
    timestamp_ms = monotonic_ms()
    state_key_version = System.unique_integer([:monotonic, :positive])
    stored_server = %{server | state_key_version: state_key_version}
    update(&Map.put(&1, key, {stored_server, timestamp_ms, server.state_key_explicit}))
    state_key_version
  end

  defp delete(%{__struct__: @server} = server) do
    update(&Map.delete(&1, key(server)))
    :ok
  end

  defp lookup(%{__struct__: @server} = server), do: get() |> Map.get(key(server))

  defp refresh(%{__struct__: @server} = server) do
    case lookup(server) do
      {%{__struct__: @server} = stored_server, _timestamp_ms, _explicit?} -> put(stored_server)
      _state -> nil
    end
  end

  defp update(fun) do
    ensure_agent()
    Agent.update(@agent, fun)
  end

  defp get do
    ensure_agent()
    Agent.get(@agent, & &1)
  end

  defp ensure_agent do
    case Process.whereis(@agent) do
      nil ->
        case Agent.start(fn -> %{} end, name: @agent) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp key(%{__struct__: @server} = server), do: {{server.config.mode, LedgerNamespace.key(server.config)}, server.state_key}

  defp repo_module_query?(repo) do
    case Code.ensure_loaded(repo) do
      {:module, _module} -> function_exported?(repo, :query, 3)
      {:error, _reason} -> false
    end
  end

  defp dynamic_repo_identity(repo) when is_atom(repo), do: if(function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo())
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false
end
