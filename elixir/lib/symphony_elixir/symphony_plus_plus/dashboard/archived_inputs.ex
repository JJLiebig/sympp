defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.ArchivedInputs do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Read the revision on the same transaction as the other board inputs.
  # Cache only stored data. Ownership, lineage endpoints, and time-dependent
  # signals are projected against the current board inputs on every build.
  @spec load(module(), boolean()) :: {:ok, map()} | {:error, term()}
  def load(repo, true) do
    with server when is_pid(server) <- Process.whereis(__MODULE__),
         source when is_pid(source) <- GenServer.whereis(repo.get_dynamic_repo()),
         {:ok, %{rows: [[revision]]}} <- repo.query("SELECT revision FROM sympp_dashboard_archive_revision", []) do
      case GenServer.call(server, {:get, source, revision}) do
        {:ok, _inputs} = hit -> hit
        :miss -> load_and_store(repo, server, source, revision)
      end
    else
      _unavailable -> read(repo)
    end
  end

  def load(repo, false), do: read(repo)

  defp load_and_store(repo, server, source, revision) do
    with {:ok, inputs} <- read(repo) do
      GenServer.cast(server, {:put, source, revision, inputs})
      {:ok, inputs}
    end
  end

  defp read(repo) do
    with {:ok, work_requests} <- Repository.list(repo, %{phase: "archived"}),
         {:ok, inputs} <- Dashboard.operator_projection_inputs(repo, work_requests) do
      {:ok, %{work_requests: work_requests, projection_inputs: inputs}}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, source, revision}, _from, entries) do
    reply =
      case Map.get(entries, source) do
        {^revision, inputs} -> {:ok, inputs}
        _other -> :miss
      end

    {:reply, reply, entries}
  end

  @impl true
  def handle_cast({:put, source, revision, inputs}, entries) do
    case Map.get(entries, source) do
      {current, _inputs} when current >= revision ->
        {:noreply, entries}

      nil ->
        Process.monitor(source)
        {:noreply, Map.put(entries, source, {revision, inputs})}

      _older ->
        {:noreply, Map.put(entries, source, {revision, inputs})}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, source, _reason}, entries) do
    {:noreply, Map.delete(entries, source)}
  end
end
