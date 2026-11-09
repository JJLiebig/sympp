defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectProductTreeTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [json_safe_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    ErrorDetails,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @work_package_authoring_states ["planned", "dispatched"]

  @tools [
    "ask_question",
    "record_decision",
    "edit_plan",
    "skip_work_package"
  ]

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t(), map()) :: {:ok, map()} | {:error, integer(), String.t(), map()}
  def call("ask_question", %Config{} = config, _terminal, arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, category} <- required_argument(arguments, "category"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, why_needed} <- required_argument(arguments, "why_needed"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, asked_by_agent_run_id} <- optional_string_argument(arguments, "asked_by_agent_run_id"),
         {:ok, _work_request, _filters, scope} <- scoped_work_request(config.repo, work_request_id),
         {:ok, question_record} <-
           WorkRequestService.ask_question(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "category" => category,
                 "question" => question,
                 "why_needed" => why_needed
               },
               "decision_prompt",
               decision_prompt
             )
             |> optional_put("asked_by_agent_run_id", asked_by_agent_run_id)
           ),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("ask_question", reason)
      {:error, :not_found} -> not_found_error("ask_question")
      {:error, reason} -> architect_error(reason, "ask_question")
    end
  end

  def call("record_decision", %Config{} = config, terminal, arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", terminal_name(terminal)),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, _work_request, _filters, scope} <- scoped_work_request(config.repo, work_request_id),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "source_type" => source_type,
                 "decision" => decision,
                 "rationale" => rationale,
                 "scope_impact" => scope_impact,
                 "created_by" => created_by
               },
               "source_id",
               source_id
             )
           ),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_decision", reason)
      {:error, :not_found} -> not_found_error("record_decision")
      {:error, reason} -> architect_error(reason, "record_decision")
    end
  end

  def call("edit_plan", %Config{} = config, terminal, arguments) do
    tool = "edit_plan"
    created_by = terminal_name(terminal)

    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, ops} <- edit_plan_ops(arguments),
         {:ok, _work_request, _filters, scope} <- scoped_work_request(config.repo, work_request_id),
         {:ok, {applied, graph}} <-
           mutate_product_tree(config.repo, work_request_id, tool, created_by, fn ->
             apply_plan_edit(config.repo, work_request_id, ops, created_by)
           end) do
      WorkRequestService.notify_plan_changed()
      {:ok, ToolResult.agent_tool_result(%{"applied" => applied, "plan" => graph, "scope" => scope})}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, {:op_failed, index, op, reason}} -> edit_plan_op_error(index, op, reason)
      {:error, {:work_request_terminal, phase}} -> architect_error({:work_request_terminal, phase, nil}, tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("skip_work_package", %Config{} = config, terminal, arguments) do
    tool = "skip_work_package"

    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_request, work_package, _filters, scope} <-
           scoped_work_package(config.repo, work_request_id, work_package_id),
         :ok <- require_work_package_authoring_status(work_request, work_package.contract_revision),
         :ok <- require_mutable_work_package_contract(work_package),
         {:ok, work_package} <-
           mutate_product_tree(config.repo, work_request_id, tool, terminal_name(terminal), fn ->
             WorkRequestService.skip_work_package(config.repo, work_request_id, work_package_id)
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package_id" => work_package.id,
         "scope" => scope,
         "status" => %{"work_package_status" => work_package.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp require_work_package_authoring_status(%WorkRequest{archived_at: %DateTime{}}, revision),
    do: {:error, {:work_request_archived, revision}}

  defp require_work_package_authoring_status(%WorkRequest{operator_completed_at: %DateTime{}}, revision),
    do: {:error, {:work_request_terminal, "done", revision}}

  defp require_work_package_authoring_status(%WorkRequest{}, _revision), do: :ok

  defp require_mutable_work_package_contract(%WorkPackage{status: status} = work_package) do
    cond do
      Lifecycle.ended?(work_package) -> {:error, {:work_package_terminal, status, work_package.contract_revision}}
      Lifecycle.ready?(work_package) -> {:error, {:contract_frozen, status, work_package.contract_revision}}
      true -> :ok
    end
  end

  defp edit_plan_ops(arguments) do
    case Map.get(arguments, "ops") do
      [_ | _] = ops -> if Enum.all?(ops, &is_map/1), do: {:ok, ops}, else: {:tool_error, "invalid_ops"}
      _ops -> {:tool_error, "invalid_ops"}
    end
  end

  defp apply_plan_edit(repo, work_request_id, ops, created_by) do
    with {:ok, applied} <- WorkRequestService.edit_plan(repo, work_request_id, ops, created_by),
         {:ok, graph} <- effective_graph(repo, work_request_id) do
      {:ok, {applied, graph}}
    end
  end

  # Names the failing operation, what state blocked it and what to do next. The
  # whole edit was rolled back.
  defp edit_plan_op_error(index, op, %Ecto.Changeset{} = changeset) do
    {:error, code, message, data} = changeset_invalid_params_error("edit_plan", "invalid_work_package", changeset)
    {:error, code, message, Map.merge(data, op_error_fields(index, op, "Fix the listed fields and resend the whole edit."))}
  end

  defp edit_plan_op_error(index, op, reason) do
    {details, next_action} = op_error_details(reason)
    data = %{"tool" => "edit_plan", "reason" => op_error_reason(reason)} |> Map.merge(details) |> Map.merge(op_error_fields(index, op, next_action))
    {:error, -32_602, "Invalid params", data}
  end

  defp op_error_fields(index, op, next_action) do
    %{"op_index" => index, "op" => op, "next_action" => next_action, "applied" => "none: the whole edit was rolled back"}
  end

  defp op_error_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp op_error_reason({reason, _first, _second}) when is_atom(reason), do: Atom.to_string(reason)
  defp op_error_reason(reason), do: reason_text(reason)

  defp op_error_details({:invalid_op, ops}), do: {%{"allowed_ops" => ops}, "Set op to one of the allowed ops."}
  defp op_error_details({:invalid_field, field}), do: {%{"field" => field}, "Give #{field} a valid value."}
  defp op_error_details({:duplicate_key, key}), do: {%{"key" => key}, "Use a key not already used by an earlier add_package."}

  defp op_error_details({:unknown_work_package, ref}),
    do: {%{"work_package_ref" => ref}, "Use a WorkPackage id from read_work_request view: plan, or the key of an earlier add_package."}

  defp op_error_details({:self_dependency, id}), do: {%{"work_package_id" => id}, "A package cannot depend on itself."}

  defp op_error_details({:incomplete_contract, missing}),
    do: {%{"missing" => missing}, "Give title and goal, and acceptance_criteria, validation_steps and stop_conditions as lists of strings."}

  defp op_error_details({:revision_conflict, status, revision}),
    do: {%{"state" => status, "current_revision" => revision}, "Re-read with read_work_request view: package, then retry with expected_revision #{revision}."}

  defp op_error_details({:contract_frozen, revision}),
    do:
      {%{"state" => "ready", "current_revision" => revision},
       "A ready package's contract is frozen. Add a successor with edit_plan add_package, then end this one with record_work_package_delivery outcome: superseded."}

  defp op_error_details({:work_package_ended, revision}),
    do: {%{"state" => "ended", "current_revision" => revision}, "An ended package cannot change. Add a successor with edit_plan add_package."}

  defp op_error_details({:dependency_not_found, from, to}), do: {%{"from" => from, "to" => to}, "Nothing to remove: #{from} does not depend on #{to}."}
  defp op_error_details(:open_questions), do: {%{}, "Answer or close the open clarification questions, then resend the edit."}
  defp op_error_details(:invalid_work_package), do: {%{"allowed_kinds" => WorkPackage.kinds()}, "Use an executable package kind."}
  defp op_error_details(:database_busy), do: {%{}, "Another write held the ledger. Resend the edit."}
  defp op_error_details(_reason), do: {%{}, "Fix the operation and resend the whole edit."}

  # The plan after the edit: each package with its group, status, revision and
  # what it depends on, plus any cycles.
  defp effective_graph(repo, work_request_id) do
    with {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request_id),
         {:ok, graph} <- ExecutionGraph.evaluate(repo, work_request_id, work_packages) do
      depends_on =
        Enum.group_by(graph.effective_edges, & &1.dependent_work_package_id, & &1.prerequisite_work_package_id)

      ready_ids = MapSet.new(graph.dependency_ready_work_package_ids)

      packages =
        Enum.map(work_packages, fn package ->
          %{
            "id" => package.id,
            "title" => package.title,
            "group" => package.group,
            "status" => package.status,
            "revision" => package.contract_revision,
            "depends_on" => Map.get(depends_on, package.id, []),
            "next_action" => Lifecycle.next_action(package, %{dependencies_met?: MapSet.member?(ready_ids, package.id)}).action
          }
        end)

      {:ok, %{"work_packages" => packages} |> optional_put("cycles", if(graph.cycles == [], do: nil, else: graph.cycles))}
    end
  end

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with :ok <- require_unarchived_in_transaction(repo, work_request_id),
           {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
        {:ok, result}
      end
    end)
  end

  # The authoring check before the transaction answers early; this one makes the
  # refusal atomic with the write.
  defp require_unarchived_in_transaction(repo, work_request_id) do
    case repo.get(WorkRequest, work_request_id) do
      %WorkRequest{archived_at: %DateTime{}} -> {:error, {:work_request_archived, nil}}
      _work_request -> :ok
    end
  end

  defp record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
    case Dashboard.work_request_detail(repo, work_request_id) do
      {:ok, detail} ->
        record_product_tree_revision(repo, work_request_id, tool, created_by, detail)

      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
    end
  end

  defp record_product_tree_revision(repo, work_request_id, tool, created_by, detail) do
    snapshot = product_tree_revision_snapshot(detail.product_tree)
    tree = ProductTree.tree_for_work_request(repo, work_request_id)

    if match?({:ok, %{latest_revision: %{tree_snapshot: ^snapshot}}}, tree) do
      {:ok, nil}
    else
      insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot)
    end
  end

  defp insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot) do
    case ProductTree.record_revision(repo, work_request_id, %{
           "reason" => product_tree_revision_reason(tool),
           "created_by" => created_by,
           "tree_snapshot" => snapshot
         }) do
      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error

      result ->
        result
    end
  end

  defp missing_product_tree_schema_error?({:storage_failed, message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
  end

  defp missing_product_tree_schema_error?(_reason), do: false

  defp product_tree_revision_snapshot(product_tree) do
    product_tree
    |> json_safe_payload()
    |> Map.delete("latest_revision")
    |> Map.delete("execution_graph")
  end

  defp product_tree_revision_reason("edit_plan"), do: "Plan edited through MCP."
  defp product_tree_revision_reason("skip_work_package"), do: "WorkPackage skipped in product tree through MCP."

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp optional_decision_prompt_argument(arguments, key) do
    with {:ok, prompt} <- optional_object_argument(arguments, key) do
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:tool_error, "#{key} #{HumanDecisionPrompt.error_message(reason)}"}
      end
    end
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp terminal_name(%Terminal{display_address: address}), do: address

  defp scoped_work_request(repo, work_request_id) do
    with {:ok, work_request, filters} <- WorkRequestScope.work_request_scope(repo, work_request_id) do
      {:ok, work_request, filters, WorkRequestPayloads.redacted_work_request_scope(work_request)}
    end
  end

  defp scoped_work_package(repo, work_request_id, work_package_id) do
    case WorkRequestScope.work_package_scope(repo, work_request_id, work_package_id) do
      {:ok, work_request, work_package} ->
        scope = WorkRequestPayloads.redacted_work_request_scope(work_request)
        {:ok, work_request, work_package, %{}, scope}

      error ->
        error
    end
  end

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)

  defp architect_error({:work_request_archived, revision}, tool) do
    ErrorDetails.lifecycle_error(tool, :work_request_archived, optional_put(%{"phase" => "archived"}, "current_contract_revision", revision))
  end

  defp architect_error({:work_request_terminal, phase, revision}, tool) do
    ErrorDetails.lifecycle_error(tool, :work_request_terminal, optional_put(%{"phase" => phase}, "current_contract_revision", revision))
  end

  defp architect_error({:contract_frozen, status, revision}, tool) do
    ErrorDetails.lifecycle_error(tool, :contract_frozen, %{
      "actual_status" => reason_text(status),
      "allowed_authoring_states" => @work_package_authoring_states,
      "current_contract_revision" => revision
    })
  end

  defp architect_error({reason, status, revision}, tool)
       when reason in [:contract_revision_conflict, :work_package_terminal] do
    ErrorDetails.lifecycle_error(tool, reason, %{
      "actual_status" => reason_text(status),
      "allowed_authoring_states" => if(tool == "skip_work_package", do: ["planned"], else: @work_package_authoring_states),
      "current_contract_revision" => revision
    })
  end

  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error(:open_questions, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "open_questions",
       "message" => "Answer or close all open clarification questions before adding WorkPackages."
     }}
  end

  defp architect_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
  end

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}

  defp auth_error({:unauthorized, reason}, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}

  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
