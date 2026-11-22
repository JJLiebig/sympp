defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, DashboardPubSub, HerdrCore, Repo}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionFeedback, DecisionLogEntry}

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
    first_build = :atomics.new(1, [])

    read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)

        DashboardCache.json(Repo, :racing, fn ->
          captured = payload()

          if :atomics.exchange(first_build, 1, 1) == 0 do
            send(caller, {:captured, self()})
            receive do: (:continue -> :ok)
          end

          captured
        end)
      end)

    assert_receive {:captured, builder}
    release = release_on_exit(builder)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    assert {:ok, fresh, etag} = DashboardCache.json(Repo, :racing, &payload/0)
    assert Jason.decode!(fresh)["decision"] == "acknowledged"
    release.()
    assert {:ok, old, _etag} = Task.await(read)
    assert Jason.decode!(old)["decision"] == "recorded"
    assert {:ok, ^fresh, ^etag} = DashboardCache.json(Repo, :racing, &payload/0)
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

  defp watch(surface, builder) do
    {:ok, cache, ref} = DashboardCache.watch(Repo, [{surface, builder}])
    on_exit(fn -> DashboardCache.unwatch(cache, ref) end)
    {cache, ref}
  end

  defp refresh_watches do
    send(DashboardCache, :refresh_watched)
    :sys.get_state(DashboardCache)
  end

  test "pending feedback reaches its interruption deadline without writes or reads" do
    clock = controlled_clock()
    initial = :atomics.get(clock, 1)
    reviewed_at = DateTime.add(DateTime.utc_now(), -30_000, :millisecond)
    builds = :atomics.new(1, [])

    builder = fn ->
      :atomics.add(builds, 1, 1)
      shifted = DateTime.add(reviewed_at, initial - :atomics.get(clock, 1), :millisecond)
      entry = %DecisionLogEntry{reviewed_at: shifted, undelivered_reason: "delivering"}
      {:ok, %{delivery: DecisionFeedback.undelivered_reason(entry)}}
    end

    {_cache, ref} = watch(:time, builder)
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, old, etag} = DashboardCache.json(Repo, :time, builder)
    assert Jason.decode!(old)["delivery"] == "delivering"

    :atomics.put(clock, 1, initial + 15_001)
    refresh_watches()
    assert {:ok, ^old, ^etag} = DashboardCache.json(Repo, :time, builder)
    assert :atomics.get(builds, 1) == 1

    :atomics.put(clock, 1, initial + 61_000)
    refresh_watches()
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, fresh, fresh_etag} = DashboardCache.json(Repo, :time, builder)
    assert Jason.decode!(fresh)["delivery"] == "delivery_interrupted"
    refute fresh_etag == etag
    assert :atomics.get(builds, 1) == 2
  end

  test "a remote owner becomes unknown when its lease expires and live after a fresh heartbeat" do
    clock = controlled_clock()
    ttl = 60_000
    terminal = "remote-core/t1"
    leases = start_supervised!({ClientLeases, name: :dashboard_test_leases, ttl_ms: ttl, sweep_ms: 120_000})
    assert {:ok, _} = ClientLeases.attach("bridge", leases, terminal)
    builder = fn -> {:ok, %{live: ClientLeases.terminal_live?(terminal, leases)}} end

    {_cache, ref} = watch(:hydrated, builder)
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :hydrated, builder)
    assert Jason.decode!(body)["live"]

    now = System.monotonic_time(:millisecond)
    :sys.replace_state(leases, &put_in(&1.leases["bridge"].last_seen_ms, now - ttl - 1))
    :atomics.put(clock, 1, now + ttl + 1)
    refresh_watches()
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :hydrated, builder)
    refute Jason.decode!(body)["live"]

    :atomics.put(clock, 1, System.monotonic_time(:millisecond))
    assert {:ok, _} = ClientLeases.heartbeat("bridge", leases, terminal)
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :hydrated, builder)
    assert Jason.decode!(body)["live"]
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

  test "an inspector watches other writers without constructing a board", %{path: path} do
    {_cache, ref} = watch(:herdr, :revision)
    assert_receive {:dashboard_changed, ^ref, _initial}

    log =
      capture_log(fn ->
        {:ok, writer} = Exqlite.Sqlite3.open(path)
        :ok = Exqlite.Sqlite3.execute(writer, "UPDATE probe SET value = 'acknowledged'")
        :ok = Exqlite.Sqlite3.close(writer)
        refresh_watches()
        assert_receive {:dashboard_changed, ^ref, _updated}
      end)

    assert log =~ "board_revision_probe surface=herdr"
    refute log =~ "board_build"
  end

  test "a watched board rechecks unavailable Herdr evidence at the provider deadline" do
    clock = controlled_clock()
    now = :atomics.get(clock, 1)
    command = "test-hc"
    cache_key = {HerdrCore, :snapshot}
    previous_snapshot = :persistent_term.get(cache_key, nil)
    previous_command = Application.get_env(:symphony_elixir, :sympp_herdr_core)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :sympp_herdr_core, previous_command)
      if previous_snapshot, do: :persistent_term.put(cache_key, previous_snapshot), else: :persistent_term.erase(cache_key)
    end)

    Application.put_env(:symphony_elixir, :sympp_herdr_core, command)
    :persistent_term.put(cache_key, {command, now, :unavailable, nil})
    builder = fn -> {:ok, %{worker: HerdrCore.status_state("test-core", "t1")}} end
    {_cache, ref} = watch(:hydrated, builder)
    assert_receive {:dashboard_changed, ^ref, _initial}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :hydrated, builder)
    assert Jason.decode!(body)["worker"] == "unknown"

    snapshot = {:ok, %{core_id: "test-core", terminals: %{"t1" => %{"state" => "live"}}}}
    at = System.monotonic_time(:millisecond)
    :persistent_term.put(cache_key, {command, at, snapshot, {at, snapshot}})

    :atomics.put(clock, 1, now + 15_000)
    refresh_watches()
    assert_receive {:dashboard_changed, ^ref, _updated}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :hydrated, builder)
    assert Jason.decode!(body)["worker"] == "live"
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

    assert {:ok, ^quiet, ^etag} = Task.await(read)
    release.()
    assert {:ok, _body, _etag} = Task.await(slow)
  end

  test "projection checkouts cannot exhaust the operator write pool", %{pid: pid} do
    caller = self()

    builds =
      for surface <- [:browser_checkout, :native_checkout] do
        Task.async(fn ->
          Repo.put_dynamic_repo(pid)

          DashboardCache.json(Repo, surface, fn ->
            Repo.checkout(fn ->
              send(caller, {:checkout_held, self()})
              receive do: (:continue -> payload())
            end)
          end)
        end)
      end

    assert_receive {:checkout_held, first}
    assert_receive {:checkout_held, second}
    release_first = release_on_exit(first)
    release_second = release_on_exit(second)

    write =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)
        Repo.query!("UPDATE probe SET value = 'acknowledged'")
      end)

    assert %{num_rows: 1} = Task.await(write)
    release_first.()
    release_second.()
    Enum.each(builds, &Task.await/1)
  end

  test "provider-only invalidations catch up to the latest input before waking the stream" do
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

    assert {:ok, _, _} = DashboardCache.json(Repo, :observation, builder)
    {_cache, ref} = watch(:observation, builder)
    :atomics.put(value, 1, 1)
    DashboardCache.invalidate([:observation])
    assert_receive {:observation_refresh, worker}
    release = release_on_exit(worker)
    :atomics.put(value, 1, 2)
    DashboardCache.invalidate([:observation])
    :sys.get_state(DashboardCache)
    release.()
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :observation, builder)
    assert Jason.decode!(body)["observation"] == 2
    refute_received {:dashboard_changed, ^ref, _version}
  end

  test "external writes coalesce behind one background build and catch up to the latest commit", %{path: path} do
    caller = self()
    builds = :atomics.new(1, [])

    builder = fn ->
      :atomics.add(builds, 1, 1)
      result = payload()

      if elem(result, 1).decision == "building" do
        send(caller, {:background_projection, self()})
        receive do: (:continue -> :ok)
      end

      result
    end

    assert {:ok, _old, _etag} = DashboardCache.json(Repo, :coalesced, builder)
    {_cache, ref} = watch(:coalesced, builder)
    {:ok, writer} = Exqlite.Sqlite3.open(path)
    on_exit(fn -> Exqlite.Sqlite3.close(writer) end)
    :ok = Exqlite.Sqlite3.execute(writer, "UPDATE probe SET value = 'building'")
    refresh_watches()
    assert_receive {:background_projection, worker}
    release = release_on_exit(worker)

    for value <- ["intermediate", "latest"] do
      :ok = Exqlite.Sqlite3.execute(writer, "UPDATE probe SET value = '#{value}'")
      refresh_watches()
    end

    assert :atomics.get(builds, 1) == 2
    release.()
    assert_receive {:dashboard_changed, ^ref, _version}
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :coalesced, builder)
    assert Jason.decode!(body)["decision"] == "latest"
    assert :atomics.get(builds, 1) == 3
  end

  test "the last disconnect stops probes and catch-up even during a build", %{path: path} do
    caller = self()

    builder = fn ->
      result = payload()
      send(caller, {:build, elem(result, 1).decision, self()})

      if elem(result, 1).decision == "building" do
        receive do: (:continue -> :ok)
      end

      result
    end

    {cache, ref} = watch(:disconnected, builder)
    assert_receive {:dashboard_changed, ^ref, _version}
    assert_receive {:build, "recorded", _worker}
    assert {:ok, _, _} = DashboardCache.json(Repo, :one_off, &payload/0)

    {:ok, writer} = Exqlite.Sqlite3.open(path)
    on_exit(fn -> Exqlite.Sqlite3.close(writer) end)
    :ok = Exqlite.Sqlite3.execute(writer, "UPDATE probe SET value = 'building'")
    refresh_watches()
    assert_receive {:build, "building", worker}
    release = release_on_exit(worker)
    finished = Process.monitor(worker)

    :ok = DashboardCache.unwatch(cache, ref)
    :sys.get_state(cache)

    log =
      capture_log(fn ->
        :ok = Exqlite.Sqlite3.execute(writer, "UPDATE probe SET value = 'latest'")
        DashboardPubSub.broadcast_changed()
        release.()
        assert_receive {:DOWN, ^finished, :process, ^worker, :normal}
        refresh_watches()
      end)

    refute log =~ "board_revision_probe"
    refute log =~ "board_build"
    refute_received {:build, "latest", _worker}
    assert {:ok, fresh, _etag} = DashboardCache.json(Repo, :disconnected, builder)
    assert Jason.decode!(fresh)["decision"] == "latest"
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
    watch(:joined, builder)
    {:ok, connection} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(connection, "UPDATE probe SET value = 'acknowledged'")
    :ok = Exqlite.Sqlite3.close(connection)
    refresh_watches()
    assert_receive {:current_projection, worker}
    release = release_on_exit(worker)
    read = :gen_server.send_request(DashboardCache, {:json, pid, :joined, fn -> {:ok, %{decision: "duplicated"}} end})

    assert {:ok, _, _} = DashboardCache.json(Repo, :independent, &payload/0)
    release.()
    assert {:reply, {:ok, body, _etag}} = :gen_server.wait_response(read, 1_000)
    assert Jason.decode!(body)["decision"] == "acknowledged"
  end

  test "a failed projection releases waiting readers and later reads recover", %{pid: pid} do
    caller = self()

    builder = fn ->
      send(caller, {:current_projection, self()})
      receive do: (:continue -> payload())
    end

    read = :gen_server.send_request(DashboardCache, {:json, pid, :failed, builder})
    assert_receive {:current_projection, worker}
    on_exit(fn -> send(worker, :continue) end)

    Process.exit(worker, :kill)
    assert {:reply, {:error, {:storage_failed, _reason}}} = :gen_server.wait_response(read, 1_000)
    assert {:ok, body, _etag} = DashboardCache.json(Repo, :failed, &payload/0)
    assert Jason.decode!(body)["decision"] == "recorded"
  end

  test "memory-ledger reads after a write do not join an older unversioned snapshot" do
    {:ok, pid} = Repo.start_link(database: ":memory:", name: nil, pool_size: 1, log: false)
    Process.unlink(pid)
    previous = Repo.put_dynamic_repo(pid)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GenServer.stop(pid)
    end)

    Repo.query!("CREATE TABLE probe (value TEXT)")
    Repo.query!("INSERT INTO probe VALUES ('recorded')")
    caller = self()

    old_read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)

        DashboardCache.json(Repo, :memory, fn ->
          old = payload()
          send(caller, {:memory_projection, self()})
          receive do: (:continue -> old)
        end)
      end)

    assert_receive {:memory_projection, worker}
    release = release_on_exit(worker)
    Repo.query!("UPDATE probe SET value = 'acknowledged'")

    new_read =
      Task.async(fn ->
        Repo.put_dynamic_repo(pid)
        DashboardCache.json(Repo, :memory, &payload/0)
      end)

    assert {:ok, fresh, _etag} = Task.await(new_read)
    release.()
    assert Jason.decode!(fresh)["decision"] == "acknowledged"
    assert {:ok, _old, _etag} = Task.await(old_read)
  end
end
