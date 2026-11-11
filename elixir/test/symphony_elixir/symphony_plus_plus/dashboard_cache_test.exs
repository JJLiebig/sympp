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
end
