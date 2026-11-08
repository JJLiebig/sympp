defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution do
  @moduledoc """
  The outcome matrix: what each ending outcome means for dependents and for
  WorkRequest completion.

  | Outcome           | Satisfies dependents          | Resolves the WorkRequest       |
  |-------------------|-------------------------------|--------------------------------|
  | `pr_merged`       | yes                           | yes                            |
  | `completed_no_pr` | yes                           | yes                            |
  | `finished`        | no (the code is not on base)  | yes                            |
  | `superseded`      | if its same-WR successors do  | if its same-WR successors do   |
  | `skipped`         | only through a successor      | only through a successor       |
  | `abandoned`       | no                            | no                             |
  | `legacy`          | if it was `merged`/`closed`   | if it was `merged`/`closed`    |

  Successor chains are cycle-safe and never cross WorkRequests. A skipped
  package without a successor is left out of WorkRequest completion (see
  `Completion`), unless every package is skipped.
  """

  @delivered_outcomes ["pr_merged", "completed_no_pr"]
  @traversed_outcomes ["superseded", "skipped"]
  @resolving_legacy_statuses ["merged", "closed"]

  @doc "Whether the package's ending lets packages that depend on it proceed."
  @spec satisfies_dependents?(String.t(), map(), map()) :: boolean()
  @spec satisfies_dependents?(String.t(), map(), map(), map()) :: boolean()
  def satisfies_dependents?(work_package_id, work_packages_by_id, deliveries_by_id, successors_by_id \\ %{}) do
    resolve(work_package_id, work_packages_by_id, deliveries_by_id, successors_by_id, :dependents, %{})
  end

  @doc "Whether the package's ending counts toward completing its WorkRequest."
  @spec resolves_work_request?(String.t(), map(), map()) :: boolean()
  @spec resolves_work_request?(String.t(), map(), map(), map()) :: boolean()
  def resolves_work_request?(work_package_id, work_packages_by_id, deliveries_by_id, successors_by_id \\ %{}) do
    resolve(work_package_id, work_packages_by_id, deliveries_by_id, successors_by_id, :work_request, %{})
  end

  @spec successor_ids(String.t(), map(), map()) :: [String.t()]
  def successor_ids(work_package_id, deliveries_by_id, successors_by_id) do
    delivery = Map.get(deliveries_by_id, work_package_id, %{})
    pointer = if value(delivery, :outcome) == "superseded", do: value(delivery, :successor_work_package_id)

    (List.wrap(pointer) ++ Map.get(successors_by_id, work_package_id, [])) |> Enum.uniq()
  end

  defp resolve(id, packages, deliveries, successors, mode, visited) do
    package = Map.get(packages, id)
    delivery = Map.get(deliveries, id)
    outcome = value(delivery, :outcome)

    cond do
      is_nil(package) -> false
      outcome in @delivered_outcomes -> true
      outcome == "finished" -> mode == :work_request
      outcome == "legacy" -> value(delivery, :legacy_status) in @resolving_legacy_statuses
      outcome == "superseded" and is_nil(value(delivery, :successor_work_package_id)) -> false
      Map.has_key?(visited, id) -> false
      outcome in @traversed_outcomes -> resolve_successors(package, packages, deliveries, successors, mode, Map.put(visited, id, true))
      true -> false
    end
  end

  defp resolve_successors(package, packages, deliveries, successors, mode, visited) do
    ids = successor_ids(value(package, :id), deliveries, successors)

    ids != [] and
      Enum.all?(ids, fn id ->
        successor = Map.get(packages, id)

        not is_nil(successor) and value(successor, :work_request_id) == value(package, :work_request_id) and
          resolve(id, packages, deliveries, successors, mode, visited)
      end)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
