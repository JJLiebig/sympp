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
         {:ok, %{rows: [[revision]]}} <- repo.query("SELECT revision FROM sympp_dashboard_archive_revision", []) do
      case GenServer.call(server, {:get, revision}) do
        {:ok, _inputs} = hit -> hit
        :miss -> load_and_store(repo, server, revision)
      end
    else
      _unavailable -> read(repo)
    end
  end

  def load(repo, false), do: read(repo)

  defp load_and_store(repo, server, revision) do
    with {:ok, inputs} <- read(repo) do
      GenServer.cast(server, {:put, revision, inputs})
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
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:get, revision}, _from, {revision, inputs} = entry), do: {:reply, {:ok, inputs}, entry}
  def handle_call({:get, _revision}, _from, entry), do: {:reply, :miss, entry}

  @impl true
  def handle_cast({:put, revision, inputs}, _entry), do: {:noreply, {revision, inputs}}
end
