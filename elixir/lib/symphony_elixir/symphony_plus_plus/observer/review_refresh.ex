defmodule SymphonyElixir.SymphonyPlusPlus.Observer.ReviewRefresh do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.{Observer, OfflineSandbox, Repo, ReviewStatus}
  @board_wait_ms 2_000
  @standalone_refresh_ms 60_000
  @review_concurrency 4
  @review_timeout_ms ReviewStatus.timeout_ms() + 1_000
  @pubsub SymphonyElixir.PubSub
  @topic "sympp:review_refresh"
  @type scope :: Observer.review_scope()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  @spec with_stdio_session((-> result)) :: result when result: var
  def with_stdio_session(run) do
    if OfflineSandbox.enabled?() do
      run.()
    else
      source = Repo.get_dynamic_repo()

      case start_link(name: {:global, stdio_name(source)}, repo_source: source, standalone: true) do
        {:ok, pid} ->
          try do
            run.()
          after
            GenServer.stop(pid)
          end

        {:error, {:already_started, _pid}} ->
          run.()

        {:error, reason} ->
          raise "sympp MCP review refresh start failed: #{inspect(reason)}"
      end
    end
  end

  @spec request(module(), scope(), boolean()) :: :ok | :pending
  def request(repo, scope, wait?) do
    if OfflineSandbox.enabled?() do
      :ok
    else
      case coordinator(repo) do
        nil -> request_local(repo, scope, wait?)
        pid -> request_shared(pid, scope, wait?)
      end
    end
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(@pubsub, @topic)

  @spec demand(scope()) :: :ok
  def demand(scope), do: GenServer.cast(__MODULE__, {:demand, scope})

  @spec advance() :: :ok
  def advance, do: GenServer.cast(__MODULE__, :advance)

  @doc false
  @spec sweep(%{{String.t(), String.t() | nil} => [String.t()]}) :: [{[String.t()], ReviewStatus.result()}]
  def sweep(groups) when map_size(groups) == 0, do: []
  def sweep(groups), do: GenServer.call(__MODULE__, {:sweep, groups}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Repo.put_dynamic_repo(Keyword.get(opts, :repo_source, Repo))

    {:ok,
     %{
       reads: %{},
       scopes: %{},
       queued: [],
       running: %{},
       waiters: %{},
       sweeps: %{},
       standalone?: Keyword.get(opts, :standalone, false),
       refresh_timer: nil
     }}
  end

  @impl true
  def handle_call({:request, scope, token}, from, state) do
    {ids, state} = select_scope(scope, state)
    state = start_reads(state)

    if complete?(ids, state.reads) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, ids})}}
    end
  end

  def handle_call({:sweep, groups}, from, state) do
    batch = make_ref()
    jobs = for {cycle, ids} <- groups, do: {cycle, {:sweep, batch, ids}}
    sweeps = Map.put(state.sweeps, batch, {from, length(jobs), []})
    {:noreply, start_reads(%{state | sweeps: sweeps, queued: jobs ++ state.queued})}
  end

  @impl true
  def handle_cast({:demand, scope}, state) do
    {_ids, state} = select_scope(scope, state)
    {:noreply, start_reads(state)}
  end

  def handle_cast({:cancel_wait, token}, state) do
    {:noreply, %{state | waiters: Map.delete(state.waiters, token)}}
  end

  def handle_cast(:advance, state), do: {:noreply, next_refresh(state)}

  @impl true
  def handle_info(:advance, state), do: {:noreply, next_refresh(%{state | refresh_timer: nil})}

  def handle_info({:read_timeout, ref}, state) when is_map_key(state.running, ref) do
    {_job, pid, _timer} = Map.fetch!(state.running, ref)
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    {:noreply, finish_read(state, ref, :unknown)}
  end

  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_read(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_map_key(state.running, ref) do
    {:noreply, finish_read(state, ref, :unknown)}
  end

  def handle_info(_finished_read, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.running, fn {_ref, {_job, pid, _timer}} -> Process.exit(pid, :kill) end)
  end

  defp next_refresh(state) do
    # Recheck requested scopes after discovery. An older batch still covers
    # the packages it actually selected, even while its scope is reloaded.
    reads = Map.filter(state.reads, fn {_id, status} -> status == :pending end)
    # Streams renew demand after writing to their connection. A request
    # process still waiting to detect a disconnected peer is not enough.
    if Process.whereis(@pubsub), do: Phoenix.PubSub.broadcast(@pubsub, @topic, :review_refresh_due)
    %{state | reads: reads, scopes: %{}}
  end

  defp select_scope(scope, state) do
    state = ensure_refresh_timer(state)

    case Map.fetch(state.scopes, scope) do
      {:ok, ids} ->
        {ids, state}

      :error ->
        candidates = Observer.pre_pr_review_candidates(Repo, scope)
        ids = for {package, _observation} <- candidates, do: package.id
        missing = Enum.reject(candidates, fn {package, _observation} -> Map.has_key?(state.reads, package.id) end)
        jobs = Observer.display_reviews(Repo, missing)
        pending = for {_route, observations} <- jobs, observation <- observations, do: observation.work_package_id
        reads = Enum.reduce(pending, state.reads, &Map.put(&2, &1, :pending))
        queued = state.queued ++ Enum.map(jobs, fn {cycle, observations} -> {cycle, {:display, observations}} end)
        {ids, %{state | reads: reads, queued: queued, scopes: Map.put(state.scopes, scope, ids)}}
    end
  end

  defp ensure_refresh_timer(%{standalone?: true, refresh_timer: nil} = state),
    do: %{state | refresh_timer: Process.send_after(self(), :advance, @standalone_refresh_ms)}

  defp ensure_refresh_timer(state), do: state

  defp start_reads(%{queued: [_ | _], running: running} = state) when map_size(running) < @review_concurrency do
    # Qualification needs a fresh read after any in-flight read of that cycle.
    active = MapSet.new(Map.values(running), fn {{cycle, _kind}, _pid, _timer} -> cycle end)

    case Enum.split_while(state.queued, fn {cycle, _job} -> MapSet.member?(active, cycle) end) do
      {blocked, [{{review_id, route}, _kind} = job | rest]} ->
        task = Task.async(ReviewStatus, :read, [review_id, route])
        timer = Process.send_after(self(), {:read_timeout, task.ref}, @review_timeout_ms)
        start_reads(%{state | queued: blocked ++ rest, running: Map.put(running, task.ref, {job, task.pid, timer})})

      {_blocked, []} ->
        state
    end
  end

  defp start_reads(state), do: state

  defp finish_read(state, ref, result) do
    {{{_cycle, job}, _pid, timer}, running} = Map.pop!(state.running, ref)
    Process.cancel_timer(timer)
    %{state | running: running} |> complete_read(job, result) |> start_reads()
  end

  defp complete_read(state, {:display, observations}, result) do
    :ok = Observer.record_display_review(Repo, observations, result)
    ids = Enum.map(observations, & &1.work_package_id)
    reads = Enum.reduce(ids, state.reads, &Map.put(&2, &1, :done))
    {ready, waiting} = Map.split_with(state.waiters, fn {_token, {_from, ids}} -> complete?(ids, reads) end)
    Enum.each(ready, fn {_token, {from, _ids}} -> GenServer.reply(from, :ok) end)
    %{state | reads: reads, waiters: waiting}
  end

  defp complete_read(state, {:sweep, batch, ids}, result) do
    {from, remaining, results} = Map.fetch!(state.sweeps, batch)
    results = [{ids, result} | results]

    sweeps =
      if remaining == 1 do
        GenServer.reply(from, results)
        Map.delete(state.sweeps, batch)
      else
        Map.put(state.sweeps, batch, {from, remaining - 1, results})
      end

    %{state | sweeps: sweeps}
  end

  defp complete?(ids, reads), do: Enum.all?(ids, &(Map.get(reads, &1) != :pending))

  defp request_shared(pid, scope, false), do: GenServer.cast(pid, {:demand, scope})

  defp request_shared(pid, scope, true) do
    token = make_ref()

    try do
      GenServer.call(pid, {:request, scope, token}, @board_wait_ms)
    catch
      :exit, {:timeout, _call} ->
        GenServer.cast(pid, {:cancel_wait, token})
        :pending

      :exit, {:noproc, _call} ->
        :pending
    end
  end

  defp request_local(repo, scope, wait?) do
    task = start_local(repo, scope)
    if wait?, do: await_tasks([task], System.monotonic_time(:millisecond) + @board_wait_ms), else: :ok
  end

  defp start_local(repo, scope) do
    source = if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo()

    {:ok, pid} =
      Task.start(fn ->
        if source, do: repo.put_dynamic_repo(source)
        Observer.refresh_review_progress(repo, Observer.pre_pr_review_candidates(repo, scope))
      end)

    pid
  end

  defp coordinator(Repo) do
    source = Repo.get_dynamic_repo()

    case :global.whereis_name(stdio_name(source)) do
      pid when is_pid(pid) -> pid
      :undefined -> if configured_repo?(source), do: Process.whereis(__MODULE__)
    end
  end

  defp coordinator(_repo), do: nil

  defp stdio_name(source), do: {__MODULE__, :stdio, source}

  defp configured_repo?(Repo), do: true

  defp configured_repo?(pid) when is_pid(pid) do
    # The API can use a separate pool for the same configured ledger.
    database = Repo.database_path_without_side_effects()
    pid == Process.whereis(Repo) or pid == :global.whereis_name(Repo.process_key(database))
  end

  defp configured_repo?(_source), do: false

  # A polling board can join a quick refresh. A slow worker still leaves the
  # board available and the client can retry while that same refresh finishes.
  defp await_tasks(tasks, deadline) do
    refs = Enum.map(tasks, &Process.monitor/1)

    try do
      await(refs, deadline)
    after
      Enum.each(refs, &Process.demonitor(&1, [:flush]))
    end
  end

  defp await([], _deadline), do: :ok

  defp await([ref | refs], deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> await(refs, deadline)
    after
      remaining -> :pending
    end
  end
end
