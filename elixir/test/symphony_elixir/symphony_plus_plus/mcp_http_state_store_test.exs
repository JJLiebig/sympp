defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPStateStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, HTTPStateStore, LedgerNamespace, Server}
  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @current_state_key "__sympp_mcp_current_state__"
  @unbound_client_key "__sympp_mcp_unbound__"

  defmodule FailingDynamicRepo do
    def get_dynamic_repo, do: Process.get(:sympp_mcp_http_state_store_test_dynamic_repo)
    def database_key(database), do: database
  end

  setup_all do
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    :ok
  end

  setup do
    HTTPStateStore.reset!()
    :ok
  end

  test "state entries are scoped by client and configured ledger" do
    config = config("ledger-a")
    other_ledger_config = config("ledger-b")
    server = initialized_server(config, "shared-state")

    assert :ok = HTTPStateStore.put(config, "client-a", "shared-state", server)

    assert %Server{initialized: true} = HTTPStateStore.get(config, "client-a", "shared-state")
    assert HTTPStateStore.get(config, "client-b", "shared-state") == nil
    assert HTTPStateStore.get(other_ledger_config, "client-a", "shared-state") == nil
  end

  test "a state key never hands one client's state to another or to the unbound client" do
    config = config("non-bearer-state-key")

    assert :ok = HTTPStateStore.put(config, "bound-client", "shared-state", initialized_server(config, "shared-state"))

    assert %Server{initialized: true} = HTTPStateStore.get(config, "bound-client", "shared-state")
    assert HTTPStateStore.get(config, @unbound_client_key, "shared-state") == nil
    assert HTTPStateStore.get(config, "other-client", "shared-state") == nil
  end

  test "stale state requests cannot republish a superseded current alias" do
    config = config("stale-alias-publish")
    old_server = initialized_server(config, "old-state")
    new_server = initialized_server(config, "new-state")

    assert :ok = HTTPStateStore.put(config, "client", "old-state", old_server)
    assert HTTPStateStore.publish_alias(config, "client", "old-state", "client", @current_state_key, old_server)

    assert :ok = HTTPStateStore.put(config, "client", "new-state", new_server)
    assert HTTPStateStore.supersede_alias(config, "client", "new-state", "client", @current_state_key, new_server)

    refute HTTPStateStore.publish_alias(config, "client", "old-state", "client", @current_state_key, old_server)
    assert %Server{state_key: "new-state"} = HTTPStateStore.get(config, "client", @current_state_key)
    assert HTTPStateStore.get(config, "client", "old-state") == nil
  end

  test "queued updates started before invalidation cannot resurrect state" do
    config = config("queued-invalidate")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    first =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_first_update, self()})

          receive do
            :release_first_update -> :ok
          after
            1_000 -> raise "timed out waiting to release first update"
          end

          {:first, %{server | initialized: true}}
        end)
      end)

    assert_receive {:entered_first_update, first_pid}

    second =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_second_update, server.initialized})
          {:second, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", "state")

    send(first_pid, :release_first_update)

    assert Task.await(first) == {:first, :dropped}
    assert_receive {:entered_second_update, false}
    assert Task.await(second) == {:second, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "direct put cannot be overwritten by an in-flight stale update" do
    config = config("put-race")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    update =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:stale_update, %{server | state_key: "stale-update", initialized: true}}
        end)
      end)

    assert_receive {:holding_update, update_pid}

    put = Task.async(fn -> HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put")) end)
    refute Task.yield(put, 50)

    send(update_pid, :release_update)

    assert Task.await(update) == {:stale_update, :stored}
    assert Task.await(put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  test "newer successful writes prevent older queued puts from overwriting state" do
    config = config("queued-write-order")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_write_order_update, self()})

          receive do
            :release_write_order_update -> :ok
          after
            1_000 -> raise "timed out waiting to release write-order update"
          end

          {:held, %{server | state_key: "held-update", initialized: true}}
        end)
      end)

    assert_receive {:holding_write_order_update, holder_pid}

    stale_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "stale-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    fresh_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    reverse_queued_lock(config, "client", "state")
    send(holder_pid, :release_write_order_update)

    assert Task.await(holder) == {:held, :stored}
    assert Task.await(fresh_put) == :ok
    assert Task.await(stale_put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  test "bypassed updates do not supersede queued writes" do
    config = config("bypassed-write-order")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_bypassed_write_order, self()})

          receive do
            :release_bypassed_write_order -> :ok
          after
            1_000 -> raise "timed out waiting to release bypassed write order"
          end

          {:held, %{server | state_key: "held-update"}}
        end)
      end)

    assert_receive {:holding_bypassed_write_order, holder_pid}

    pending =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          {:pending, %{server | state_key: "pending-update"}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    bypass =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn _server ->
          {:bypass, :route}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    reverse_queued_lock(config, "client", "state")
    send(holder_pid, :release_bypassed_write_order)

    assert Task.await(holder) == {:held, :stored}
    assert {{:route, %Server{state_key: "held-update"}}, :bypassed} = Task.await(bypass)
    assert Task.await(pending) == {:pending, :stored}
    assert %Server{state_key: "pending-update"} = HTTPStateStore.get(config, "client", "state")
  end

  test "alias publication cannot be overwritten by an in-flight stale alias update" do
    config = config("alias-publish-race")
    parent = self()
    source_server = initialized_server(config, "source-state")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)

    alias_default = default_server_fun(config, @current_state_key)

    update =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", @current_state_key, alias_default, fn
          server ->
            send(parent, {:holding_alias_update, self()})

            receive do
              :release_alias_update -> :ok
            after
              1_000 -> raise "timed out waiting to release alias update"
            end

            {:stale_alias_update, %{server | state_key: "stale-current", initialized: true}}
        end)
      end)

    assert_receive {:holding_alias_update, update_pid}

    fresh_alias_server = initialized_server(config, "fresh-current")
    publish = Task.async(fn -> HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, fresh_alias_server) end)

    wait_for_queued_lock(config, "client", @current_state_key, 1)

    send(update_pid, :release_alias_update)

    assert Task.await(update) == {:stale_alias_update, :stored}
    assert Task.await(publish)
    assert %Server{state_key: "fresh-current"} = HTTPStateStore.get(config, "client", @current_state_key)
  end

  test "queued alias writes started before invalidation cannot resurrect aliases" do
    publish_config = config("queued-alias-publish")

    assert_queued_alias_write_dropped_after_invalidation(publish_config, fn alias_server ->
      HTTPStateStore.publish_alias(publish_config, "client", "source-state", "client", @current_state_key, alias_server)
    end)

    HTTPStateStore.reset!()
    supersede_config = config("queued-alias-supersede")

    assert_queued_alias_write_dropped_after_invalidation(supersede_config, fn alias_server ->
      HTTPStateStore.supersede_alias(supersede_config, "client", "source-state", "client", @current_state_key, alias_server)
    end)
  end

  test "delete prevents queued updates from resurrecting deleted state" do
    config = config("queued-delete")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    first =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:first, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, update_pid}

    delete = Task.async(fn -> HTTPStateStore.delete(config, "client", "state") end)
    wait_for_queued_lock(config, "client", "state", 1)

    second =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_second_update, server.initialized})
          {:second, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    send(update_pid, :release_update)

    assert Task.await(first) == {:first, :stored}
    assert Task.await(delete) == :ok
    assert_receive {:entered_second_update, false}
    assert Task.await(second) == {:second, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "queued direct puts started before invalidation cannot resurrect state" do
    config = config("queued-put-invalidate")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}

    stale_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "stale-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", "state")
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(stale_put) == :ok
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "ttl cleanup prevents queued updates from resurrecting expired state" do
    original_ttl_ms = :sys.get_state(HTTPStateStore).ttl_ms
    on_exit(fn -> :sys.replace_state(HTTPStateStore, &%{&1 | ttl_ms: original_ttl_ms}) end)

    config = config("queued-ttl-expire")
    parent = self()
    key = store_key(config, "client", "state")

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}

    queued =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          {:queued, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    :sys.replace_state(HTTPStateStore, fn state ->
      entries = Map.update!(state.entries, key, fn {server, _touched_at} -> {server, System.monotonic_time(:millisecond) - 10} end)
      %{state | entries: entries, ttl_ms: 1}
    end)

    assert HTTPStateStore.get(config, "client", "state") == nil
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(queued) == {:queued, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "first write after ttl cleanup can recreate expired state while queued" do
    config = config("post-ttl-queued-recreate")
    parent = self()
    key = store_key(config, "client", "state")

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "expired"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}
    expire_entry(key)

    fresh_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(fresh_put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  defp config(database), do: Config.default(mode: :http, repo: Repo, database: database)

  defp initialized_server(config, state_key) do
    Server.new(config, state_key: state_key, initialized: true)
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

  defp assert_queued_alias_write_dropped_after_invalidation(%Config{} = config, alias_fun) do
    parent = self()
    source_server = initialized_server(config, "source-state")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)
    alias_default = default_server_fun(config, @current_state_key)

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", @current_state_key, alias_default, fn server ->
          send(parent, {:holding_alias_update, self()})

          receive do
            :release_alias_update -> :ok
          after
            1_000 -> raise "timed out waiting to release alias update"
          end

          {:held_alias, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_alias_update, holder_pid}

    alias_write =
      Task.async(fn ->
        alias_fun.(initialized_server(config, "queued-current"))
      end)

    wait_for_queued_lock(config, "client", @current_state_key, 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", @current_state_key)
    send(holder_pid, :release_alias_update)

    assert Task.await(holder) == {:held_alias, :dropped}
    refute Task.await(alias_write)
    assert HTTPStateStore.get(config, "client", @current_state_key) == nil
  end

  defp expire_entry(key) do
    :sys.replace_state(HTTPStateStore, fn state ->
      entries =
        Map.update!(state.entries, key, fn {server, _touched_at} ->
          {server, System.monotonic_time(:millisecond) - 86_400_001}
        end)

      %{state | entries: entries}
    end)
  end
end
