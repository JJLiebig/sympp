defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPTransportMinimalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    FailedCall,
    HTTPStateStore,
    HTTPTransport,
    LedgerNamespace,
    Server
  }

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    assert :ok = WorkPackageRepository.migrate(Repo)
    assert :ok = SoloSessionRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, config: Config.default(mode: :http, repo: Repo)}
  end

  setup %{config: config} do
    reset_server_response_state()
    HTTPStateStore.reset!()

    config.repo.delete_all(SoloSessionEntry)
    config.repo.delete_all(SoloSession)
    config.repo.delete_all(OperatorSettings)
    config.repo.delete_all(WorkPackage)
    FailedCall.reset()

    :ok
  end

  test "initialize only marks state trusted when the internal daemon config opts in", %{config: config} do
    assert {:ok, ordinary} = HTTPTransport.handle(config, initialize_request("ordinary-init"), client_key: "ordinary-client")
    assert %Server{local_daemon_trusted: false} = HTTPStateStore.get(config, "ordinary-client", ordinary.state_key)

    trusted_config = Config.default(mode: :http, repo: Repo, local_daemon_trusted: true)

    assert {:ok, trusted} = HTTPTransport.handle(trusted_config, initialize_request("trusted-init"), client_key: "trusted-client")
    assert %Server{local_daemon_trusted: true} = HTTPStateStore.get(trusted_config, "trusted-client", trusted.state_key)
  end

  test "live repo policy stays in transport for state-local and repo-backed followups", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")
    parent = self()
    ref = make_ref()

    live_handle = fn _payload, _client_key, _state_key ->
      send(parent, {:live_handle_called, ref})
      {:error, :repo_unavailable}
    end

    assert {:ok, health} =
             HTTPTransport.handle(config, health_request("health"),
               client_key: "client-a",
               state_key: init.state_key,
               live_handle: live_handle
             )

    assert get_in(health.response, ["result", "structuredContent", "status"]) == "ok"
    refute_receive {:live_handle_called, ^ref}

    assert {:ok, resources} =
             HTTPTransport.handle(config, resources_list_request("resources"),
               client_key: "client-a",
               state_key: init.state_key,
               live_handle: live_handle
             )

    assert get_in(resources.response, ["result", "resources", Access.at(0), "uri"]) == "sympp://health/version"
    refute_receive {:live_handle_called, ^ref}

    repo_backed = tool_call_request("repo-backed", "solo_list", %{})

    assert {:error, :ledger_unavailable, ^repo_backed} =
             HTTPTransport.handle(config, repo_backed,
               client_key: "client-a",
               state_key: init.state_key,
               live_handle: live_handle
             )

    assert_receive {:live_handle_called, ^ref}
  end

  test "a second client cannot reuse initialized state from a state key", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, foreign_tools} =
             HTTPTransport.handle(config, tools_list_request("foreign-tools"), client_key: "client-b", state_key: init.state_key)

    assert foreign_tools.status == :error
    assert foreign_tools.state_key == nil
    assert get_in(foreign_tools.response, ["error", "data", "reason"]) == "unknown_state_key"
    assert HTTPStateStore.get(config, "client-b", init.state_key) == nil
    assert %Server{initialized: true} = HTTPStateStore.get(config, "client-a", init.state_key)
  end

  test "batch transport observes each failed tool item once without retaining values", %{config: config} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(config.repo, %{"capture_failed_mcp_calls" => true})
    {:ok, init} = HTTPTransport.handle(config, initialize_request("batch-failure-init"), client_key: "batch-failure-client")

    request = tool_call_request("private-request-id", "sympp.health", %{"bearer" => "request-secret"})
    notification = tool_call_request(nil, "sympp.health", %{"bearer" => "notification-secret"}) |> Map.delete("id")

    {result, log} =
      with_log(fn ->
        HTTPTransport.handle(config, [request, notification],
          client_key: "batch-failure-client",
          state_key: init.state_key
        )
      end)

    assert {:ok, %{response: [%{"error" => %{"data" => %{"diagnostic_id" => diagnostic_id}}}]}} = result
    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/
    assert events = diagnostic_events(log)
    assert length(events) == 2
    assert Enum.all?(events, &(&1["failure_layer"] == "tool"))
    assert events |> Enum.map(& &1["diagnostic_id"]) |> Enum.uniq() |> length() == 2
    refute log =~ "private-request-id"
    refute log =~ "request-secret"
    refute log =~ "notification-secret"
  end

  test "batched initialize requests are rejected without creating HTTP state", %{config: config} do
    assert {:ok, batch_initialize} =
             HTTPTransport.handle(config, [initialize_request("batch-init")], client_key: "client-a")

    assert batch_initialize.status == :error
    assert batch_initialize.state_key == nil
    assert get_in(batch_initialize.response, ["error", "data", "reason"]) == "initialize_must_be_standalone"
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "raced missing existing state is not recreated as a placeholder", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")
    parent = self()

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(
          config,
          "client-a",
          init.state_key,
          default_server_fun(config, init.state_key),
          fn server ->
            send(parent, {:holding_update, self()})

            receive do
              :release_update -> :ok
            after
              1_000 -> raise "timed out waiting to release update"
            end

            {:held, server}
          end
        )
      end)

    assert_receive {:holding_update, holder_pid}

    raced_transport =
      Task.async(fn ->
        HTTPTransport.handle(config, tools_list_request("raced-tools"), client_key: "client-a", state_key: init.state_key)
      end)

    wait_for_queued_lock(config, "client-a", init.state_key, 1)

    delete = Task.async(fn -> HTTPStateStore.delete(config, "client-a", init.state_key) end)

    wait_for_queued_lock(config, "client-a", init.state_key, 2)
    reverse_queued_lock(config, "client-a", init.state_key)
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :stored}
    assert Task.await(delete) == :ok
    assert {:ok, lost} = Task.await(raced_transport)
    assert lost.status == :error
    assert lost.state_key == nil
    assert get_in(lost.response, ["error", "data", "reason"]) == "state_update_lost"
    assert HTTPStateStore.get(config, "client-a", init.state_key) == nil
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "sympp-http-transport-minimal-test-client", "version" => "0.1.0"},
        "capabilities" => %{}
      }
    }
  end

  defp tools_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  defp resources_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}

  defp health_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "sympp.health", "arguments" => %{}}
    }
  end

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp diagnostic_events(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ~s("event":"sympp_failed_mcp_call")))
    |> Enum.map(fn line ->
      {json_start, 1} = :binary.match(line, "{")
      line |> binary_part(json_start, byte_size(line) - json_start) |> Jason.decode!()
    end)
  end

  defp reset_server_response_state do
    handle_state_agent = Module.concat(Server, HandleState)

    case Process.whereis(handle_state_agent) do
      nil -> :ok
      _pid -> reset_handle_state_agent(handle_state_agent)
    end
  end

  defp reset_handle_state_agent(handle_state_agent) do
    Agent.update(handle_state_agent, fn _store -> %{} end)
  catch
    :exit, _reason -> :ok
  end

  defp default_server_fun(config, state_key) do
    fn -> Server.new(config, state_key: state_key) end
  end

  defp wait_for_queued_lock(config, client_key, state_key, expected_len, attempts \\ 50)

  defp wait_for_queued_lock(_config, _client_key, _state_key, expected_len, 0) do
    flunk("timed out waiting for #{expected_len} queued HTTP state lock waiters")
  end

  defp wait_for_queued_lock(%Config{} = config, client_key, state_key, expected_len, attempts) do
    store = :sys.get_state(HTTPStateStore)
    key = store_key(config, client_key, state_key)

    queued? =
      case Map.get(store.locks, key) do
        %{queue: queue} -> :queue.len(queue) >= expected_len
        _missing -> false
      end

    if queued? do
      :ok
    else
      Process.sleep(10)
      wait_for_queued_lock(config, client_key, state_key, expected_len, attempts - 1)
    end
  end

  defp reverse_queued_lock(%Config{} = config, client_key, state_key) do
    key = store_key(config, client_key, state_key)

    :sys.replace_state(HTTPStateStore, fn state ->
      locks =
        Map.update!(state.locks, key, fn lock ->
          queue =
            lock.queue
            |> :queue.to_list()
            |> Enum.reverse()
            |> :queue.from_list()

          %{lock | queue: queue}
        end)

      %{state | locks: locks}
    end)

    :ok
  end

  defp store_key(%Config{} = config, client_key, state_key) do
    {config.mode, LedgerNamespace.key(config), client_key, state_key}
  end
end
