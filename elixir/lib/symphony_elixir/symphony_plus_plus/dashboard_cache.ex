defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCache do
  @moduledoc false
  use GenServer

  require Logger

  alias Exqlite.Sqlite3
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, OperatorConfig, Repo}

  @refresh_interval_ms 250
  @deadline_key {__MODULE__, :deadline}

  @type projection :: (-> {:ok, map()} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec json(module(), atom(), projection()) :: {:ok, binary(), binary()} | {:error, term()}
  def json(Repo, surface, fun) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:json, source(), surface, fun}, :infinity)
    else
      project(surface, fun)
    end
  end

  def json(_repo, surface, fun), do: project(surface, fun)

  @doc false
  @spec watch(module(), [{atom(), projection() | :revision}]) :: {:ok, pid(), reference()} | :unversioned
  def watch(Repo, projections) do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, ref} <- GenServer.call(pid, {:watch, source(), projections}, :infinity) do
      {:ok, pid, ref}
    else
      _unversioned -> :unversioned
    end
  end

  def watch(_repo, _projections), do: :unversioned

  @doc false
  @spec unwatch(pid(), reference()) :: :ok
  def unwatch(server, ref), do: GenServer.cast(server, {:unwatch, ref})

  @doc false
  @spec expire_at(DateTime.t() | integer()) :: :ok
  def expire_at(deadline) do
    case Process.get(@deadline_key) do
      {expires, core?} -> Process.put(@deadline_key, {min(expires, monotonic_deadline(deadline)), core?})
      nil -> :ok
    end

    :ok
  end

  @doc false
  @spec track_core_expiry() :: :ok
  def track_core_expiry do
    case Process.get(@deadline_key) do
      {expires, false} -> Process.put(@deadline_key, {expires, true})
      _other -> :ok
    end

    :ok
  end

  defp monotonic_deadline(%DateTime{} = deadline) do
    remaining = DateTime.to_unix(deadline, :microsecond) - System.system_time(:microsecond)
    System.convert_time_unit(System.monotonic_time(:microsecond) + remaining + 999, :microsecond, :millisecond)
  end

  defp monotonic_deadline(deadline), do: deadline

  defp source do
    case Repo.get_dynamic_repo() do
      name when is_atom(name) -> Process.whereis(name)
      source -> source
    end
  end

  @doc false
  @spec invalidate([atom()]) :: :ok
  def invalidate(surfaces), do: GenServer.cast(__MODULE__, {:invalidate, surfaces})

  @impl true
  def init(_opts) do
    :ok = DashboardPubSub.subscribe()

    {:ok,
     %{
       sources: %{},
       entries: %{},
       watches: %{},
       refreshing: %{},
       epochs: %{},
       config_revision: {nil, nil},
       timer: nil,
       refresh_pending?: false,
       clock: fn -> System.monotonic_time(:millisecond) end
     }}
  end

  @impl true
  def handle_call({:json, source, surface, fun}, from, state) do
    {connection, state} = connection(source, state)
    {revision, state} = probe(state, connection, [surface])
    # Unversioned reads cannot join a projection that might predate their write.
    generation = generation(state, revision, surface) || make_ref()
    key = {source, surface}
    entry = Map.get(state.entries, key)

    if current?(state, entry, generation) do
      {:reply, entry.response, state}
    else
      job_key = {key, generation}
      state = ensure_refresh(state, job_key, fun)
      {:noreply, update_in(state.refreshing[job_key].waiters, &[from | &1])}
    end
  end

  def handle_call({:watch, source, projections}, {pid, _tag}, state) do
    {connection, state} = connection(source, state)

    if connection do
      ref = Process.monitor(pid)

      watches =
        Enum.reduce(projections, state.watches, fn {surface, fun}, watches ->
          add_reader(watches, {source, surface}, fun, ref, pid)
        end)

      # Register the stream before checking any revision, including if an
      # on-demand build for this surface is already in flight.
      {:reply, {:ok, ref}, queue_refresh(%{state | watches: watches})}
    else
      {:reply, :unversioned, state}
    end
  end

  defp add_reader(watches, key, projection, ref, pid) do
    target = if projection == :revision, do: {:revision, nil}, else: projection
    {target, readers} = Map.get(watches, key, {target, %{}})

    # A notification client may have read its detail before connecting. When a
    # revision is already known, wake the new reader as well as tracking it.
    if match?({:revision, generation} when not is_nil(generation), target), do: notify_readers(%{ref => pid})
    Map.put(watches, key, {target, Map.put(readers, ref, pid)})
  end

  defp ensure_refresh(state, job_key, fun) do
    if Map.has_key?(state.refreshing, job_key), do: state, else: start_refresh(state, job_key, fun)
  end

  defp start_refresh(state, {{source, surface}, _generation} = job_key, fun) do
    owner = self()
    sequence = System.unique_integer([:positive, :monotonic])
    database = get_in(state.sources, [source, :database])

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        Process.flag(:priority, :low)
        send(owner, {:refreshed, job_key, sequence, build_on_ledger(source, database, surface, fun)})
      end)

    job = %{pid: pid, sequence: sequence, monitor: Process.monitor(pid), waiters: []}
    put_in(state.refreshing[job_key], job)
  end

  defp build_on_ledger(source, nil, surface, fun) do
    Repo.put_dynamic_repo(source)
    build(surface, fun)
  end

  defp build_on_ledger(_source, database, surface, fun) do
    # Projection snapshots may hold a checkout while doing CPU work. Give each
    # file-backed build its own connection so it cannot exhaust the write pool.
    {:ok, reader} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
    Repo.put_dynamic_repo(reader)

    try do
      build(surface, fun)
    after
      GenServer.stop(reader)
    end
  end

  defp build(surface, fun) do
    Process.put(@deadline_key, {:infinity, false})
    response = HerdrCore.with_cached_reads(fn -> project(surface, fun) end)
    {response, Process.get(@deadline_key)}
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      reason =
        if String.contains?(String.downcase(message), ["busy", "locked"]),
          do: :database_busy,
          else: {:storage_failed, message}

      {{:error, reason}, {:infinity, false}}
  end

  defp project(surface, fun) do
    Logger.debug("board_build surface=#{surface}")
    encode(fun.(), surface)
  end

  @impl true
  def handle_cast({:invalidate, surfaces}, state) do
    epochs = Enum.reduce(surfaces, state.epochs, &Map.update(&2, &1, 1, fn epoch -> epoch + 1 end))
    {:noreply, queue_refresh(%{state | epochs: epochs})}
  end

  def handle_cast({:unwatch, ref}, state), do: {:noreply, remove_watch(state, ref)}

  @impl true
  def handle_info(:operator_dashboard_changed, state) do
    {:noreply, queue_refresh(state)}
  end

  def handle_info({:refresh_tick, token}, %{timer: {_, _, token}} = state) do
    {:noreply, refresh_watched(%{state | timer: nil})}
  end

  def handle_info({:refresh_tick, _stale}, state), do: {:noreply, state}

  def handle_info(:refresh_watched, state) do
    {:noreply, refresh_watched(%{state | refresh_pending?: false})}
  end

  def handle_info({:refreshed, {key, generation} = job_key, sequence, {response, deadlines}}, state) do
    case Map.get(state.refreshing, job_key) do
      %{sequence: ^sequence} = job ->
        reply_waiters(job, response)
        state = %{state | refreshing: Map.delete(state.refreshing, job_key)}
        entry = %{generation: generation, sequence: sequence, response: response, deadlines: deadlines}
        {:noreply, finish_refresh(state, key, entry)}

      _superseded ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if get_in(state.sources, [pid, :monitor]) == ref do
      {:noreply, close_source(state, pid)}
    else
      {:noreply, state |> failed_refresh(ref) |> remove_watch(ref)}
    end
  end

  defp finish_refresh(state, {source, surface} = key, entry) do
    case Map.get(state.watches, key) do
      {fun, _readers} when is_function(fun, 0) ->
        {revision, state} = probe(state, get_in(state.sources, [source, :connection]), [surface])
        latest = generation(state, revision, surface)

        state =
          if entry.generation == latest do
            install(state, key, entry)
          else
            refresh_if_stale(state, key, latest, fun)
          end

        schedule(state)

      _no_projection_watch ->
        # A later GET rechecks this build's generation. Once demand ends,
        # completing a build requires neither a version check nor a retry.
        install(state, key, entry)
    end
  end

  defp install(state, key, %{response: {:ok, _body, etag}, generation: generation} = entry) when not is_reference(generation) do
    case Map.get(state.entries, key) do
      %{sequence: sequence} when sequence > entry.sequence ->
        state

      %{response: {:ok, _body, ^etag}} ->
        put_in(state.entries[key], entry)

      _changed ->
        state = put_in(state.entries[key], entry)
        DashboardPubSub.broadcast_refreshed()
        notify_projection_readers(Map.get(state.watches, key))
        state
    end
  end

  defp install(state, _key, _entry), do: state

  defp notify_projection_readers({fun, readers}) when is_function(fun, 0), do: notify_readers(readers)
  defp notify_projection_readers(_other), do: :ok

  defp notify_readers(readers) do
    version = System.unique_integer([:positive, :monotonic])
    Enum.each(readers, fn {ref, pid} -> send(pid, {:dashboard_changed, ref, version}) end)
  end

  defp close_source(state, source) do
    Sqlite3.close(get_in(state.sources, [source, :connection]))

    {owned, other} =
      Enum.split_with(state.refreshing, fn {{{owner, _surface}, _generation}, _job} -> owner == source end)

    Enum.each(owned, fn {_key, job} ->
      Process.exit(job.pid, :shutdown)
      reply_waiters(job, {:error, {:storage_failed, "Dashboard ledger closed"}})
    end)

    {closed, watches} = Enum.split_with(state.watches, fn {{owner, _surface}, _watch} -> owner == source end)

    Enum.each(closed, fn {_key, {_fun, readers}} ->
      Enum.each(readers, fn {ref, pid} ->
        Process.demonitor(ref, [:flush])
        send(pid, {:dashboard_source_closed, ref})
      end)
    end)

    schedule(%{
      state
      | sources: Map.delete(state.sources, source),
        entries: Map.reject(state.entries, fn {{owner, _surface}, _entry} -> owner == source end),
        refreshing: Map.new(other),
        watches: Map.new(watches)
    })
  end

  defp failed_refresh(state, monitor) do
    case Enum.find(state.refreshing, fn {_key, job} -> job.monitor == monitor end) do
      {key, job} ->
        reply_waiters(job, {:error, {:storage_failed, "Dashboard refresh interrupted"}})
        %{state | refreshing: Map.delete(state.refreshing, key)}

      nil ->
        state
    end
  end

  defp reply_waiters(job, result) do
    Process.demonitor(job.monitor, [:flush])
    Enum.each(job.waiters, &GenServer.reply(&1, result))
  end

  defp remove_watch(state, ref) do
    Process.demonitor(ref, [:flush])

    watches =
      Map.new(state.watches, fn {key, {fun, readers}} -> {key, {fun, Map.delete(readers, ref)}} end)
      |> Map.reject(fn {_key, {_fun, readers}} -> map_size(readers) == 0 end)

    schedule(%{state | watches: watches})
  end

  defp queue_refresh(%{refresh_pending?: true} = state), do: state
  defp queue_refresh(%{watches: watches} = state) when map_size(watches) == 0, do: state

  defp queue_refresh(state) do
    send(self(), :refresh_watched)
    %{state | refresh_pending?: true}
  end

  defp refresh_watched(state) do
    state.watches
    |> Enum.group_by(fn {{source, _surface}, _watch} -> source end)
    |> Enum.reduce(state, fn {source, watches}, state ->
      surfaces = Enum.map(watches, fn {{_source, surface}, _watch} -> surface end)
      {revision, state} = probe(state, get_in(state.sources, [source, :connection]), surfaces)

      Enum.reduce(watches, state, fn {{_source, surface} = key, watch}, state ->
        refresh_watch(state, key, watch, generation(state, revision, surface))
      end)
    end)
    |> schedule()
  end

  defp refresh_watch(state, key, {{:revision, previous}, readers}, generation) do
    if generation != nil and generation != previous do
      notify_readers(readers)
      put_in(state.watches[key], {{:revision, generation}, readers})
    else
      state
    end
  end

  defp refresh_watch(state, key, {fun, _readers}, generation), do: refresh_if_stale(state, key, generation, fun)

  defp refresh_if_stale(state, _key, nil, _fun), do: state

  defp refresh_if_stale(state, key, generation, fun) do
    # Watchers need only the latest snapshot. GETs can still read a new
    # generation while an older build is held on a different connection.
    if current?(state, Map.get(state.entries, key), generation) or
         Enum.any?(state.refreshing, fn {{active_key, _generation}, _job} -> active_key == key end) do
      state
    else
      start_refresh(state, {key, generation}, fun)
    end
  end

  defp current?(state, %{generation: generation, deadlines: {_expires, core?}} = entry, generation) do
    if core?, do: HerdrCore.refresh_on_demand()
    now = state.clock.()
    expiry(entry, now) > now
  end

  defp current?(_state, _entry, _generation), do: false

  defp expiry(%{deadlines: {expires, true}}, now), do: min(expires, HerdrCore.last_good_deadline() || now)
  defp expiry(%{deadlines: {expires, false}}, _now), do: expires
  defp expiry(nil, _now), do: :infinity

  defp schedule(%{watches: watches} = state) when map_size(watches) == 0, do: cancel_timer(state)

  defp schedule(state) do
    now = state.clock.()

    next =
      Enum.reduce(state.watches, now + @refresh_interval_ms, fn
        {key, {fun, _readers}}, next when is_function(fun, 0) ->
          case expiry(Map.get(state.entries, key), now) do
            deadline when deadline > now -> min(next, deadline)
            _due -> next
          end

        _revision_watch, next ->
          next
      end)

    case state.timer do
      {scheduled, _ref, _token} when scheduled <= next ->
        state

      _later_or_missing ->
        state = cancel_timer(state)
        token = make_ref()
        ref = Process.send_after(self(), {:refresh_tick, token}, next - now)
        %{state | timer: {next, ref, token}}
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_scheduled, ref, _token}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp generation(_state, nil, _surface), do: nil

  defp generation(state, revision, surface) do
    {_stamp, config} = state.config_revision
    {surface_version(revision, surface, config), Map.get(state.epochs, surface, 0)}
  end

  defp surface_version({:revisions, [_priority, archived, _live, _native]}, :archived, _config), do: archived
  defp surface_version({:revisions, [priority, _archived, _live, _native]}, :priority, config), do: {priority, config}
  defp surface_version({:revisions, [_priority, _archived, live, _native]}, surface, config) when surface in [:deferred, :hydrated], do: {live, config}
  defp surface_version({:revisions, [_priority, _archived, _live, native]}, _surface, config), do: {native, config}
  defp surface_version({:data_version, version}, _surface, config), do: {version, config}

  defp probe(state, nil, _surfaces), do: {nil, state}

  defp probe(state, connection, surfaces) do
    Logger.debug("board_revision_probe surface=#{surfaces |> Enum.sort() |> Enum.join(",")}")

    revision =
      case query_row(connection, "SELECT priority, archived, live, native FROM sympp_dashboard_revisions") do
        [_, _, _, _] = revisions -> {:revisions, revisions}
        _unavailable -> data_version(connection)
      end

    config = if surfaces == [:archived], do: state.config_revision, else: OperatorConfig.revision(state.config_revision)
    {revision, %{state | config_revision: config}}
  end

  defp connection(source, state) do
    case Map.fetch(state.sources, source) do
      {:ok, %{connection: connection}} -> {connection, state}
      :error -> open_connection(source, state)
    end
  end

  defp open_connection(source, state) do
    # A dedicated reader observes committed versions from every writer,
    # including other factory processes, without using the write pool.
    previous = Repo.put_dynamic_repo(source)

    try do
      with {:ok, %{rows: rows}} <- Repo.query("PRAGMA database_list"),
           [_, "main", path] when path != "" <- Enum.find(rows, &(Enum.at(&1, 1) == "main")),
           {:ok, connection} <- Sqlite3.open(path, mode: :readonly) do
        monitor = if is_pid(source), do: Process.monitor(source)
        ledger = %{connection: connection, database: path, monitor: monitor}
        {connection, put_in(state.sources[source], ledger)}
      else
        _unavailable -> {nil, state}
      end
    after
      Repo.put_dynamic_repo(previous)
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
