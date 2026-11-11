defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCache do
  @moduledoc false
  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, OperatorConfig, Repo}

  @ttl_ms 15_000
  @refresh_interval_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec json(module(), term(), (-> term())) :: {:ok, binary(), binary()} | {:error, term()}
  def json(Repo, surface, fun) do
    source = Repo.get_dynamic_repo()
    source = if is_atom(source), do: Process.whereis(source), else: source

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:json, source, surface, fun}, :infinity)
    else
      encode(fun.())
    end
  end

  def json(_repo, _surface, fun), do: encode(fun.())

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
       epoch: 0,
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
      version = cache_version(connection) || make_ref()
      key = {source, surface}
      state = remember_builder(state, key, source, fun, connection)
      now = state.clock.()

      case Map.get(state.entries, key) do
        {^version, expires, result} when not is_nil(version) and expires > now ->
          {:reply, result, state}

        {^version, _expires, result} when not is_nil(version) ->
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
    state = refresh(state, key, version, source, fun)
    {_pid, ref, _epoch, _monitor} = Map.fetch!(state.refreshing, {key, version})
    waiters = Map.update(state.waiters, ref, [from], &[from | &1])
    {:noreply, %{state | waiters: waiters}}
  end

  defp remember_builder(state, _key, _source, _fun, nil), do: state

  defp remember_builder(state, key, source, fun, _connection),
    do: %{state | builders: Map.put(state.builders, key, {source, fun})}

  defp refresh(state, key, version, source, fun) do
    if Map.has_key?(state.refreshing, {key, version}), do: state, else: start_refresh(state, key, version, source, fun)
  end

  defp start_refresh(state, key, version, source, fun) do
    owner = self()
    ref = make_ref()
    database = Map.get(state.databases, source)

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        Process.flag(:priority, :low)
        send(owner, {:refreshed, key, ref, version, build_on_ledger(source, database, fun)})
      end)

    %{state | refreshing: Map.put(state.refreshing, {key, version}, {pid, ref, state.epoch, Process.monitor(pid)})}
  end

  defp build_on_ledger(source, nil, fun) do
    Repo.put_dynamic_repo(source)
    build(fun)
  end

  defp build_on_ledger(_source, database, fun) do
    # Projection snapshots may hold a checkout while doing CPU work. Give each
    # file-backed build its own connection so it cannot exhaust the write pool.
    {:ok, reader} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
    Repo.put_dynamic_repo(reader)

    try do
      build(fun)
    after
      GenServer.stop(reader)
    end
  end

  defp build(fun) do
    encode(HerdrCore.with_cached_reads(fun))
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  @impl true
  def handle_info(:operator_dashboard_changed, state) do
    {:noreply, refresh_registered(%{state | epoch: state.epoch + 1}, true)}
  end

  def handle_info(:refresh_tick, state) do
    Process.send_after(self(), :refresh_tick, @refresh_interval_ms)
    {:noreply, refresh_registered(state, false)}
  end

  def handle_info({:refreshed, {source, _surface} = key, ref, version, result}, state) do
    job_key = {key, version}

    case Map.get(state.refreshing, job_key) do
      {_pid, ^ref, epoch, monitor} ->
        Process.demonitor(monitor, [:flush])
        entries = refreshed_entries(state, source, key, version, result)
        state = reply_waiters(state, ref, result)
        state = %{state | entries: entries, refreshing: Map.delete(state.refreshing, job_key)}
        # Publish completed snapshots for liveness, then catch up if a signal
        # arrived while building. Continuous signals must not starve readers.
        state = if epoch != state.epoch, do: refresh_key(state, key), else: state
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

  defp refreshed_entries(state, source, key, version, result) do
    # Never label a snapshot with a newer commit that raced its construction.
    if version != nil and match?({:ok, _, _}, result) and cache_version(Map.get(state.sources, source)) == version do
      entry = {version, state.clock.() + @ttl_ms, result}

      case Map.get(state.entries, key) do
        {_old_version, _expires, {:ok, _body, etag}} when elem(result, 2) != etag ->
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

  defp refresh_registered(state, force?) do
    versions = Map.new(state.sources, fn {source, connection} -> {source, cache_version(connection)} end)
    now = state.clock.()

    Enum.reduce(state.builders, state, fn {key, {source, fun}}, state ->
      version = Map.get(versions, source)

      current? =
        case Map.get(state.entries, key) do
          {^version, expires, _result} when expires > now -> true
          _stale -> false
        end

      if version != nil and (force? or not current?),
        do: refresh(state, key, version, source, fun),
        else: state
    end)
  end

  defp refresh_key(state, {source, _surface} = key) do
    with {^source, fun} <- Map.get(state.builders, key),
         version when not is_nil(version) <- cache_version(Map.get(state.sources, source)) do
      refresh(state, key, version, source, fun)
    else
      _closed -> state
    end
  end

  defp cache_version(connection) do
    case data_version(connection) do
      nil -> nil
      version -> {version, OperatorConfig.load()}
    end
  end

  defp connection(source, state) do
    case Map.fetch(state.sources, source) do
      {:ok, connection} -> {connection, state}
      :error -> open_connection(source, state)
    end
  end

  defp open_connection(source, state) do
    # A dedicated read-only connection observes commits by *every* writer,
    # including other factory processes. data_version is connection-local;
    # querying it through the Ecto pool would not be a valid cache token.
    with {:ok, %{rows: rows}} <- Repo.query("PRAGMA database_list"),
         [_, "main", path] when path != "" <- Enum.find(rows, &(Enum.at(&1, 1) == "main")),
         {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
      if is_pid(source), do: Process.monitor(source)
      {connection, %{state | sources: Map.put(state.sources, source, connection), databases: Map.put(state.databases, source, path)}}
    else
      _unavailable -> {nil, state}
    end
  end

  defp data_version(nil), do: nil

  defp data_version(connection) do
    case Sqlite3.prepare(connection, "PRAGMA data_version") do
      {:ok, statement} ->
        try do
          case Sqlite3.step(connection, statement) do
            {:row, [version]} -> version
            _unavailable -> nil
          end
        after
          Sqlite3.release(connection, statement)
        end

      _unavailable ->
        nil
    end
  end

  defp encode({:ok, payload}) do
    body = Jason.encode!(payload)
    # generated_at describes the snapshot, not a board change.
    digest = :crypto.hash(:sha256, Jason.encode!(Map.delete(payload, :generated_at))) |> Base.encode16(case: :lower)
    {:ok, body, "\"#{digest}\""}
  end

  defp encode(error), do: error
end
