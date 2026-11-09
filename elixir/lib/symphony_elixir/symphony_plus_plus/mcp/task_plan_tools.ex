defmodule SymphonyElixir.SymphonyPlusPlus.MCP.TaskPlanTools do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  @type repo :: module()
  @type result :: {:ok, map()} | {:tool_error, term()} | {:error, term()}

  @doc "Reads one WorkPackage task plan by id."
  @spec read_task_plan(repo(), String.t()) :: result()
  def read_task_plan(repo, work_package_id) when is_binary(work_package_id) do
    with {:ok, state} <- PlanningRepository.get_task_plan_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, "task_plan.md"),
         uri = "sympp://work-packages/#{work_package_id}/task_plan.md",
         {:ok, virtual_payload} <- WorkerContext.virtual_file_payload(state, "task_plan.md", uri: uri) do
      {:ok,
       ToolResult.agent_tool_result(
         Map.put(virtual_payload, "text", markdown),
         fn -> WorkerContext.encode_tool_payload(virtual_payload) end
       )}
    end
  end
end
