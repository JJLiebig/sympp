defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyInputs
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
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

    with {:ok, context} <- DependencyInputs.context(repo, work_packages, Enum.any?(tree.dependency_edges, &(&1.candidate_head_sha || &1.selection_updated_at))) do
      {:ok, evaluate(tree, work_packages, deliveries, context)}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec evaluate(map(), [map() | struct()], [map() | struct()], map()) :: graph()
  def evaluate(%{dependency_edges: dependency_edges}, work_packages, deliveries, context)
      when is_list(dependency_edges) and is_list(work_packages) and is_list(deliveries) do
    work_packages =
      work_packages
      |> Enum.map(&Map.put(&1, :status, value(&1, :status) || value(&1, :raw_status)))
      |> Enum.sort_by(&value(&1, :id))

    work_package_ids = Enum.map(work_packages, &value(&1, :id))
    work_package_id_set = MapSet.new(work_package_ids)

    effective_edges =
      dependency_edges
      |> Enum.filter(&(value(&1, :kind) in @hard_edge_kinds))
      |> effective_edges()
      |> Enum.filter(
        &(MapSet.member?(work_package_id_set, &1.prerequisite_work_package_id) and
            MapSet.member?(work_package_id_set, &1.dependent_work_package_id))
      )

    packages = Map.new(work_packages, &{value(&1, :id), &1})
    deliveries_by_work_package_id = Map.new(deliveries, &{value(&1, :work_package_id), &1})
    successors = Map.get(context, :successors, %{})
    resolutions = Enum.map(work_packages, &resolution(&1, packages, deliveries_by_work_package_id, successors))
    effective_edges = DependencyInputs.evaluate(effective_edges, packages, deliveries_by_work_package_id, context)

    build_graph(work_package_ids, effective_edges, resolutions)
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
      merge_eligibility: DependencyInputs.merge_eligibility(work_package_ids, effective_edges, resolutions, cycles)
    }
  end

  @spec require_ready(graph(), String.t()) :: :ok | {:error, term()}
  def require_ready(%{cycles: [_ | _] = cycles}, _work_package_id),
    do: {:error, {:execution_graph_cycle, cycles}}

  def require_ready(%{unmet_dependencies: unmet_dependencies}, work_package_id) do
    case Enum.find(unmet_dependencies, &(&1.work_package_id == work_package_id)) do
      nil -> :ok
      evidence -> {:error, {:unmet_work_package_dependencies, work_package_id, evidence.prerequisite_work_package_ids}}
    end
  end

  defp effective_edges(dependency_edges) do
    dependency_edges
    |> Enum.sort_by(&{value(&1, :created_at), value(&1, :id)})
    |> Enum.reduce(%{}, fn edge, acc ->
      {prerequisite_id, dependent_id} =
        case value(edge, :kind) do
          "depends_on" -> {value(edge, :target_id), value(edge, :source_id)}
          "blocks" -> {value(edge, :source_id), value(edge, :target_id)}
        end

      Map.update(acc, {prerequisite_id, dependent_id}, [constraint(edge)], &[constraint(edge) | &1])
    end)
    |> Enum.map(fn {{prerequisite_id, dependent_id}, constraints} ->
      %{
        prerequisite_work_package_id: prerequisite_id,
        dependent_work_package_id: dependent_id,
        dependency_ids: constraints |> Enum.map(& &1.dependency_id) |> Enum.uniq() |> Enum.sort(),
        constraints: Enum.sort_by(constraints, & &1.dependency_id)
      }
    end)
    |> Enum.sort_by(&{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
  end

  defp constraint(edge), do: %{dependency_id: value(edge, :id), candidate_head_sha: value(edge, :candidate_head_sha), selection_updated_at: value(edge, :selection_updated_at)}

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
    prerequisites =
      effective_edges
      |> Enum.reject(&Enum.all?(&1.constraints, fn constraint -> constraint.available end))
      |> Enum.group_by(& &1.dependent_work_package_id, & &1.prerequisite_work_package_id)

    Enum.flat_map(work_package_ids, fn work_package_id ->
      case Map.get(prerequisites, work_package_id, []) |> Enum.uniq() |> Enum.sort() do
        [] -> []
        unmet -> [%{work_package_id: work_package_id, prerequisite_work_package_ids: unmet}]
      end
    end)
  end

  defp value(nil, _key), do: nil
  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
