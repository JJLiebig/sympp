defmodule SymphonyElixir.SymphonyPlusPlus.DashboardCache do
  @moduledoc false
  use GenServer

  require Logger

  alias Exqlite.Sqlite3
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Inputs
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, DeploymentObservation, HerdrCore}
  alias SymphonyElixir.SymphonyPlusPlus.{OperatorConfig, Repo}

  @refresh_interval_ms 250
  @read_budget_ms 2_000
  @max_retry_delay_ms 30_000
  @deadline_key {__MODULE__, :deadline}
  @snapshots __MODULE__

  @type projection :: (-> {:ok, map()} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec json(module(), atom(), projection()) :: {:ok | :stale, binary(), binary()} | {:error, term()} | :building
  def json(Repo, surface, fun) do
    if server = Process.whereis(__MODULE__) do
      read_with_budget(server, source(), surface, fun)
    else
      project(surface, fun)
    end
  end

  def json(_repo, surface, fun), do: project(surface, fun)

  defp read_with_budget(server, source, surface, fun) do
    GenServer.call(server, {:json, source, surface, fun}, @read_budget_ms)
  catch
    # Revision probes also touch SQLite. A stalled probe must not hold HTTP
    # readers hostage to the cache process or stop them getting a snapshot.
    :exit, {:timeout, _call} -> available({source, surface})
  end

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
  @spec inputs_changed() :: :ok
  def inputs_changed, do: GenServer.cast(__MODULE__, :inputs_changed)

  @doc false
  @spec deployment_ready(:ets.table(), term(), term()) :: :ok
  def deployment_ready(table, slot, value), do: GenServer.cast(__MODULE__, {:deployment_ready, table, slot, value})

  @impl true
  def init(_opts) do
    :ok = DashboardPubSub.subscribe()
    Inputs.init()
    :ets.new(@snapshots, [:named_table, :protected, read_concurrency: true])

    {:ok,
     %{
       sources: %{},
       entries: %{},
       watches: %{},
       refreshing: %{},
       failures: %{},
       deployment_publication: nil,
       timer: nil,
       refresh_pending?: false,
       clock: fn -> System.monotonic_time(:millisecond) end
     }}
  end

  @impl true
  def handle_call({:json, source, surface, fun}, from, state) do
    check_inputs(fn -> read_json(source, surface, fun, from, state) end)
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

  defp read_json(source, surface, fun, from, state) do
    {connection, state} = connection(source, state)
    revision = probe(connection, [surface])
    key = {source, surface}
    entry = Map.get(state.entries, key)
    generation = generation(revision, surface)

    cond do
      current?(state, entry, generation) ->
        {:reply, entry.response, state}

      connection != nil and generation == nil ->
        {:reply, pending_response(state, key), state}

      true ->
        # Unversioned reads cannot join a projection that might predate their write.
        {job_key, _config} = request = build_request(key, generation || make_ref())
        state = ensure_refresh(state, request, fun)

        case {pending_response(state, key), Map.get(state.refreshing, job_key)} do
          {{:error, _reason} = error, _job} ->
            {:reply, error, state}

          {_pending, %{read_timer: timer}} when is_reference(timer) ->
            {:noreply, update_in(state.refreshing[job_key].waiters, &[from | &1])}

          {pending, _busy} ->
            {:reply, pending, state}
        end
    end
  end

  defp add_reader(watches, key, projection, ref, pid) do
    target = if projection == :revision, do: {:revision, nil, MapSet.new()}, else: projection
    {target, readers} = Map.get(watches, key, {target, %{}})

    # A notification client may have read its detail before connecting. When a
    # revision is already known, wake the new reader as well as tracking it.
    if match?({:revision, generation, _stale} when not is_nil(generation), target), do: notify_readers(%{ref => pid})
    Map.put(watches, key, {target, Map.put(readers, ref, pid)})
  end

  defp ensure_refresh(state, {{key, generation, _revision}, _config} = request, fun) do
    if is_reference(generation) or (not refreshing?(state, key) and retry_due?(state, key)) do
      start_refresh(state, request, fun)
    else
      state
    end
  end

  defp refreshing?(state, key), do: Enum.any?(state.refreshing, fn {{active_key, _, _}, _job} -> active_key == key end)

  defp retry_due?(state, key) do
    case Map.get(state.failures, key) do
      {retry_at, _delay, _error} -> state.clock.() >= retry_at
      nil -> true
    end
  end

  defp build_request({_source, :archived} = key, generation), do: {{key, generation, nil}, nil}

  defp build_request(key, generation) do
    # The key and projection must use the same config, even if the file is
    # edited and restored while the worker is waiting to read the ledger.
    config = OperatorConfig.load()
    {{key, generation, OperatorConfig.board_revision()}, config}
  end

  defp start_refresh(state, {{{source, surface}, _generation, _revision} = job_key, config}, fun) do
    owner = self()
    sequence = System.unique_integer([:positive, :monotonic])
    database = get_in(state.sources, [source, :database])

    project = fn ->
      OperatorConfig.use_board_snapshot(config)
      fun.()
    end

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        Process.flag(:priority, :low)
        send(owner, {:refreshed, job_key, sequence, build_on_ledger(source, database, surface, project)})
      end)

    timer = Process.send_after(self(), {:read_budget_elapsed, job_key, sequence}, @read_budget_ms)
    job = %{pid: pid, sequence: sequence, monitor: Process.monitor(pid), read_timer: timer, waiters: []}
    put_in(state.refreshing[job_key], job)
  end

  defp build_on_ledger(source, nil, surface, fun) do
    Repo.put_dynamic_repo(source)
    build(nil, surface, fun)
  end

  defp build_on_ledger(source, database, surface, fun) do
    # SQLite snapshots span the whole projection. A dedicated reader can finish
    # even when storage is slow, without holding a connection in the write pool.
    {:ok, reader} = Repo.start_link(database: database, name: nil, pool_size: 1, timeout: :infinity, log: false)
    Repo.put_dynamic_repo(reader)

    try do
      build(source, surface, fun)
    after
      GenServer.stop(reader)
    end
  end

  defp build(source, surface, fun) do
    Process.put(@deadline_key, {:infinity, false})
    {response, inputs} = Inputs.capture(source, surface, fn -> project(surface, fun) end)
    {response, Process.get(@deadline_key), inputs}
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      reason =
        if String.contains?(String.downcase(message), ["busy", "locked"]),
          do: :database_busy,
          else: {:storage_failed, message}

      {{:error, reason}, {:infinity, false}, %{}}
  end

  defp project(surface, fun) do
    Logger.debug("board_build surface=#{surface}")
    encode(fun.(), surface)
  end

  @impl true
  def handle_cast({:unwatch, ref}, state), do: {:noreply, remove_watch(state, ref)}
  def handle_cast(:inputs_changed, state), do: {:noreply, queue_refresh(state)}

  def handle_cast({:deployment_ready, table, slot, value}, state) do
    {token, ready} = state.deployment_publication || schedule_deployment_publication()
    {:noreply, %{state | deployment_publication: {token, Map.put(ready, {table, slot}, value)}}}
  end

  defp schedule_deployment_publication do
    token = make_ref()
    Process.send_after(self(), {:publish_deployments, token}, @refresh_interval_ms)
    {token, %{}}
  end

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

  def handle_info({:publish_deployments, token}, %{deployment_publication: {token, ready}} = state) do
    DeploymentObservation.publish(ready)
    {:noreply, %{state | deployment_publication: nil}}
  end

  def handle_info({:publish_deployments, _stale}, state), do: {:noreply, state}

  def handle_info({:read_budget_elapsed, {key, _, _} = job_key, sequence}, state) do
    case Map.get(state.refreshing, job_key) do
      %{sequence: ^sequence} = job ->
        reply_waiters(job, available(key))
        {:noreply, put_in(state.refreshing[job_key], %{job | read_timer: nil, waiters: []})}

      _superseded ->
        {:noreply, state}
    end
  end

  def handle_info({:refreshed, {key, generation, _config} = job_key, sequence, {response, deadlines, inputs}}, state) do
    case Map.get(state.refreshing, job_key) do
      %{sequence: ^sequence} = job ->
        state = remove_job(state, job_key, job)

        case response do
          {:ok, _body, _etag} ->
            reply_waiters(job, response)

            entry = %{
              generation: generation,
              sequence: sequence,
              response: response,
              deadlines: deadlines,
              inputs: inputs
            }

            state = update_in(state.failures, &Map.delete(&1, key))
            {:noreply, finish_refresh(state, key, entry, is_nil(job.read_timer))}

          {:error, _reason} ->
            {:noreply, finish_failure(state, job_key, job, response)}
        end

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

  defp finish_refresh(state, {source, surface} = key, entry, slow?) do
    case Map.get(state.watches, key) do
      {fun, _readers} when is_function(fun, 0) ->
        revision = probe(get_in(state.sources, [source, :connection]), [surface])
        latest = generation(revision, surface)

        check_inputs(fn -> finish_watched(state, key, entry, latest, fun, slow?) end)

      _no_projection_watch ->
        # A later GET rechecks this build's generation. Once demand ends,
        # completing a build requires neither a version check nor a retry.
        install(state, key, entry)
    end
  end

  defp finish_watched(state, key, entry, latest, fun, slow?) do
    state =
      if entry.generation == latest and Inputs.current?(entry.inputs) do
        install(state, key, entry)
      else
        # A first or slow snapshot is still useful if inputs moved during its
        # build. Keep it available while readers wait for the newer revision.
        state = if slow? or not Map.has_key?(state.entries, key), do: install(state, key, entry), else: state
        refresh_if_stale(state, key, latest, fun)
      end

    schedule(state)
  end

  defp install(state, key, %{response: {:ok, _body, etag}, generation: generation} = entry) when not is_reference(generation) do
    :ets.insert(@snapshots, {key, entry.response})

    case Map.get(state.entries, key) do
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
      Enum.split_with(state.refreshing, fn {{{owner, _surface}, _generation, _config}, _job} -> owner == source end)

    Enum.each(owned, fn {_key, job} ->
      Process.exit(job.pid, :shutdown)
      release_job(job)
      reply_waiters(job, {:error, {:storage_failed, "Dashboard ledger closed"}})
    end)

    Inputs.forget_ledger(source)
    :ets.match_delete(@snapshots, {{source, :_}, :_})

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
        failures: Map.reject(state.failures, fn {{owner, _surface}, _failure} -> owner == source end),
        watches: Map.new(watches)
    })
  end

  defp failed_refresh(state, monitor) do
    case Enum.find(state.refreshing, fn {_key, job} -> job.monitor == monitor end) do
      {key, job} ->
        state = remove_job(state, key, job)
        finish_failure(state, key, job, {:error, {:storage_failed, "Dashboard refresh interrupted"}})

      nil ->
        state
    end
  end

  defp finish_failure(state, {_key, generation, _config}, job, error) when is_reference(generation) do
    reply_waiters(job, error)
    state
  end

  defp finish_failure(state, {{_source, surface} = key, _generation, _config}, job, error) do
    Logger.warning("board_refresh_failed surface=#{surface}")
    error = if error == {:error, :database_busy}, do: error, else: {:error, {:storage_failed, :dashboard_build_failed}}
    response = available(key, error)
    reply_waiters(job, response)
    previous = Map.get(state.failures, key)

    if response == error and not match?({_deadline, _delay, ^error}, previous) do
      notify_projection_readers(Map.get(state.watches, key))
    end

    # Retry only on reader demand. Give a failing surface progressively more
    # time to recover so other reads and watch ticks cannot restart it in a loop.
    delay =
      case previous do
        {_, previous, _error} -> min(2 * previous, @max_retry_delay_ms)
        nil -> @read_budget_ms
      end

    put_in(state.failures[key], {state.clock.() + delay, delay, error})
  end

  defp pending_response(state, key) do
    case Map.get(state.failures, key) do
      {_retry_at, _delay, error} -> available(key, error)
      nil -> available(key)
    end
  end

  defp available(key, fallback \\ :building) do
    case :ets.lookup(@snapshots, key) do
      [{^key, {:ok, body, etag}}] -> {:stale, body, etag}
      [] -> fallback
    end
  rescue
    ArgumentError -> fallback
  end

  defp remove_job(state, job_key, job) do
    release_job(job)
    %{state | refreshing: Map.delete(state.refreshing, job_key)}
  end

  defp release_job(job) do
    Process.demonitor(job.monitor, [:flush])
    if job.read_timer, do: Process.cancel_timer(job.read_timer)
  end

  defp reply_waiters(job, result), do: Enum.each(job.waiters, &GenServer.reply(&1, result))

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
    check_inputs(fn -> refresh_watched_inputs(state) end)
  end

  defp check_inputs(fun), do: Inputs.check(fn -> DeploymentObservation.refresh_after(fun) end)

  defp refresh_watched_inputs(state) do
    state.watches
    |> Enum.group_by(fn {{source, _surface}, _watch} -> source end)
    |> Enum.reduce(state, fn {source, watches}, state ->
      surfaces = Enum.map(watches, fn {{_source, surface}, _watch} -> surface end)
      revision = probe(get_in(state.sources, [source, :connection]), surfaces)

      Enum.reduce(watches, state, fn {{_source, surface} = key, watch}, state ->
        refresh_watch(state, key, watch, generation(revision, surface))
      end)
    end)
    |> schedule()
  end

  defp refresh_watch(state, key, {{:revision, previous, notified}, readers}, generation) when not is_nil(generation) do
    revision = {generation, OperatorConfig.board_revision()}
    stale = stale_notification_entries(state, key)

    if revision != previous or not MapSet.subset?(stale, notified) do
      notify_readers(readers)
    end

    put_in(state.watches[key], {{:revision, revision, stale}, readers})
  end

  defp refresh_watch(state, key, {fun, _readers}, generation), do: refresh_if_stale(state, key, generation, fun)

  defp stale_notification_entries(state, {source, watch}) do
    # An events client that reads the board keeps the inputs of its last
    # response watched. A request inspector never schedules board work.
    for surface <- notification_surfaces(watch),
        entry = Map.get(state.entries, {source, surface}),
        entry != nil and not current?(state, entry, entry.generation),
        into: MapSet.new(),
        do: {surface, entry.sequence}
  end

  defp notification_surfaces(:herdr_events), do: [:herdr]
  defp notification_surfaces(:operator_events), do: [:priority, :deferred, :hydrated, :archived]
  defp notification_surfaces(_detail), do: []

  defp refresh_if_stale(state, _key, nil, _fun), do: state

  defp refresh_if_stale(state, key, generation, fun) do
    if current?(state, Map.get(state.entries, key), generation) or refreshing?(state, key) or not retry_due?(state, key) do
      state
    else
      start_refresh(state, build_request(key, generation), fun)
    end
  end

  defp current?(state, %{generation: generation, deadlines: {expires, _core?}, inputs: inputs}, generation) do
    expires > state.clock.() and Inputs.current?(inputs)
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

  defp generation(nil, _surface), do: nil
  defp generation({:revisions, [priority, _, _, _, _, _]}, :priority), do: {:revision, priority}
  defp generation({:revisions, [_, archived, _, _, _, _]}, :archived), do: {:revision, archived}
  defp generation({:revisions, [_, _, live, _, _, _]}, :hydrated), do: {:revision, live}
  defp generation({:revisions, [_, _, _, native, _, _]}, :herdr), do: {:revision, native}
  defp generation({:revisions, [_, _, _, _, deferred, _]}, :deferred), do: {:revision, deferred}
  defp generation({:revisions, [_, _, _, _, _, detail]}, _surface), do: {:revision, detail}
  defp generation({:data_version, _version} = revision, _surface), do: revision

  defp probe(nil, _surfaces), do: nil

  defp probe(connection, surfaces) do
    Logger.debug("board_revision_probe surface=#{surfaces |> Enum.sort() |> Enum.join(",")}")

    case query_row(connection, "SELECT priority, archived, live, native, deferred, detail FROM sympp_dashboard_revisions") do
      [_, _, _, _, _, _] = revisions -> {:revisions, revisions}
      _unavailable -> data_version(connection)
    end
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
    content = payload |> Map.drop([:generated_at, :etag]) |> DeploymentObservation.change_identity() |> Jason.encode!()
    digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    etag = "\"#{digest}\""
    body = if surface == :herdr, do: Map.put(payload, :etag, etag), else: payload
    {:ok, Jason.encode!(body), etag}
  end

  defp encode(error, _surface), do: error
end
