defmodule SymphonyElixir.SymphonyPlusPlus.Observer.ReviewRefresh do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.{Observer, OfflineSandbox, Repo}
  alias SymphonyElixir.TaskSupervisor

  @board_wait_ms 2_000
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
  def init(_opts), do: {:ok, %{tasks: %{}, scopes: %{}}}

  @impl true
  def handle_call({:request, scope}, _from, state) do
    {tasks, state} = refresh(scope, state)
    {:reply, tasks, state}
  end

  @impl true
  def handle_cast({:demand, scope}, state) do
    {_tasks, state} = refresh(scope, state)
    {:noreply, state}
  end

  def handle_cast(:advance, state) do
    # Recheck requested scopes after discovery. An older batch still covers
    # the packages it actually selected, even while its scope is reloaded.
    tasks = Map.filter(state.tasks, fn {_id, pid} -> Process.alive?(pid) end)
    # Streams renew demand after writing to their connection. A request
    # process still waiting to detect a disconnected peer is not enough.
    Phoenix.PubSub.broadcast(@pubsub, @topic, :review_refresh_due)
    {:noreply, %{tasks: tasks, scopes: %{}}}
  end

  defp refresh(scope, state) do
    {ids, state} = select_scope(scope, state)
    {state.tasks |> Map.take(ids) |> Map.values() |> Enum.uniq(), state}
  end

  defp select_scope(scope, state) do
    case Map.fetch(state.scopes, scope) do
      {:ok, ids} ->
        {ids, state}

      :error ->
        candidates = Observer.pre_pr_review_candidates(Repo, scope)
        ids = for {package, _observation} <- candidates, do: package.id
        missing = Enum.reject(candidates, fn {package, _observation} -> Map.has_key?(state.tasks, package.id) end)
        tasks = start_missing(missing, state.tasks)
        {ids, %{state | tasks: tasks, scopes: Map.put(state.scopes, scope, ids)}}
    end
  end

  defp start_missing([], tasks), do: tasks

  defp start_missing(candidates, tasks) do
    args = [Repo, candidates]
    {:ok, pid} = Task.Supervisor.start_child(TaskSupervisor, Observer, :refresh_review_progress, args)
    Enum.reduce(candidates, tasks, fn {package, _observation}, tasks -> Map.put(tasks, package.id, pid) end)
  end

  defp request_factory(scope, false), do: demand(scope)

  defp request_factory(scope, true) do
    deadline = System.monotonic_time(:millisecond) + @board_wait_ms
    __MODULE__ |> GenServer.call({:request, scope}, @board_wait_ms) |> await_tasks(deadline)
  catch
    :exit, {:timeout, _call} -> :pending
    :exit, {:noproc, _call} -> :pending
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
