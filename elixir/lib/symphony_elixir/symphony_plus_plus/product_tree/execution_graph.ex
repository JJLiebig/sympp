defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph do
  @moduledoc """
  The hard dependencies of one WorkRequest's packages.

  A dependency is met only by delivered work
  (`DeliveryResolution.satisfies_dependents?/4`): a prerequisite that ended
  `pr_merged` or `completed_no_pr`, or a `superseded`/`skipped` one whose
  same-WorkRequest successors all delivered. A package with an unmet
  dependency doesn't dispatch, and each unmet edge names the packages it
  waits for (`waiting_for`).
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryResolution
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @hard_edge_kinds ["depends_on", "blocks"]

  @type graph :: %{
          available: boolean(),
          work_package_ids: [String.t()],
          effective_edges: [map()],
          topological_order: [String.t()],
          cycles: [[String.t()]],
          unmet_dependencies: [map()],
          dependency_ready_work_package_ids: [String.t()],
          resolutions: [map()],
          merge_eligibility: [map()]
        }

  @spec evaluate(module(), String.t()) :: {:ok, graph()} | {:error, term()}
  def evaluate(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, work_packages} <- WorkRequestRepository.list_work_packages(repo, work_request_id) do
      evaluate(repo, work_request_id, work_packages)
    end
  end

  @spec evaluate(module(), String.t(), [map() | struct()]) :: {:ok, graph()} | {:error, term()}
  def evaluate(repo, work_request_id, work_packages)
      when is_atom(repo) and is_binary(work_request_id) and is_list(work_packages) do
    with {:ok, tree} <- ProductTreeRepository.tree_for_work_request(repo, work_request_id) do
      evaluate(repo, work_request_id, work_packages, tree)
    end
  end

  @spec evaluate(map(), [map() | struct()], [map() | struct()]) :: graph()
  def evaluate(%{} = tree, work_packages, deliveries), do: evaluate(tree, work_packages, deliveries, %{})

  @spec evaluate(module(), String.t(), [map() | struct()], map()) :: {:ok, graph()} | {:error, term()}
  def evaluate(repo, work_request_id, work_packages, tree) when is_atom(repo) do
    deliveries =
      if work_packages == [],
        do: [],
        else: repo.all(from(delivery in WorkPackageDelivery, where: delivery.work_request_id == ^work_request_id))

    with {:ok, successors} <- successors(repo, work_packages) do
      {:ok, evaluate(tree, work_packages, deliveries, successors)}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec evaluate(map(), [map() | struct()], [map() | struct()], map()) :: graph()
  def evaluate(%{dependency_edges: dependency_edges}, work_packages, deliveries, successors)
      when is_list(dependency_edges) and is_list(work_packages) and is_list(deliveries) and is_map(successors) do
    work_packages =
      work_packages
      |> Enum.map(&Map.put(&1, :status, value(&1, :status) || value(&1, :raw_status)))
      |> Enum.sort_by(&value(&1, :id))

    work_package_ids = Enum.map(work_packages, &value(&1, :id))
    work_package_id_set = MapSet.new(work_package_ids)
    packages = Map.new(work_packages, &{value(&1, :id), &1})
    deliveries = Map.new(deliveries, &{value(&1, :work_package_id), &1})

    effective_edges =
      dependency_edges
      |> Enum.filter(&(value(&1, :kind) in @hard_edge_kinds))
      |> effective_edges()
      |> Enum.filter(
        &(MapSet.member?(work_package_id_set, &1.prerequisite_work_package_id) and
            MapSet.member?(work_package_id_set, &1.dependent_work_package_id))
      )
      |> Enum.map(&delivery_state(&1, packages, deliveries, successors))

    resolutions = Enum.map(work_packages, &resolution(&1, packages, deliveries, successors))

    build_graph(work_package_ids, effective_edges, resolutions)
  end

  @doc """
  The same-WorkRequest successors recorded for the ended packages among
  `work_packages`, which a superseded or skipped prerequisite delivers through.
  """
  @spec successors(module(), [map() | struct()]) :: {:ok, map()} | {:error, term()}
  def successors(repo, work_packages) do
    retired =
      work_packages
      |> Enum.filter(&Lifecycle.ended?(value(&1, :status) || value(&1, :raw_status)))
      |> Enum.map(&%{id: value(&1, :id), work_request_id: value(&1, :work_request_id)})

    if retired == [], do: {:ok, %{}}, else: OperationalLineage.delivery_successors(repo, retired)
  end

  @spec scope(graph(), Enumerable.t()) :: graph()
  def scope(%{available: true} = graph, visible_work_package_ids) do
    visible_ids = MapSet.new(visible_work_package_ids)
    graph_work_package_ids = MapSet.new(graph.work_package_ids)

    if MapSet.subset?(graph_work_package_ids, visible_ids) do
      graph
    else
      scope_graph(graph, visible_ids)
    end
  end

  def scope(graph, _visible_work_package_ids), do: graph

  defp scope_graph(%{available: true} = graph, visible_ids) do
    visible? = &MapSet.member?(visible_ids, &1)
    work_package_ids = Enum.filter(graph.work_package_ids, visible?)

    effective_edges =
      Enum.filter(graph.effective_edges, fn edge ->
        visible?.(edge.prerequisite_work_package_id) and visible?.(edge.dependent_work_package_id)
      end)

    resolutions = Enum.filter(graph.resolutions, &visible?.(&1.work_package_id))

    build_graph(work_package_ids, effective_edges, resolutions)
    |> Map.put(:merge_eligibility, Enum.filter(graph.merge_eligibility, &visible?.(&1.work_package_id)))
  end

  defp build_graph(work_package_ids, effective_edges, resolutions) do
    pairs = Enum.map(effective_edges, &{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
    {topological_order, cycles} = topology(work_package_ids, pairs)
    unmet_dependencies = unmet_dependencies(work_package_ids, effective_edges)
    unmet_ids = unmet_dependencies |> Enum.map(& &1.work_package_id) |> MapSet.new()

    %{
      available: true,
      work_package_ids: work_package_ids,
      effective_edges: effective_edges,
      topological_order: topological_order,
      cycles: cycles,
      unmet_dependencies: unmet_dependencies,
      dependency_ready_work_package_ids: if(cycles == [], do: Enum.reject(work_package_ids, &MapSet.member?(unmet_ids, &1)), else: []),
      resolutions: resolutions,
      merge_eligibility: merge_eligibility(work_package_ids, effective_edges, resolutions, cycles)
    }
  end

  @spec require_ready(graph(), String.t()) :: :ok | {:error, term()}
  def require_ready(%{cycles: [_ | _] = cycles}, _work_package_id),
    do: {:error, {:execution_graph_cycle, cycles}}

  def require_ready(%{unmet_dependencies: unmet_dependencies}, work_package_id) do
    case Enum.find(unmet_dependencies, &(&1.work_package_id == work_package_id)) do
      nil ->
        :ok

      %{prerequisite_work_package_ids: prerequisites, waiting_for: waiting_for} ->
        {:error, {:unmet_work_package_dependencies, work_package_id, prerequisites, waiting_for}}
    end
  end

  defp effective_edges(dependency_edges) do
    dependency_edges
    |> Enum.group_by(fn edge ->
      case value(edge, :kind) do
        "depends_on" -> {value(edge, :target_id), value(edge, :source_id)}
        "blocks" -> {value(edge, :source_id), value(edge, :target_id)}
      end
    end)
    |> Enum.map(fn {{prerequisite_id, dependent_id}, edges} ->
      %{
        prerequisite_work_package_id: prerequisite_id,
        dependent_work_package_id: dependent_id,
        dependency_ids: edges |> Enum.map(&value(&1, :id)) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
  end

  # Whether the prerequisite delivered, what the dependent still waits for, and
  # whether a merged dependent landed only after its prerequisite delivered.
  defp delivery_state(edge, packages, deliveries, successors) do
    prerequisite = edge.prerequisite_work_package_id
    delivered = DeliveryResolution.satisfies_dependents?(prerequisite, packages, deliveries, successors)

    waiting_for =
      if delivered,
        do: [],
        else: DeliveryResolution.waiting_for(prerequisite, packages, deliveries, successors)

    Map.merge(edge, %{
      delivered: delivered,
      waiting_for: waiting_for,
      delivered_before: delivered_before?(prerequisite, Map.get(deliveries, edge.dependent_work_package_id), packages, deliveries, successors)
    })
  end

  defp delivered_before?(_id, nil, _packages, _deliveries, _successors), do: true

  defp delivered_before?(id, delivery, packages, deliveries, successors) do
    if value(delivery, :outcome) == "pr_merged" do
      merged_at = timestamp(value(delivery, :pr_merged_at))

      prior_deliveries =
        Map.filter(deliveries, fn {_id, prerequisite} ->
          delivered_at = timestamp(value(prerequisite, :pr_merged_at) || value(prerequisite, :recorded_at))
          is_integer(merged_at) and is_integer(delivered_at) and delivered_at <= merged_at
        end)

      DeliveryResolution.satisfies_dependents?(id, packages, prior_deliveries, successors)
    else
      true
    end
  end

  defp merge_eligibility(ids, edges, resolutions, cycles) do
    incoming = Enum.group_by(edges, & &1.dependent_work_package_id)
    states = Map.new(resolutions, &{&1.work_package_id, &1})

    Enum.map(ids, fn id ->
      edges = Map.get(incoming, id, [])
      state = Map.fetch!(states, id)

      reasons =
        [
          {cycles != [], "dependency_cycle"},
          {Enum.any?(edges, &(not &1.delivered)), "dependency_not_delivered"},
          {Enum.any?(edges, &(not &1.delivered_before)), "delivery_order_violation"}
        ]
        |> Enum.flat_map(fn
          {true, reason} -> [reason]
          {false, _reason} -> []
        end)

      ready = Lifecycle.ready?(state.status)
      terminal = Lifecycle.ended?(state.status) or not is_nil(state.delivery_outcome)

      %{
        work_package_id: id,
        eligible: ready and not terminal and reasons == [],
        reason_codes: if(ready or terminal, do: reasons, else: ["not_ready" | reasons]),
        next_action: merge_next_action(state.status, reasons, terminal)
      }
    end)
  end

  # Merge eligibility only adds dependency reasons on top of `ready`; every
  # other next action comes from the lifecycle.
  defp merge_next_action(_status, _reasons, true), do: nil

  defp merge_next_action(status, [_reason | _rest] = reasons, false) do
    cond do
      not Lifecycle.ready?(status) -> Lifecycle.next_action(status, %{dependencies_met?: "dependency_not_delivered" not in reasons}).action
      "delivery_order_violation" in reasons -> "resolve_delivery_order_violation"
      true -> "deliver_prerequisites"
    end
  end

  defp merge_next_action(status, [], false), do: Lifecycle.next_action(status).action

  defp timestamp(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp timestamp(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, time, _offset} -> timestamp(time)
      _invalid -> nil
    end
  end

  defp timestamp(_time), do: nil

  defp topology(work_package_ids, pairs) do
    graph = :digraph.new()
    Enum.each(work_package_ids, &:digraph.add_vertex(graph, &1))
    Enum.each(Enum.uniq(pairs), fn {from, to} -> :digraph.add_edge(graph, from, to) end)

    topological_order = deterministic_topological_order(work_package_ids, Enum.uniq(pairs))

    self_edges = MapSet.new(Enum.filter(pairs, fn {from, to} -> from == to end) |> Enum.map(&elem(&1, 0)))

    cycles =
      graph
      |> :digraph_utils.strong_components()
      |> Enum.filter(fn component -> length(component) > 1 or MapSet.member?(self_edges, hd(component)) end)
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort()

    :digraph.delete(graph)
    {topological_order, cycles}
  end

  defp deterministic_topological_order(work_package_ids, pairs) do
    successors = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
    indegrees = Enum.reduce(pairs, Map.new(work_package_ids, &{&1, 0}), fn {_from, to}, acc -> Map.update!(acc, to, &(&1 + 1)) end)
    ready = indegrees |> Enum.filter(&(elem(&1, 1) == 0)) |> Enum.map(&elem(&1, 0)) |> :gb_sets.from_list()
    {order, indegrees} = take_ready(ready, successors, indegrees, [])

    if length(order) == map_size(indegrees), do: Enum.reverse(order), else: []
  end

  defp take_ready(ready, successors, indegrees, order) do
    if :gb_sets.is_empty(ready) do
      {order, indegrees}
    else
      {work_package_id, ready} = :gb_sets.take_smallest(ready)
      {ready, indegrees} = decrement_successors(Map.get(successors, work_package_id, []), ready, indegrees)
      take_ready(ready, successors, indegrees, [work_package_id | order])
    end
  end

  defp decrement_successors(successor_ids, ready, indegrees) do
    successor_ids
    |> Enum.sort()
    |> Enum.reduce({ready, indegrees}, fn successor_id, {ready, indegrees} ->
      indegrees = Map.update!(indegrees, successor_id, &(&1 - 1))
      ready = if Map.fetch!(indegrees, successor_id) == 0, do: :gb_sets.add(successor_id, ready), else: ready
      {ready, indegrees}
    end)
  end

  defp resolution(work_package, packages, deliveries, successors) do
    work_package_id = value(work_package, :id)
    status = value(work_package, :status) || value(work_package, :raw_status)

    %{
      work_package_id: work_package_id,
      status: status,
      delivery_outcome: deliveries |> Map.get(work_package_id) |> value(:outcome),
      resolved: DeliveryResolution.satisfies_dependents?(work_package_id, packages, deliveries, successors)
    }
  end

  defp unmet_dependencies(work_package_ids, effective_edges) do
    unmet = effective_edges |> Enum.reject(& &1.delivered) |> Enum.group_by(& &1.dependent_work_package_id)

    Enum.flat_map(work_package_ids, fn work_package_id ->
      case unmet |> Map.get(work_package_id, []) |> Enum.sort_by(& &1.prerequisite_work_package_id) do
        [] ->
          []

        edges ->
          [
            %{
              work_package_id: work_package_id,
              prerequisite_work_package_ids: edges |> Enum.map(& &1.prerequisite_work_package_id) |> Enum.uniq(),
              waiting_for: edges |> Enum.flat_map(& &1.waiting_for) |> Enum.uniq()
            }
          ]
      end
    end)
  end

  defp value(nil, _key), do: nil
  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
