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
    if OfflineSandbox.enabled?() do
      :ok
    else
      tasks = if factory_source?(repo), do: GenServer.call(__MODULE__, {:request, scope}), else: [start_local(repo, scope)]
      if wait?, do: await(tasks), else: :ok
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
  def init(_opts), do: {:ok, %{tasks: %{}}}

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
    # Keep the scopes of in-flight reads and any scopes they already excluded.
    active = for {scope, pid} <- state.tasks, Process.alive?(pid), do: scope
    tasks = Map.filter(state.tasks, fn {scope, _pid} -> Enum.any?(active, &covers?(&1, scope)) end)
    # Streams renew demand after writing to their connection. A request
    # process still waiting to detect a disconnected peer is not enough.
    Phoenix.PubSub.broadcast(@pubsub, @topic, :review_refresh_due)
    {:noreply, %{state | tasks: tasks}}
  end

  defp refresh(scope, state) do
    active_scopes = Map.keys(state.tasks)

    tasks =
      if Enum.any?(active_scopes, &covers?(&1, scope)) do
        state.tasks
      else
        excluded = Enum.filter(active_scopes, &covers?(scope, &1))
        Map.put(state.tasks, scope, start_factory(scope, excluded))
      end

    joined = for {read, pid} <- tasks, covers?(read, scope) or covers?(scope, read), do: pid
    {joined, %{state | tasks: tasks}}
  end

  defp covers?(:all, _scope), do: true
  defp covers?({:request, id}, {:package, id, _package_id}), do: true
  defp covers?(scope, scope), do: true
  defp covers?(_outer, _inner), do: false

  defp start_factory(scope, excluded) do
    args = [Repo, scope, excluded]
    {:ok, pid} = Task.Supervisor.start_child(TaskSupervisor, Observer, :refresh_review_progress, args)
    pid
  end

  defp start_local(repo, scope) do
    source = if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo()

    {:ok, pid} =
      Task.start(fn ->
        if source, do: repo.put_dynamic_repo(source)
        Observer.refresh_review_progress(repo, scope)
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
  defp await(tasks) do
    refs = Enum.map(tasks, &Process.monitor/1)

    try do
      await(refs, System.monotonic_time(:millisecond) + @board_wait_ms)
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
