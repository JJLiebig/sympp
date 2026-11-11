defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, Repo}

  setup do
    path = Path.join(System.tmp_dir!(), "dashboard-cache-#{System.unique_integer([:positive])}.sqlite3")
    {:ok, pid} = Repo.start_link(database: path, name: nil, pool_size: 2, log: false)
    Process.unlink(pid)
    previous = Repo.put_dynamic_repo(pid)
    Repo.query!("CREATE TABLE probe (value TEXT)")
    Repo.query!("INSERT INTO probe VALUES ('recorded')")

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    %{pid: pid, path: path}
  end

  defp payload do
    %{rows: [[value]]} = Repo.query!("SELECT value FROM probe")
    {:ok, %{decision: value}}
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
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    send(builder, :continue)
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
    :atomics.add(clock, 1, 15_001)
    caller = self()

    assert {:ok, ^old, ^etag} =
             DashboardCache.json(Repo, :expiry, fn ->
               captured = payload()
               send(caller, {:refreshing, self()})
               receive do: (:continue -> captured)
             end)

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

  test "time-derived changes notify clients and leave the refreshed response ready to read" do
    clock = controlled_clock()
    :ok = SymphonyElixir.SymphonyPlusPlus.DashboardPubSub.subscribe()
    assert {:ok, old, _etag} = DashboardCache.json(Repo, :time, &payload/0)
    :atomics.add(clock, 1, 15_001)
    assert {:ok, ^old, _etag} = DashboardCache.json(Repo, :time, fn -> {:ok, %{decision: "elapsed"}} end)
    assert_receive :operator_dashboard_changed
    assert {:ok, fresh, _etag} = DashboardCache.json(Repo, :time, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "elapsed"
  end
end
