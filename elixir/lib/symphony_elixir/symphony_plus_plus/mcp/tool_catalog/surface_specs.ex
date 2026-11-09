defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.SurfaceSpecs do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

  @doc """
  Tools listed for a surface profile. `:full` lists everything; `:architect`
  the WorkRequest tools; `:coordinator` and `:solo` health and Solo. Workers
  get no tools: the bridge serves none in a `sympp.role=worker` terminal.
  """
  @spec startup_tool_specs(:full | :architect | :coordinator | :solo, Config.t()) :: [ToolCatalog.tool_spec()]
  def startup_tool_specs(profile, %Config{}) do
    full = fn -> [health_tool_spec() | solo_tool_specs()] ++ [bootstrap_tool_spec("create_work_request") | architect_tool_specs()] end

    case profile do
      :architect -> [health_tool_spec(), bootstrap_tool_spec("create_work_request")] ++ architect_tool_specs()
      profile when profile in [:coordinator, :solo] -> [health_tool_spec() | solo_tool_specs()]
      :full -> full.() ++ local_operator_tool_specs()
    end
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(&put_access_annotation/1)
    |> lean_tool_specs()
  end

  defp put_access_annotation(%{"name" => name} = spec),
    do: Map.put(spec, "annotations", %{"readOnlyHint" => ToolCatalog.tool_access(name) == :read})

  defp solo_tool_specs, do: Enum.map(ToolCatalog.solo_tools(), &SoloTools.tool_spec/1)
  defp architect_tool_specs, do: Enum.map(ToolCatalog.architect_tools(), &architect_tool_spec/1)

  @spec lean_tool_specs([ToolCatalog.tool_spec()]) :: [ToolCatalog.tool_spec()]
  def lean_tool_specs(specs), do: Enum.map(specs, &lean_tool_spec/1)

  @spec local_operator_tool_specs() :: [ToolCatalog.tool_spec()]
  def local_operator_tool_specs, do: Enum.map(ToolCatalog.local_operator_tools(), &local_operator_tool_spec/1)

  defp health_tool_spec do
    %{
      "name" => ToolCatalog.health_tool(),
      "title" => "sympp health",
      "description" => "Returns server version, ledger reachability and identity, and the caller's Herdr terminal with the WorkRequests it owns.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  end

  defp bootstrap_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => bootstrap_tool_description(name),
      "inputSchema" => InputSchemas.bootstrap_tool_input_schema(name)
    }
  end

  defp bootstrap_tool_description("create_work_request"),
    do: "Create a WorkRequest. The calling terminal becomes its owner unless own is false."

  defp local_operator_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => local_operator_tool_description(name),
      "inputSchema" => InputSchemas.local_operator_tool_input_schema(name)
    }
  end

  defp local_operator_tool_description("record_work_request_operator_decision") do
    "Record a redacted local-operator decision on a WorkRequest by id. Any Herdr terminal may record one; ownership is not required."
  end

  defp local_operator_tool_description("summarize_failed_mcp_calls") do
    "Summarize process-local redacted failed MCP call envelopes without exposing raw requests or durable history. Failures are counted only while the operator setting capture_failed_mcp_calls is on; capture_enabled reports it."
  end

  defp lean_tool_spec(spec), do: Map.delete(spec, "title")

  defp architect_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => architect_tool_description(name),
      "inputSchema" => InputSchemas.architect_tool_input_schema(name)
    }
  end

  defp architect_tool_description("list_work_requests"), do: "List WorkRequests in the ledger, newest first."

  defp architect_tool_description("read_work_request"),
    do: "Read a compact WorkRequest overview: status, description, open questions, package next actions and recent decisions. Use detail: full for all contracts and history."

  defp architect_tool_description("read_plan"),
    do: "Read the scoped execution graph, Groups and package references. Use detail: full with the desired view for complete package payloads."

  defp architect_tool_description("read_task_plan"),
    do: "Read the task plan for an explicit descendant WorkPackage."

  defp architect_tool_description("append_finding"),
    do: "Append idempotent finding evidence to an explicit descendant WorkPackage."

  defp architect_tool_description("append_progress"),
    do: "Append an idempotent progress event to an explicit descendant WorkPackage."

  defp architect_tool_description("resolve_blocker"), do: "Resolve a blocker on a WorkPackage of a WorkRequest you own."

  defp architect_tool_description("read_delivery_board"), do: "Read a compact scoped WorkRequest delivery board; detail: full includes complete package and closeout evidence."

  defp architect_tool_description("sync_pr"),
    do:
      "Fetch GitHub evidence for an explicit descendant WorkPackage; accept a normal PR handoff with url and head_sha, or reconcile an attached terminal PR. dependency_inputs records which prerequisite inputs the current PR head consumed."

  defp architect_tool_description("reconcile_work_request"), do: "Dry-run or apply deterministic WorkRequest delivery closeout repairs from structured PR/GitHub evidence."

  defp architect_tool_description("record_work_package_delivery") do
    "End a WorkPackage with its one ending record; replays with the same key are idempotent. Evidence depends on outcome: pr_merged needs PR evidence, completed_no_pr needs direct evidence, superseded needs a same-WorkRequest successor and reason, abandoned needs rationale; finished and skipped need none. Any chief or architect may record finished. Ending clears active blocker residue."
  end

  defp architect_tool_description("set_report"),
    do: "Patch the operator report on a WorkRequest you own: brief, eta and parking. null clears a field; clearing parking records that work resumed."

  defp architect_tool_description("ask_question"), do: "Add a clarification question to a scoped WorkRequest."
  defp architect_tool_description("answer_question"), do: "Answer an open clarification question that belongs to a scoped WorkRequest."
  defp architect_tool_description("answer_question_and_record_decision"), do: "Answer an open clarification question and atomically record the resulting WorkRequest decision."
  defp architect_tool_description("close_question"), do: "Close an open clarification question that belongs to a scoped WorkRequest without recording an answer."

  defp architect_tool_description("record_decision"),
    do: "Record a durable decision log entry on a scoped WorkRequest. source_type must be one of: #{Enum.join(DecisionLogEntry.source_types(), ", ")}."

  defp architect_tool_description("slice_work_request"), do: "Atomically slice a WorkRequest you own into canonical WorkPackages."
  defp architect_tool_description("update_work_package"), do: "Update one canonical WorkPackage contract using its optimistic contract revision."

  defp architect_tool_description("upsert_group") do
    "Create, rename, reparent, or reorder an optional Group inside a WorkRequest you own. Groups organize WorkPackages and have no lifecycle."
  end

  defp architect_tool_description("delete_group"),
    do: "Remove a Group, move its direct child Groups and WorkPackages to its parent, and remove dependencies that name it."

  defp architect_tool_description("upsert_dependency"),
    do: "Create or edit one dependency intent between WorkPackage or Group endpoints; the backend derives effective WorkPackage edges."

  defp architect_tool_description("delete_dependency"), do: "Remove one dependency intent from a WorkRequest you own."
  defp architect_tool_description("skip_work_package"), do: "End a planned WorkPackage of a WorkRequest you own as skipped."

  defp architect_tool_description("dispatch_work_package"),
    do:
      "Dispatch a planned WorkPackage with a review mode: prepares its factory worktree, writes the worker's assignment file and returns launch_line, the hc run command that starts the worker. Calling it again for a dispatched package reuses the same worktree and review id."
end
