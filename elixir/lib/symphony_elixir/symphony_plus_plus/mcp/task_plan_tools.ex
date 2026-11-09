defmodule SymphonyElixir.SymphonyPlusPlus.MCP.TaskPlanTools do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  @type repo :: module()

  @doc """
  One WorkPackage's task plan for the package view: its version and up to
  100 steps (`omitted_steps` counts the rest); with detail `full`, also the
  rendered Markdown.
  """
  @spec task_plan(repo(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def task_plan(repo, work_package_id, detail) when is_binary(work_package_id) and detail in ["summary", "full"] do
    with {:ok, state} <- PlanningRepository.get_task_plan_render_state(repo, work_package_id),
         {:ok, text} <- task_plan_text(state, detail) do
      {:ok,
       %{"version" => plan_version(state.plan_version_material), "steps" => Enum.map(state.plan_nodes, &redacted_plan_node_payload/1)}
       |> put_present("omitted_steps", if((state.plan_nodes_omitted_count || 0) > 0, do: state.plan_nodes_omitted_count))
       |> put_present("text", text)}
    end
  end

  defp redacted_plan_node_payload(%PlanNode{} = plan_node), do: Map.update!(plan_node_payload(plan_node), "title", &Redactor.redact_text/1)

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp task_plan_text(state, "full"), do: PlanningRenderer.render_state(state, "task_plan.md")
  defp task_plan_text(_state, "summary"), do: {:ok, nil}

  defp plan_version(plan_nodes) do
    material =
      Enum.map(plan_nodes, fn node ->
        %{
          id: node.id,
          title: node.title,
          body: node.body,
          status: node.status,
          position: node.position,
          updated_at: timestamp_version_part(node.updated_at)
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> rem(9_007_199_254_740_991)
  end

  defp timestamp_version_part(nil), do: nil
  defp timestamp_version_part(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end
end
