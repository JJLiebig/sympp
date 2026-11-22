defmodule SymphonyElixir.SymphonyPlusPlus.Observer.ReviewRefresh do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.{Observer, OfflineSandbox, Repo}
  alias SymphonyElixir.TaskSupervisor

  @board_wait_ms 2_000
  @type scope :: :all | {:request, String.t()}

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

  @spec watch(scope()) :: :ok
  def watch(scope) do
    if Process.whereis(Observer), do: GenServer.cast(__MODULE__, {:watch, scope})
    :ok
  end

  @spec advance() :: :ok
  def advance, do: GenServer.cast(__MODULE__, :advance)

  @impl true
  def init(_opts), do: {:ok, %{tasks: %{}, watched: MapSet.new()}}

  @impl true
  def handle_call({:request, scope}, _from, state) do
    {tasks, state} = refresh(scope, state)
    {:reply, tasks, state}
  end

  @impl true
  def handle_cast({:watch, scope}, state) do
    {_tasks, state} = refresh(scope, state)
    {:noreply, %{state | watched: MapSet.put(state.watched, scope)}}
  end

  def handle_cast(:advance, state) do
    # Retain in-flight reads so a slow worker is never read twice at once.
    # Event streams renew demand through their existing notifications and heartbeat.
    active = Map.filter(state.tasks, fn {_scope, pid} -> Process.alive?(pid) end)
    scopes = if :all in state.watched, do: [:all], else: state.watched
    state = Enum.reduce(scopes, %{tasks: active, watched: MapSet.new()}, &elem(refresh(&1, &2), 1))
    {:noreply, state}
  end

  defp refresh(:all, %{tasks: %{all: _pid} = tasks} = state), do: {Map.values(tasks), state}

  defp refresh(:all, state) do
    excluded = for {{:request, id}, _pid} <- state.tasks, do: id
    tasks = Map.put(state.tasks, :all, start_factory(:all, excluded))
    {Map.values(tasks), %{state | tasks: tasks}}
  end

  defp refresh({:request, _id} = scope, state) do
    case Map.get(state.tasks, scope) || Map.get(state.tasks, :all) do
      nil ->
        pid = start_factory(scope, [])
        {[pid], %{state | tasks: Map.put(state.tasks, scope, pid)}}

      pid ->
        {[pid], state}
    end
  end

  defp start_factory(scope, excluded) do
    args = [Repo, scope, excluded]
    {:ok, pid} = Task.Supervisor.start_child(TaskSupervisor, Observer, :refresh_review_progress, args)
    pid
  end

  defp start_local(repo, scope) do
    source = if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo()

    {:ok, pid} =
      Task.Supervisor.start_child(TaskSupervisor, fn ->
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
