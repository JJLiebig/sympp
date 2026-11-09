defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Projection do
  @moduledoc """
  The read model of a WorkRequest's plan: dependency intents, the effective
  execution graph and the latest plan revision. Groups are a path on each
  package, so they need no projection here.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, ExecutionGraph, Revision}

  @spec project(module(), String.t(), [map()], keyword()) :: map()
  def project(repo, work_request_id, work_package_payloads, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_list(work_package_payloads) and is_list(opts) do
    with {:ok, tree} <- product_tree_context(repo, work_request_id, opts),
         {:ok, execution_graph} <- ExecutionGraph.evaluate(repo, work_request_id, work_package_payloads, tree) do
      project_tree(tree, execution_graph, work_package_payloads, opts)
    else
      {:error, reason} -> unavailable_projection(reason, work_package_payloads)
    end
  end

  defp product_tree_context(repo, work_request_id, opts) do
    case Keyword.fetch(opts, :product_tree_context) do
      {:ok, nil} -> ProductTree.tree_for_work_request(repo, work_request_id)
      {:ok, context} -> context
      :error -> ProductTree.tree_for_work_request(repo, work_request_id)
    end
  end

  defp project_tree(%{dependency_edges: dependency_edges, latest_revision: latest_revision}, execution_graph, work_package_payloads, opts) do
    visible_work_package_ids =
      work_package_payloads
      |> Enum.map(&map_value(&1, "id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {dependency_edges, execution_graph} =
      if Keyword.get(opts, :visible_only?, false) do
        {Enum.filter(dependency_edges, &(MapSet.member?(visible_work_package_ids, &1.source_id) and MapSet.member?(visible_work_package_ids, &1.target_id))),
         ExecutionGraph.scope(execution_graph, visible_work_package_ids)}
      else
        {dependency_edges, execution_graph}
      end

    %{
      available: true,
      dependency_edges: Enum.map(dependency_edges, &dependency_edge_payload/1),
      execution_graph: public_execution_graph(execution_graph),
      summary: summary(work_package_payloads),
      latest_revision: revision_payload(latest_revision)
    }
  end

  defp public_execution_graph(graph) do
    edges =
      Enum.map(graph.effective_edges, fn edge ->
        %{edge | constraints: Enum.map(edge.constraints, &public_constraint/1)}
      end)

    graph |> Map.drop([:merge_eligibility]) |> Map.put(:effective_edges, edges)
  end

  defp public_constraint(%{candidate_head_sha: nil} = constraint),
    do: Map.take(constraint, [:dependency_id, :available, :delivered])

  defp public_constraint(constraint), do: Map.drop(constraint, [:selection_updated_at])

  defp dependency_edge_payload(%DependencyEdge{} = edge) do
    %{
      id: edge.id,
      source: %{kind: edge.source_kind, id: edge.source_id},
      target: %{kind: edge.target_kind, id: edge.target_id},
      kind: edge.kind,
      candidate_head_sha: edge.candidate_head_sha,
      reason: Sanitizer.redacted_text(edge.reason),
      decision_ref: Sanitizer.redacted_json(edge.decision_ref),
      created_by: Sanitizer.redacted_text(edge.created_by),
      created_at: timestamp(edge.created_at)
    }
  end

  defp revision_payload(nil), do: nil

  defp revision_payload(%Revision{} = revision) do
    %{
      id: revision.id,
      revision_number: revision.revision_number,
      reason: Sanitizer.redacted_text(revision.reason),
      decision_ref: Sanitizer.redacted_json(revision.decision_ref),
      created_by: Sanitizer.redacted_text(revision.created_by),
      created_at: timestamp(revision.created_at)
    }
  end

  defp summary(work_package_payloads) do
    %{
      work_package_count: length(work_package_payloads),
      attention_count: Enum.count(work_package_payloads, &work_package_attention?/1),
      guidance_count: Enum.count(work_package_payloads, &work_package_guidance?/1),
      blocker_count: Enum.count(work_package_payloads, &work_package_blocker?/1)
    }
  end

  defp unavailable_projection(reason, work_package_payloads) do
    work_package_ids = work_package_payloads |> Enum.map(&map_value(&1, "id")) |> Enum.reject(&is_nil/1)

    %{
      available: false,
      dependency_edges: [],
      execution_graph: %{
        available: false,
        work_package_ids: work_package_ids,
        effective_edges: [],
        topological_order: [],
        cycles: [],
        unmet_dependencies: [],
        dependency_ready_work_package_ids: [],
        resolutions: []
      },
      summary: %{
        work_package_count: length(work_package_payloads),
        attention_count: 0,
        guidance_count: 0,
        blocker_count: 0
      },
      attention_items: [
        %{
          key: "product_tree_unavailable",
          label: "Plan unavailable",
          tone: "warning",
          reason: inspect(reason)
        }
      ]
    }
  end

  defp work_package_attention?(work_package) do
    state = map_value(work_package, "operational_state") || %{}

    map_value(state, "key") in ["blocked", "needs_attention"] or
      (map_value(state, "attention_items") || []) != [] or
      (map_value(work_package, "attention_reason_codes") || []) != []
  end

  defp work_package_blocker?(work_package) do
    state = map_value(work_package, "operational_state") || %{}
    reason_codes = map_value(work_package, "attention_reason_codes") || map_value(state, "attention_reason_codes") || []

    "active_blocker" in reason_codes or
      Enum.any?(map_value(state, "attention_items") || [], &(map_value(&1, "key") == "active_blocker"))
  end

  defp work_package_guidance?(work_package) do
    state = map_value(work_package, "operational_state") || %{}
    Enum.any?(map_value(state, "attention_items") || [], &attention_item_guidance?/1)
  end

  defp attention_item_guidance?(item) do
    key = item |> map_value("key") |> downcased()
    label = item |> map_value("label") |> downcased()

    String.contains?(key, "question") or String.contains?(label, "question")
  end

  defp downcased(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp downcased(_value), do: ""

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, maybe_atom(key))
  defp map_value(_map, _key), do: nil

  defp maybe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil
end
