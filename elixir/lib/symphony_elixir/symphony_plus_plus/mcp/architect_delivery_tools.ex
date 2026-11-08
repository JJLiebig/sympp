defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectDeliveryTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_boolean: 3,
      optional_object_argument: 2,
      optional_positive_integer_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      required_object: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      json_safe_payload: 1,
      work_package_payload: 1
    ]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectPRSync,
    Config,
    ErrorDetails,
    ProgressEvents,
    ToolArguments,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope,
    WorktreeScope,
    Writer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @tools ["reconcile_work_request", "attach_branch", "sync_pr", "record_work_package_delivery"]

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t() | nil, map()) :: mcp_tool_result()
  def call("reconcile_work_request", %Config{} = config, terminal, arguments) do
    with {:ok, apply?} <- optional_boolean(arguments, "apply", false),
         {:ok, arguments} <- validate_arguments(arguments, "reconcile_work_request"),
         {:ok, detail} <- reconcile_detail_argument(arguments),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", terminal_name(terminal)),
         {:ok, work_request, _filters} <- WorkRequestScope.work_request_scope(config.repo, work_request_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {visible_work_package_ids, work_package_contexts} <-
           WorkRequestScope.visible_delivery_board_work_package_contexts(config.repo, work_request, work_packages),
         {:ok, reconciliation} <-
           reconcile_work_request(config.repo, terminal, work_request_id, apply?, recorded_by,
             mode: reconcile_work_request_mode(apply?),
             work_request: work_request,
             work_packages: work_packages,
             visible_work_package_ids: visible_work_package_ids,
             work_package_contexts: work_package_contexts
           ) do
      {:ok, reconcile_work_request_result(work_request, reconciliation, detail, scope)}
    else
      error -> reconcile_work_request_error(error)
    end
  end

  def call("sync_pr", %Config{} = config, %Terminal{} = terminal, arguments) do
    with {:ok, arguments} <- validate_arguments(arguments, "sync_pr"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_request, work_package} <- WorkRequestScope.work_package_scope(config.repo, work_request_id, work_package_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         {:ok, pr_sync} <- ArchitectPRSync.sync(config.repo, Actor.from_terminal(terminal), work_package, arguments),
         {:ok, result} <- architect_sync_pr_result(config.repo, work_package.id, pr_sync, scope) do
      {:ok, result}
    else
      {:tool_error, reason} -> invalid_params_error("sync_pr", reason)
      {:error, :not_found} -> not_found_error("sync_pr")
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> architect_error(reason, "sync_pr")
    end
  end

  def call("attach_branch", %Config{} = config, %Terminal{} = terminal, arguments) do
    with {:ok, arguments} <- validate_arguments(arguments, "attach_branch"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_request, work_package} <- WorkRequestScope.work_package_scope(config.repo, work_request_id, work_package_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         writer = Writer.new(terminal, work_package.id),
         {:ok, branch} <- architect_attach_branch_argument(work_package, arguments),
         {:ok, head_sha} <- required_argument(arguments, "head_sha"),
         {:ok, _idempotency_key, attrs} <-
           ProgressEvents.metadata_attrs(writer, Map.drop(arguments, ["work_request_id", "work_package_id"]), "attach_branch", "branch_attached", %{
             "type" => "branch",
             "branch" => branch,
             "head_sha" => head_sha
           }),
         attrs = Map.update!(attrs, "idempotency_key", &("attach_branch:#{work_package.id}:" <> &1)),
         {:ok, event} <-
           PlanningRepository.append_audit_progress_event_for_work_package(config.repo, writer.actor, work_package.id, attrs) do
      {:ok, ToolResult.agent_tool_result(%{"progress_event" => ProgressEvents.payload(event), "scope" => scope})}
    else
      error -> attach_branch_error(error)
    end
  end

  # Any chief or architect may end a package as finished (it waits on someone
  # else); the server requires ownership of the WorkRequest for every other
  # outcome before this runs.
  def call("record_work_package_delivery", %Config{} = config, %Terminal{} = terminal, arguments) do
    with {:ok, arguments} <- validate_arguments(arguments, "record_work_package_delivery"),
         {:ok, work_request_id} <- work_request_id_argument(config.repo, arguments),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, outcome} <- required_work_package_delivery_outcome(arguments),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", terminal_name(terminal)),
         {:ok, attrs} <- work_package_delivery_attrs(arguments, outcome, idempotency_key, recorded_by),
         {:ok, work_request, _work_package} <- WorkRequestScope.work_package_scope(config.repo, work_request_id, work_package_id),
         scope = WorkRequestPayloads.redacted_work_request_scope(work_request),
         :ok <- require_successor_in_work_request(config.repo, work_request, attrs),
         {:ok, {delivery, cleanup_work_package, closeout_context}} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             "record_work_package_delivery",
             recorded_by,
             fn ->
               DeliveryCloseout.record_in_transaction(
                 config.repo,
                 work_request_id,
                 work_package_id,
                 attrs
               )
             end
           ),
         _delivery_broadcast_result <- DashboardPubSub.broadcast_changed(),
         :ok <-
           DeliveryCloseout.cleanup_after_commit(
             config.repo,
             cleanup_work_package,
             delivery,
             closeout_context
           ),
         _cleanup_broadcast_result <- DashboardPubSub.broadcast_changed(),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, work_packages) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "work_package_delivery" => WorkRequestPayloads.work_package_delivery(delivery),
         "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_work_package_delivery", reason)
      {:error, :not_found} -> not_found_error("record_work_package_delivery")
      {:error, reason} -> record_work_package_delivery_error(reason)
    end
  end

  defp required_work_package_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in WorkPackageDelivery.outcomes() do
        {:ok, outcome}
      else
        {:tool_error, {:invalid_enum, "outcome", WorkPackageDelivery.outcomes()}}
      end
    end
  end

  defp work_package_delivery_attrs(arguments, outcome, idempotency_key, recorded_by) do
    with {:ok, evidence} <- optional_object_argument(arguments, "evidence"),
         {:ok, evidence_attrs} <- work_package_delivery_evidence_attrs(evidence || %{}, outcome) do
      {:ok,
       Map.merge(
         %{
           "outcome" => outcome,
           "idempotency_key" => idempotency_key,
           "recorded_by" => recorded_by
         },
         evidence_attrs
       )}
    end
  end

  defp work_package_delivery_evidence_attrs(evidence, outcome) do
    case Map.keys(evidence) do
      [^outcome] ->
        with {:ok, typed_evidence} <- required_object(evidence, outcome) do
          work_package_delivery_typed_evidence_attrs(outcome, typed_evidence)
        end

      [] ->
        work_package_delivery_typed_evidence_attrs(outcome, %{})

      _keys ->
        {:tool_error, "conflicting_delivery_evidence"}
    end
  end

  defp work_package_delivery_typed_evidence_attrs(outcome, evidence) do
    case WorkPackageDelivery.validate_evidence(outcome, evidence) do
      :ok ->
        collect_work_package_delivery_evidence_attrs(
          evidence,
          WorkPackageDelivery.evidence_field_specs(outcome)
        )

      {:error, details} ->
        {:tool_error, {:invalid_evidence, details}}
    end
  end

  defp collect_work_package_delivery_evidence_attrs(evidence, field_specs) do
    Enum.reduce_while(field_specs, {:ok, %{}}, fn %{name: field, type: type}, {:ok, attrs} ->
      case work_package_delivery_evidence_field(evidence, field, type) do
        {:ok, value} -> {:cont, {:ok, optional_put(attrs, field, value)}}
        {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      end
    end)
  end

  defp work_package_delivery_evidence_field(evidence, field, :string), do: optional_string_argument(evidence, field)

  defp work_package_delivery_evidence_field(evidence, field, :positive_integer),
    do: optional_positive_integer_argument(evidence, field)

  defp reconcile_detail_argument(arguments) do
    case optional_string_argument(arguments, "detail", "summary") do
      {:ok, detail} when detail in ["summary", "full"] -> {:ok, detail}
      {:ok, _detail} -> {:tool_error, "invalid_detail"}
      error -> error
    end
  end

  defp reconcile_work_request_result(%WorkRequest{} = work_request, reconciliation, detail, scope) do
    payload = %{
      "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
      "reconciliation" => reconciliation_payload(reconciliation, detail),
      "delivery_board" =>
        reconciliation.delivery_board
        |> WorkRequestPayloads.delivery_board(detail)
        |> then(fn board -> if detail == "full", do: board, else: Map.delete(board, "work_packages") end),
      "detail" => detail,
      "scope" => scope
    }

    ToolResult.with_text_profile(:full, fn -> ToolResult.read_tool_result(payload) end)
  end

  defp reconcile_work_request_error({:tool_error, reason}),
    do: {:error, -32_602, "Invalid params", %{"tool" => "reconcile_work_request", "reason" => reason}}

  defp reconcile_work_request_error({:error, :not_found}), do: not_found_error("reconcile_work_request")
  defp reconcile_work_request_error({:error, reason}), do: architect_error(reason, "reconcile_work_request")

  defp validate_arguments(arguments, tool) do
    case ToolArguments.architect_tool_arguments(%{"arguments" => arguments}, tool) do
      {:ok, arguments} -> {:ok, arguments}
      {:error, _code, _message, %{"reason" => reason}} -> {:tool_error, reason}
    end
  end

  defp reconcile_work_request_mode(true), do: :apply
  defp reconcile_work_request_mode(false), do: :dry_run

  defp architect_attach_branch_argument(%WorkPackage{} = work_package, arguments) do
    case optional_string_argument(arguments, "branch") do
      {:ok, nil} -> WorktreeScope.prepared_branch(work_package)
      result -> result
    end
  end

  defp architect_sync_pr_result(repo, work_package_id, %{status: status} = pr_sync, scope)
       when status in ["merged", "already_merged", "dispatched", "ready"] do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package" => work_package_payload(work_package),
         "pr_sync" => json_safe_payload(pr_sync),
         "scope" => scope
       })}
    end
  end

  defp architect_sync_pr_result(_repo, _work_package_id, pr_sync, _scope) do
    data =
      pr_sync
      |> json_safe_payload()
      |> Map.take(~w(reason expected_repository actual_repository expected_base_branch actual_base_branch expected_head_sha actual_head_sha delivery_error))
      |> Map.put("tool", "sync_pr")
      |> Map.put_new("reason", "terminal_pr_sync_failed")

    {:error, -32_602, "Invalid params", data}
  end

  defp reconcile_work_request(repo, %Terminal{} = terminal, work_request_id, true = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)
    opts = Keyword.put(opts, :append_blocker_closeout_event, reconcile_blocker_closeout_appender(terminal))

    run_architect_transaction(repo, fn ->
      with {:ok, reconciliation} <- DeliveryReconciler.reconcile(repo, work_request_id, opts) do
        record_reconcile_product_tree_revision_after_apply(repo, work_request_id, recorded_by, reconciliation)
      end
    end)
  end

  defp reconcile_work_request(repo, _terminal, work_request_id, false = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)

    DeliveryReconciler.reconcile(repo, work_request_id, opts)
  end

  defp record_reconcile_product_tree_revision_after_apply(repo, work_request_id, recorded_by, reconciliation) do
    with {:ok, _revision} <-
           maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
      {:ok, reconciliation}
    end
  end

  defp reconcile_blocker_closeout_appender(%Terminal{} = terminal) do
    actor = Actor.from_terminal(terminal)

    fn repo, work_package_id, attrs ->
      PlanningRepository.append_audit_progress_event_for_work_package(repo, actor, work_package_id, attrs)
    end
  end

  defp maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
    if reconcile_product_tree_revision_required?(reconciliation) do
      record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)
    else
      {:ok, nil}
    end
  end

  defp reconcile_product_tree_revision_required?(%{applied_count: count}) when count > 0, do: true

  defp reconcile_product_tree_revision_required?(%{results: results}) when is_list(results) do
    Enum.any?(results, &reconcile_result_has_delivery_closeout?/1)
  end

  defp reconcile_result_has_delivery_closeout?(%{reason: "already_closeout", work_package_status: status})
       when is_binary(status),
       do: true

  defp reconcile_result_has_delivery_closeout?(_result), do: false

  defp work_request_id_argument(repo, arguments) do
    case Map.get(arguments, "work_request_id") do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _derived_from_package ->
        with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
             {:ok, %WorkPackage{work_request_id: id}} when is_binary(id) <- WorkPackageRepository.get(repo, work_package_id) do
          {:ok, id}
        else
          {:ok, %WorkPackage{}} -> {:error, :not_found}
          error -> error
        end
    end
  end

  defp require_successor_in_work_request(repo, %WorkRequest{} = work_request, attrs) do
    case Map.get(attrs, "successor_work_package_id") do
      nil ->
        :ok

      successor_work_package_id ->
        case WorkRequestService.get_work_package(repo, work_request.id, successor_work_package_id) do
          {:ok, _successor} -> :ok
          {:error, :not_found} -> {:tool_error, "successor_work_package_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp terminal_name(%Terminal{display_address: address}), do: address
  defp terminal_name(nil), do: "architect"

  defp run_architect_transaction(repo, fun, notify? \\ true) do
    result =
      case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
        {:ok, result} -> {:ok, result}
        {:error, {:tool_error, reason}} -> {:tool_error, reason}
        {:error, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end

    if notify?, do: DashboardPubSub.broadcast_changed_on_success(result), else: result
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(
      repo,
      fn ->
        with {:ok, result} <- mutation_fun.(),
             {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
          {:ok, result}
        end
      end,
      false
    )
  end

  defp record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
    case Dashboard.work_request_detail(repo, work_request_id) do
      {:ok, detail} -> record_product_tree_revision(repo, work_request_id, tool, created_by, detail)
      {:error, reason} = error -> if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
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
      {:error, reason} = error -> if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
      result -> result
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

  defp product_tree_revision_reason("record_work_package_delivery"),
    do: "WorkPackage delivery recorded in product tree through MCP."

  defp product_tree_revision_reason("reconcile_work_request"),
    do: "WorkPackage delivery reconciled in product tree through MCP."

  defp record_work_package_delivery_error(%Ecto.Changeset{} = changeset),
    do: changeset_invalid_params_error("record_work_package_delivery", "invalid_work_package_delivery", changeset)

  defp record_work_package_delivery_error({:delivery_outcome_conflict, outcome}) do
    {:error, -32_602, "Invalid params", %{"tool" => "record_work_package_delivery", "reason" => "delivery_outcome_conflict", "state" => "ended", "outcome" => outcome}}
  end

  defp record_work_package_delivery_error({:ending_not_allowed, status, outcome}) do
    {:error, -32_009, "Precondition Failed",
     %{
       "tool" => "record_work_package_delivery",
       "reason" => "ending_not_allowed",
       "reason_code" => "ending_not_allowed",
       "state" => status,
       "outcome" => outcome,
       "allowed_outcomes" => Enum.filter(WorkPackageDelivery.outcomes(), &(status in Lifecycle.ending_sources(&1)))
     }}
  end

  defp record_work_package_delivery_error(reason)
       when reason in [:missing_strong_pr_evidence, :idempotency_key_conflict] do
    data = %{"tool" => "record_work_package_delivery", "reason" => Atom.to_string(reason)}
    {:error, -32_602, "Invalid params", data}
  end

  defp record_work_package_delivery_error(:active_runtime),
    do: delivery_closeout_precondition_error("record_work_package_delivery", :active_runtime)

  defp record_work_package_delivery_error(reason), do: architect_error(reason, "record_work_package_delivery")

  defp delivery_closeout_precondition_error(tool, reason) when is_atom(reason),
    do: precondition_error(tool, Atom.to_string(reason))

  defp precondition_error(tool, reason) do
    {:error, -32_009, "Precondition Failed",
     %{
       "tool" => tool,
       "reason" => reason,
       "reason_code" => reason,
       "decision_reason" => "precondition_denied",
       "next_action" => precondition_next_action(tool, reason)
     }}
  end

  defp precondition_next_action("record_work_package_delivery", "active_runtime"),
    do: "release_worker_or_retry_after_stale"

  defp precondition_next_action("record_work_package_delivery", _reason), do: "retry_record_work_package_delivery"
  defp precondition_next_action(_tool, _reason), do: "retry_after_runtime_state_changes"

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error({:provider_head_mismatch, expected, actual}, tool),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "provider_head_mismatch", "expected_head_sha" => expected, "actual_head_sha" => actual}}

  defp architect_error(reason, tool),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp attach_branch_error({:tool_error, reason}), do: ErrorDetails.invalid_params_error("attach_branch", reason)
  defp attach_branch_error({:error, :not_found}), do: not_found_error("attach_branch")
  defp attach_branch_error({:error, reason}), do: architect_error(reason, "attach_branch")

  defp auth_error(:unauthorized, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}

  defp auth_error({:unauthorized, reason}, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource),
    do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}

  defp service_error(_reason, resource),
    do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}

  defp invalid_params_error(tool, {:invalid_changeset, reason, %Ecto.Changeset{} = changeset}) do
    changeset_invalid_params_error(tool, reason, changeset)
  end

  defp invalid_params_error(tool, {:invalid_evidence, details}) do
    {:error, -32_602, "Invalid params",
     details
     |> Map.put("tool", tool)
     |> Map.put("reason", "invalid_evidence")}
  end

  defp invalid_params_error(tool, {:invalid_enum, _field, _allowed_values} = reason) do
    ErrorDetails.invalid_params_error(tool, reason)
  end

  defp invalid_params_error(tool, reason),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
  end

  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp reconciliation_payload(reconciliation, detail) when is_map(reconciliation) do
    reconciliation
    |> Map.drop([:delivery_board, "delivery_board"])
    |> Map.update!(:results, fn results ->
      if detail == "full", do: results, else: Enum.filter(results, &(&1.status in ["proposed", "applied", "error"]))
    end)
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
