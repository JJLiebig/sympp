defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCache do
  @moduledoc false
  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, OperatorConfig, Repo}

  # The ledger version doesn't cover run age, card expiry, or local repository
  # identity changes. A surface can recheck just its external inputs on expiry.
  @ttl_ms 15_000
  @refresh_interval_ms 250

  @type result :: {:ok, term()} | {:error, term()}
  @type projection :: (-> result()) | {(-> result()), (term() -> result())}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec json(module(), term(), projection()) :: {:ok, binary(), binary()} | {:error, term()}
  def json(Repo, surface, fun) do
    source = Repo.get_dynamic_repo()
    source = if is_atom(source), do: Process.whereis(source), else: source

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:json, source, surface, fun}, :infinity)
    else
      render(fun, nil, surface) |> elem(0)
    end
  end

  def json(_repo, surface, fun), do: render(fun, nil, surface) |> elem(0)

  @doc false
  @spec invalidate([atom()]) :: :ok
  def invalidate(surfaces), do: GenServer.cast(__MODULE__, {:invalidate, surfaces})

  @impl true
  def init(_opts) do
    :ok = DashboardPubSub.subscribe()
    Process.send_after(self(), :refresh_tick, @refresh_interval_ms)

    {:ok,
     %{
       sources: %{},
       databases: %{},
       entries: %{},
       builders: %{},
       refreshing: %{},
       waiters: %{},
       epochs: %{},
       refresh_pending?: false,
       clock: fn -> System.monotonic_time(:millisecond) end
     }}
  end

  @impl true
  def handle_call({:json, source, surface, fun}, from, state) do
    previous = Repo.put_dynamic_repo(source)

    try do
      {connection, state} = connection(source, state)
      # Without a file version (for example an in-memory ledger), reads must
      # build independently rather than join a snapshot predating their write.
      version = cache_version(connection, surface) || make_ref()
      key = {source, surface}
      state = remember_builder(state, key, source, fun, connection)
      now = state.clock.()
      epoch = epoch(state, key)

      case Map.get(state.entries, key) do
        {^version, ^epoch, expires, {result, _inputs}} when expires > now ->
          {:reply, result, state}

        {^version, _epoch, _expires, {result, _inputs}} ->
          # Ledger data is still current. Refresh time-derived observations
          # without making a quiet board's next poll rebuild the projection.
          {:reply, result, refresh(state, key, version, source, fun)}

        _missing ->
          cache_miss(state, key, version, source, fun, from)
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp cache_miss(state, key, version, source, fun, from) do
    state =
      if Map.has_key?(state.refreshing, {key, version}),
        do: state,
        else: start_refresh(state, key, version, source, fun)

    {_pid, ref, _epoch, _monitor} = Map.fetch!(state.refreshing, {key, version})
    waiters = Map.update(state.waiters, ref, [from], &[from | &1])
    {:noreply, %{state | waiters: waiters}}
  end

  defp remember_builder(state, _key, _source, _fun, nil), do: state

  defp remember_builder(state, key, source, fun, _connection),
    do: %{state | builders: Map.put(state.builders, key, {source, fun})}

  defp refresh(state, key, version, source, fun) do
    # Idle subscribers need only the latest state. Never accumulate builds for
    # intervening versions while a projection for this surface is still running.
    if Enum.any?(state.refreshing, fn {{active_key, _version}, _job} -> active_key == key end),
      do: state,
      else: start_refresh(state, key, version, source, fun)
  end

  defp start_refresh(state, {_source, surface} = key, version, source, fun) do
    owner = self()
    ref = make_ref()
    database = Map.get(state.databases, source)
    epoch = epoch(state, key)

    previous =
      case Map.get(state.entries, key) do
        {^version, ^epoch, _expires, snapshot} -> snapshot
        _changed -> nil
      end

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        Process.flag(:priority, :low)
        send(owner, {:refreshed, key, ref, version, build_on_ledger(source, database, fun, previous, surface)})
      end)

    %{state | refreshing: Map.put(state.refreshing, {key, version}, {pid, ref, epoch, Process.monitor(pid)})}
  end

  defp build_on_ledger(source, nil, fun, previous, surface) do
    Repo.put_dynamic_repo(source)
    build(fun, previous, surface)
  end

  defp build_on_ledger(_source, database, fun, previous, surface) do
    # Projection snapshots may hold a checkout while doing CPU work. Give each
    # file-backed build its own connection so it cannot exhaust the write pool.
    {:ok, reader} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
    Repo.put_dynamic_repo(reader)

    try do
      build(fun, previous, surface)
    after
      GenServer.stop(reader)
    end
  end

  defp build(fun, previous, surface) do
    HerdrCore.with_cached_reads(fn -> render(fun, previous, surface) end)
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {{:error, :database_busy}, nil},
        else: {{:error, {:storage_failed, message}}, nil}
  end

  defp render({read_inputs, project}, previous, surface) do
    case read_inputs.() do
      {:ok, inputs} ->
        case previous do
          {_result, ^inputs} -> previous
          _changed -> {encode(project.(inputs), surface), inputs}
        end

      {:error, _} = error ->
        {error, nil}
    end
  end

  defp render(project, _previous, surface), do: {encode(project.(), surface), nil}

  @impl true
  def handle_cast({:invalidate, surfaces}, state) do
    epochs = Enum.reduce(surfaces, state.epochs, &Map.update(&2, &1, 1, fn epoch -> epoch + 1 end))
    {:noreply, queue_refresh(%{state | epochs: epochs})}
  end

  @impl true
  def handle_info(:operator_dashboard_changed, state) do
    {:noreply, queue_refresh(state)}
  end

  def handle_info(:refresh_tick, state) do
    Process.send_after(self(), :refresh_tick, @refresh_interval_ms)
    {:noreply, refresh_registered(state)}
  end

  def handle_info(:refresh_registered, state) do
    {:noreply, refresh_registered(%{state | refresh_pending?: false})}
  end

  def handle_info({:refreshed, {source, surface} = key, ref, version, {result, _inputs} = snapshot}, state) do
    job_key = {key, version}

    case Map.get(state.refreshing, job_key) do
      {_pid, ^ref, epoch, monitor} ->
        Process.demonitor(monitor, [:flush])
        latest = cache_version(Map.get(state.sources, source), surface)
        entries = refreshed_entries(state, key, version == latest, {version, epoch}, snapshot)
        state = reply_waiters(state, ref, result)
        state = %{state | entries: entries, refreshing: Map.delete(state.refreshing, job_key)}
        # Publish completed snapshots for liveness, then catch up if a signal
        # arrived while building. Continuous signals must not starve readers.
        changed? = epoch != epoch(state, key) or latest != version
        state = if changed?, do: refresh_key(state, key, latest), else: state
        {:noreply, state}

      _superseded ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if Map.has_key?(state.sources, pid) do
      {:noreply, close_source(state, pid)}
    else
      {:noreply, failed_refresh(state, ref)}
    end
  end

  defp close_source(state, source) do
    Sqlite3.close(Map.get(state.sources, source))
    {owned, other} = Enum.split_with(state.refreshing, fn {{{owner, _surface}, _version}, _job} -> owner == source end)

    state =
      Enum.reduce(owned, state, fn {_key, {pid, ref, _epoch, monitor}}, state ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :shutdown)
        reply_waiters(state, ref, {:error, {:storage_failed, "Dashboard ledger closed"}})
      end)

    entries = Map.reject(state.entries, fn {{owner, _surface}, _entry} -> owner == source end)
    builders = Map.reject(state.builders, fn {{owner, _surface}, _builder} -> owner == source end)

    %{
      state
      | sources: Map.delete(state.sources, source),
        databases: Map.delete(state.databases, source),
        entries: entries,
        refreshing: Map.new(other),
        builders: builders
    }
  end

  defp failed_refresh(state, monitor) do
    case Enum.find(state.refreshing, fn {_key, {_pid, _ref, _epoch, ref}} -> ref == monitor end) do
      {key, {_pid, ref, _epoch, _monitor}} ->
        state = reply_waiters(state, ref, {:error, {:storage_failed, "Dashboard refresh interrupted"}})
        %{state | refreshing: Map.delete(state.refreshing, key)}

      nil ->
        state
    end
  end

  defp reply_waiters(state, ref, result) do
    {waiters, remaining} = Map.pop(state.waiters, ref, [])
    Enum.each(waiters, &GenServer.reply(&1, result))
    %{state | waiters: remaining}
  end

  defp refreshed_entries(state, key, current?, {version, epoch}, {result, _inputs} = snapshot) do
    # Never label a snapshot with a newer commit that raced its construction.
    if current? and match?({:ok, _, _}, result) do
      entry = {version, epoch, state.clock.() + @ttl_ms, snapshot}

      case Map.get(state.entries, key) do
        {_old_version, _epoch, _expires, {{:ok, _body, etag}, _inputs}} when elem(result, 2) != etag ->
          DashboardPubSub.broadcast_refreshed()
          Map.put(state.entries, key, entry)

        nil ->
          DashboardPubSub.broadcast_refreshed()
          Map.put(state.entries, key, entry)

        _unchanged ->
          Map.put(state.entries, key, entry)
      end
    else
      state.entries
    end
  end

  defp queue_refresh(%{refresh_pending?: true} = state), do: state

  defp queue_refresh(state) do
    send(self(), :refresh_registered)
    %{state | refresh_pending?: true}
  end

  defp refresh_registered(%{builders: builders} = state) when map_size(builders) == 0, do: state

  defp refresh_registered(state) do
    versions = Map.new(state.sources, fn {source, connection} -> {source, ledger_versions(connection)} end)
    config = OperatorConfig.revision()

    Enum.reduce(state.builders, state, fn {{source, surface} = key, _builder}, state ->
      version = surface_version(Map.get(versions, source), surface, config)
      refresh_key(state, key, version)
    end)
  end

  defp refresh_key(state, {source, _surface} = key, version) do
    with {^source, fun} <- Map.get(state.builders, key),
         false <- is_nil(version),
         false <- current?(state, key, version) do
      refresh(state, key, version, source, fun)
    else
      _closed -> state
    end
  end

  defp current?(state, key, version) do
    epoch = epoch(state, key)
    now = state.clock.()

    case Map.get(state.entries, key) do
      {^version, ^epoch, expires, _result} when expires > now -> true
      _stale -> false
    end
  end

  defp epoch(state, {_source, surface}), do: Map.get(state.epochs, surface, 0)

  defp cache_version(connection, surface) do
    surface_version(ledger_versions(connection), surface, OperatorConfig.revision())
  end

  defp surface_version(nil, _surface, _config), do: nil
  defp surface_version({:revisions, [_priority, archived, _live, _native]}, :archived, _config), do: archived
  defp surface_version({:revisions, [priority, _archived, _live, _native]}, :priority, config), do: {priority, config}
  defp surface_version({:revisions, [_priority, _archived, live, _native]}, surface, config) when surface in [:deferred, :hydrated], do: {live, config}
  defp surface_version({:revisions, [_priority, _archived, _live, native]}, _surface, config), do: {native, config}
  defp surface_version({:data_version, version}, _surface, config), do: {version, config}

  defp ledger_versions(nil), do: nil

  defp ledger_versions(connection) do
    case query_row(connection, "SELECT priority, archived, live, native FROM sympp_dashboard_revisions") do
      [_, _, _, _] = revisions -> {:revisions, revisions}
      _unavailable -> data_version(connection)
    end
  end

  defp connection(source, state) do
    case Map.fetch(state.sources, source) do
      {:ok, connection} -> {connection, state}
      :error -> open_connection(source, state)
    end
  end

  defp open_connection(source, state) do
    # A dedicated reader observes committed versions from every writer,
    # including other factory processes, without using the write pool.
    with {:ok, %{rows: rows}} <- Repo.query("PRAGMA database_list"),
         [_, "main", path] when path != "" <- Enum.find(rows, &(Enum.at(&1, 1) == "main")),
         {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      if is_pid(source), do: Process.monitor(source)
      {connection, %{state | sources: Map.put(state.sources, source, connection), databases: Map.put(state.databases, source, path)}}
    else
      _unavailable -> {nil, state}
    end
  end

  defp data_version(connection) do
    case query_row(connection, "PRAGMA data_version") do
      [version] -> {:data_version, version}
      _unavailable -> nil
    end
  end

  defp query_row(connection, sql) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        try do
          case Sqlite3.step(connection, statement) do
            {:row, row} -> row
            _unavailable -> nil
          end
        after
          Sqlite3.release(connection, statement)
        end

      _unavailable ->
        nil
    end
  end

  defp encode({:ok, payload}, surface) do
    # Snapshot metadata stays outside the digest. Herdr's fetch only exposes the body.
    content = payload |> Map.drop([:generated_at, :etag]) |> Jason.encode!()
    digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    etag = "\"#{digest}\""
    body = if surface == :herdr, do: Map.put(payload, :etag, etag), else: payload
    {:ok, Jason.encode!(body), etag}
  end

  defp encode(error, _surface), do: error
end
