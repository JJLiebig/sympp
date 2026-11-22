defmodule SymphonyElixir.SymphonyPlusPlus.Observer.ReviewRefresh do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.{Observer, OfflineSandbox, Repo}
  alias SymphonyElixir.TaskSupervisor

  @board_wait_ms 2_000
  @review_concurrency 4
  @pubsub SymphonyElixir.PubSub
  @topic "sympp:review_refresh"
  @type scope :: Observer.review_scope()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec request(module(), scope(), boolean()) :: :ok | :pending
  def request(repo, scope, wait?) do
    cond do
      OfflineSandbox.enabled?() -> :ok
      factory_source?(repo) -> request_factory(scope, wait?)
      true -> request_local(repo, scope, wait?)
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

  @impl true
  def init(_opts), do: {:ok, %{reads: %{}, scopes: %{}, queued: [], running: %{}, waiters: %{}}}

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

  @impl true
  def handle_cast({:demand, scope}, state) do
    {_ids, state} = select_scope(scope, state)
    {:noreply, start_reads(state)}
  end

  def handle_cast({:cancel_wait, token}, state) do
    {:noreply, %{state | waiters: Map.delete(state.waiters, token)}}
  end

  def handle_cast(:advance, state) do
    # Recheck requested scopes after discovery. An older batch still covers
    # the packages it actually selected, even while its scope is reloaded.
    reads = Map.filter(state.reads, fn {_id, status} -> status == :pending end)
    # Streams renew demand after writing to their connection. A request
    # process still waiting to detect a disconnected peer is not enough.
    Phoenix.PubSub.broadcast(@pubsub, @topic, :review_refresh_due)
    {:noreply, %{state | reads: reads, scopes: %{}}}
  end

  @impl true
  def handle_info({ref, :ok}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_read(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_map_key(state.running, ref) do
    {:noreply, finish_read(state, ref)}
  end

  defp select_scope(scope, state) do
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
        queued = state.queued ++ jobs
        {ids, %{state | reads: reads, queued: queued, scopes: Map.put(state.scopes, scope, ids)}}
    end
  end

  defp start_reads(%{queued: [{_route, observations} = job | rest], running: running} = state)
       when map_size(running) < @review_concurrency do
    ids = Enum.map(observations, & &1.work_package_id)
    task = Task.Supervisor.async_nolink(TaskSupervisor, Observer, :refresh_display_review, [Repo, job])
    start_reads(%{state | queued: rest, running: Map.put(running, task.ref, ids)})
  end

  defp start_reads(state), do: state

  defp finish_read(state, ref) do
    {ids, running} = Map.pop!(state.running, ref)
    reads = Enum.reduce(ids, state.reads, &Map.put(&2, &1, :done))
    {ready, waiting} = Map.split_with(state.waiters, fn {_token, {_from, ids}} -> complete?(ids, reads) end)
    Enum.each(ready, fn {_token, {from, _ids}} -> GenServer.reply(from, :ok) end)
    start_reads(%{state | reads: reads, running: running, waiters: waiting})
  end

  defp complete?(ids, reads), do: Enum.all?(ids, &(Map.get(reads, &1) != :pending))

  defp request_factory(scope, false), do: demand(scope)

  defp request_factory(scope, true) do
    token = make_ref()

    try do
      GenServer.call(__MODULE__, {:request, scope, token}, @board_wait_ms)
    catch
      :exit, {:timeout, _call} ->
        GenServer.cast(__MODULE__, {:cancel_wait, token})
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

  defp factory_source?(Repo), do: Process.whereis(Observer) != nil and factory_repo?(Repo.get_dynamic_repo())
  defp factory_source?(_repo), do: false

  defp factory_repo?(Repo), do: true

  defp factory_repo?(pid) when is_pid(pid) do
    # The API can use a separate pool for the same configured ledger.
    database = Repo.database_path_without_side_effects()
    pid == Process.whereis(Repo) or pid == :global.whereis_name(Repo.process_key(database))
  end

  defp factory_repo?(_source), do: false

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
