defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase do
  @moduledoc """
  A WorkRequest's phase, derived on read and never stored. The first match wins:

  | Phase        | Derivation                                                       |
  |--------------|------------------------------------------------------------------|
  | `archived`   | `archived_at` is set (stored operator or retention override)     |
  | `done`       | `operator_completed_at` is set (stored operator override)        |
  | `intake`     | no packages                                                      |
  | `active`     | any package `dispatched` or `ready`                              |
  | `planned`    | any package `planned`, including a mix with ended packages       |
  | `unresolved` | all ended, and every package is skipped or one doesn't resolve   |
  | `done`       | all ended, and every non-skipped package resolves                |

  Resolution follows the outcome matrix in `DeliveryResolution`. A skipped
  package without a successor is left out, unless every package is skipped.
  Open clarification questions never change the phase.

  Writes to an archived WorkRequest are refused with `next_action: restore`;
  nothing restores an archived WorkRequest implicitly.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @phases ["intake", "planned", "active", "unresolved", "done", "archived"]
  @chunk_size 500

  @type phase :: String.t()
  @type summary :: %{phase: phase(), completed_at: DateTime.t() | nil}

  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  The phase and, when the WorkRequest is done, when it became done. For an
  archived WorkRequest `completed_at` still reports when its work was done, so
  retention can age it.
  """
  @spec summary(WorkRequest.t(), [WorkPackage.t()], map(), map()) :: summary()
  def summary(%WorkRequest{} = work_request, work_packages, deliveries_by_id, successors_by_id \\ %{}) do
    work_phase = work_phase(work_request, work_packages, deliveries_by_id, successors_by_id)

    %{
      phase: if(work_request.archived_at, do: "archived", else: work_phase),
      completed_at: completed_at(work_request, work_phase, work_packages, deliveries_by_id)
    }
  end

  @spec derive(WorkRequest.t(), [WorkPackage.t()], map(), map()) :: phase()
  def derive(%WorkRequest{} = work_request, work_packages, deliveries_by_id, successors_by_id \\ %{}) do
    summary(work_request, work_packages, deliveries_by_id, successors_by_id).phase
  end

  @doc "What the operator should do next in this phase, if anything."
  @spec next_action(phase()) :: String.t() | nil
  def next_action("archived"), do: "restore"
  def next_action("unresolved"), do: "complete_or_archive"
  def next_action(_phase), do: nil

  @doc "Refuses writes to an archived WorkRequest."
  @spec require_writable(WorkRequest.t()) :: :ok | {:error, :work_request_archived}
  def require_writable(%WorkRequest{archived_at: %DateTime{}}), do: {:error, :work_request_archived}
  def require_writable(%WorkRequest{}), do: :ok

  @doc "Loads the phase summary of each WorkRequest, keyed by id."
  @spec load(module(), [WorkRequest.t()]) :: {:ok, %{optional(String.t()) => summary()}} | {:error, term()}
  def load(_repo, []), do: {:ok, %{}}

  def load(repo, work_requests) when is_atom(repo) and is_list(work_requests) do
    load(repo, work_requests, work_packages(repo, Enum.map(work_requests, & &1.id)))
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @doc "Like `load/2`, with the WorkRequests' packages already read."
  @spec load(module(), [WorkRequest.t()], [WorkPackage.t()]) ::
          {:ok, %{optional(String.t()) => summary()}} | {:error, term()}
  def load(repo, work_requests, work_packages) when is_atom(repo) and is_list(work_requests) and is_list(work_packages) do
    kinds = WorkPackage.executable_kinds()
    work_packages = Enum.filter(work_packages, &(&1.kind in kinds))
    deliveries = deliveries(repo, Enum.map(work_packages, & &1.id))

    with {:ok, successors} <- OperationalLineage.delivery_successors(repo, work_packages) do
      packages_by_request = Enum.group_by(work_packages, & &1.work_request_id)

      {:ok,
       Map.new(work_requests, fn %WorkRequest{} = work_request ->
         {work_request.id, summary(work_request, Map.get(packages_by_request, work_request.id, []), deliveries, successors)}
       end)}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec load_one(module(), WorkRequest.t()) :: {:ok, summary()} | {:error, term()}
  def load_one(repo, %WorkRequest{} = work_request) do
    with {:ok, summaries} <- load(repo, [work_request]) do
      {:ok, Map.fetch!(summaries, work_request.id)}
    end
  end

  defp work_phase(%WorkRequest{operator_completed_at: %DateTime{}}, _packages, _deliveries, _successors), do: "done"
  defp work_phase(%WorkRequest{}, [], _deliveries, _successors), do: "intake"

  defp work_phase(%WorkRequest{}, work_packages, deliveries, successors) do
    cond do
      Enum.any?(work_packages, &(Lifecycle.dispatched?(&1) or Lifecycle.ready?(&1))) -> "active"
      Enum.any?(work_packages, &Lifecycle.planned?/1) -> "planned"
      resolved?(work_packages, deliveries, successors) -> "done"
      true -> "unresolved"
    end
  end

  defp resolved?(work_packages, deliveries, successors) do
    packages_by_id = Map.new(work_packages, &{&1.id, &1})

    required =
      Enum.reject(work_packages, fn work_package ->
        outcome(Map.get(deliveries, work_package.id)) == "skipped" and
          DeliveryResolution.successor_ids(work_package.id, deliveries, successors) == []
      end)

    required != [] and
      Enum.all?(required, &DeliveryResolution.resolves_work_request?(&1.id, packages_by_id, deliveries, successors))
  end

  defp completed_at(%WorkRequest{operator_completed_at: %DateTime{} = at}, _phase, _packages, _deliveries), do: at

  defp completed_at(%WorkRequest{}, "done", work_packages, deliveries) do
    work_packages
    |> Enum.map(fn work_package ->
      case Map.get(deliveries, work_package.id) do
        nil -> work_package.updated_at
        delivery -> value(delivery, :recorded_at) || work_package.updated_at
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp completed_at(%WorkRequest{}, _phase, _packages, _deliveries), do: nil

  defp work_packages(repo, work_request_ids) do
    kinds = WorkPackage.executable_kinds()

    work_request_ids
    |> Enum.chunk_every(@chunk_size)
    |> Enum.flat_map(fn chunk ->
      repo.all(from(package in WorkPackage, where: package.work_request_id in ^chunk and package.kind in ^kinds))
    end)
  end

  defp deliveries(repo, work_package_ids) do
    work_package_ids
    |> Enum.chunk_every(@chunk_size)
    |> Enum.flat_map(fn chunk ->
      repo.all(from(delivery in WorkPackageDelivery, where: delivery.work_package_id in ^chunk))
    end)
    |> Map.new(&{&1.work_package_id, &1})
  end

  defp outcome(nil), do: nil
  defp outcome(delivery), do: value(delivery, :outcome)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
