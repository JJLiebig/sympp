defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, DashboardPubSub, Repo}

  setup do
    path = Path.join(System.tmp_dir!(), "dashboard-cache-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
    {:ok, pid} = Repo.start_link(database: path, name: nil, pool_size: 2, log: false)
    Process.unlink(pid)
    previous = Repo.put_dynamic_repo(pid)
    Repo.query!("CREATE TABLE probe (value TEXT)")
    Repo.query!("INSERT INTO probe VALUES ('recorded')")

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      if Process.alive?(pid), do: GenServer.stop(pid)
      :sys.get_state(DashboardCache)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    %{pid: pid, path: path}
  end

  defp payload do
    %{rows: [[value]]} = Repo.query!("SELECT value FROM probe")
    {:ok, %{decision: value}}
  end

  defp release_on_exit(pid) do
    released = :atomics.new(1, [])

    release = fn ->
      if :atomics.exchange(released, 1, 1) == 0, do: send(pid, :continue)
    end

    on_exit(release)
    release
  end

  test "commits by another SQLite writer invalidate an encoded response without a notification", %{path: path} do
    assert {:ok, old, old_etag} = DashboardCache.json(Repo, :native, &payload/0)
    assert Jason.decode!(old)["decision"] == "recorded"

    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)

    assert {:ok, fresh, fresh_etag} = DashboardCache.json(Repo, :native, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "acknowledged"
    refute fresh_etag == old_etag
    assert {:ok, ^fresh, ^fresh_etag} = DashboardCache.json(Repo, :native, &payload/0)
  end

  test "a commit during projection construction cannot poison subsequent reads", %{pid: pid, path: path} do
    caller = self()

    read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)

        DashboardCache.json(Repo, :racing, fn ->
          captured = payload()
          send(caller, {:captured, self()})
          receive do: (:continue -> captured)
        end)
      end)

    assert_receive {:captured, builder}
    release = release_on_exit(builder)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    release.()
    assert {:ok, _old, _etag} = Task.await(read)
    assert {:ok, fresh, _etag} = DashboardCache.json(Repo, :racing, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "acknowledged"
  end

  test "an uninitialized schema returns a storage error without taking other reads down" do
    assert {:error, {:storage_failed, _message}} =
             DashboardCache.json(Repo, :missing, fn ->
               Repo.query!("SELECT value FROM missing_table")
             end)

    assert {:ok, body, _etag} = DashboardCache.json(Repo, :native, &payload/0)
    assert Jason.decode!(body)["decision"] == "recorded"
  end

  defp controlled_clock do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, System.monotonic_time(:millisecond))
    original_clock = :sys.get_state(DashboardCache).clock
    :sys.replace_state(DashboardCache, &%{&1 | clock: fn -> :atomics.get(clock, 1) end})
    on_exit(fn -> :sys.replace_state(DashboardCache, &%{&1 | clock: original_clock}) end)
    clock
  end

  test "quiet reads return immediately during timed refresh and a racing write stays fresh", %{path: path} do
    clock = controlled_clock()
    assert {:ok, old, etag} = DashboardCache.json(Repo, :expiry, &payload/0)
    caller = self()

    builder = fn ->
      captured = payload()
      send(caller, {:refreshing, self()})
      receive do: (:continue -> captured)
    end

    DashboardCache.json(Repo, :expiry, builder)
    :atomics.add(clock, 1, 15_001)
    assert {:ok, ^old, ^etag} = DashboardCache.json(Repo, :expiry, builder)

    assert_receive {:refreshing, worker}
    ref = Process.monitor(worker)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    assert {:ok, fresh, fresh_etag} = DashboardCache.json(Repo, :expiry, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "acknowledged"
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    assert {:ok, ^fresh, ^fresh_etag} = DashboardCache.json(Repo, :expiry, &payload/0)
  end

  test "time-derived changes notify clients and keep all prepared surfaces ready to read" do
    clock = controlled_clock()
    :ok = DashboardPubSub.subscribe()
    assert {:ok, old, _etag} = DashboardCache.json(Repo, :time, &payload/0)
    caller = self()

    builder = fn ->
      send(caller, {:time_refresh, self()})
      receive do: (:continue -> {:ok, %{decision: "elapsed"}})
    end

    DashboardCache.json(Repo, :time, builder)
    :atomics.add(clock, 1, 15_001)
    assert {:ok, other, other_etag} = DashboardCache.json(Repo, :other, &payload/0)
    assert {:ok, ^old, _etag} = DashboardCache.json(Repo, :time, builder)
    assert_receive {:time_refresh, worker}
    send(worker, :continue)
    assert_receive :operator_dashboard_changed
    assert {:ok, ^other, ^other_etag} = DashboardCache.json(Repo, :other, fn -> {:ok, %{decision: "recomputed"}} end)
    assert {:ok, fresh, _etag} = DashboardCache.json(Repo, :time, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "elapsed"
  end

  test "external commits notify subscribers without a client read", %{path: path} do
    :ok = DashboardPubSub.subscribe()
    assert {:ok, _body, _etag} = DashboardCache.json(Repo, :external, &payload/0)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    assert_receive :operator_dashboard_changed, 2_000
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :external, &payload/0)
    assert Jason.decode!(body)["decision"] == "acknowledged"
  end

  test "a read that discovers an external commit also notifies other subscribers", %{path: path} do
    assert {:ok, _old, _etag} = DashboardCache.json(Repo, :discovered, &payload/0)
    :ok = DashboardPubSub.subscribe()
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :discovered, &payload/0)
    assert Jason.decode!(body)["decision"] == "acknowledged"
    assert_receive :operator_dashboard_changed
  end

  test "an unprimed slow view leaves quiet cached reads available", %{pid: pid} do
    assert {:ok, quiet, etag} = DashboardCache.json(Repo, :quiet, &payload/0)
    caller = self()

    slow =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)

        DashboardCache.json(Repo, :cold, fn ->
          send(caller, {:cold_projection, self()})
          receive do: (:continue -> payload())
        end)
      end)

    assert_receive {:cold_projection, worker}
    release = release_on_exit(worker)

    read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)
        DashboardCache.json(Repo, :quiet, &payload/0)
      end)

    result = Task.yield(read, 100)
    release.()
    assert {:ok, {:ok, ^quiet, ^etag}} = result
    assert {:ok, _body, _etag} = Task.await(slow)
  end

  test "observation invalidations keep reads available and overlapping signals catch up" do
    :ok = DashboardPubSub.subscribe()
    value = :atomics.new(1, [])
    caller = self()

    builder = fn ->
      captured = :atomics.get(value, 1)

      if captured == 1 do
        send(caller, {:observation_refresh, self()})
        receive do: (:continue -> :ok)
      end

      {:ok, %{observation: captured}}
    end

    assert {:ok, old, etag} = DashboardCache.json(Repo, :observation, builder)
    :atomics.put(value, 1, 1)
    DashboardPubSub.broadcast_changed()
    assert_receive :operator_dashboard_changed
    assert_receive {:observation_refresh, worker}
    assert {:ok, ^old, ^etag} = DashboardCache.json(Repo, :observation, builder)
    :atomics.put(value, 1, 2)
    DashboardPubSub.broadcast_changed()
    assert_receive :operator_dashboard_changed
    send(worker, :continue)
    assert_receive :operator_dashboard_changed
    assert_receive :operator_dashboard_changed
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :observation, builder)
    assert Jason.decode!(body)["observation"] == 2
  end

  test "a fresh read joins the current projection without blocking other surfaces", %{pid: pid, path: path} do
    caller = self()

    builder = fn ->
      result = payload()

      if elem(result, 1).decision == "acknowledged" do
        send(caller, {:current_projection, self()})
        receive do: (:continue -> :ok)
      end

      result
    end

    DashboardCache.json(Repo, :joined, builder)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    DashboardPubSub.broadcast_changed()
    assert_receive {:current_projection, worker}
    on_exit(fn -> send(worker, :continue) end)

    read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)
        DashboardCache.json(Repo, :joined, fn -> {:ok, %{decision: "duplicated"}} end)
      end)

    assert Task.yield(read, 100) == nil
    assert {:ok, _, _} = DashboardCache.json(Repo, :independent, &payload/0)
    send(worker, :continue)
    assert {:ok, body, _etag} = Task.await(read)
    assert Jason.decode!(body)["decision"] == "acknowledged"
  end

  test "a failed projection releases waiting readers and later reads recover", %{pid: pid, path: path} do
    caller = self()

    builder = fn ->
      result = payload()

      if elem(result, 1).decision == "acknowledged" do
        send(caller, {:current_projection, self()})
        receive do: (:continue -> :ok)
      end

      result
    end

    DashboardCache.json(Repo, :failed, builder)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    DashboardPubSub.broadcast_changed()
    assert_receive {:current_projection, worker}

    read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)
        DashboardCache.json(Repo, :failed, &payload/0)
      end)

    assert Task.yield(read, 100) == nil
    Process.exit(worker, :kill)
    assert {:error, {:storage_failed, _reason}} = Task.await(read)
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :failed, &payload/0)
    assert Jason.decode!(body)["decision"] == "acknowledged"
  end
end
