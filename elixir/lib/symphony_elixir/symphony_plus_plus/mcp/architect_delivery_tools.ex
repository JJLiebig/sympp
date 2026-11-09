defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectDeliveryTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2
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
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @tools ["sync_pr", "close_work_package"]

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t() | nil, map()) :: mcp_tool_result()
  def call("sync_pr", %Config{} = config, %Terminal{} = terminal, arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
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

  # Any chief or architect may close a package as finished (its PR waits on
  # someone else); the server requires ownership of the WorkRequest for every
  # other outcome before this runs.
  def call("close_work_package", %Config{} = config, %Terminal{} = terminal, arguments) do
    tool = "close_work_package"

    with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, outcome} <- close_outcome(arguments),
         {:ok, attrs} <- close_attrs(arguments, work_package_id, outcome, terminal),
         {:ok, work_request_id} <- work_request_id_argument(config.repo, arguments),
         {:ok, work_request, _work_package} <- WorkRequestScope.work_package_scope(config.repo, work_request_id, work_package_id),
         :ok <- require_successor_in_work_request(config.repo, work_request, attrs),
         {:ok, delivery} <- close(config.repo, work_request_id, work_package_id, attrs, terminal),
         {:ok, work_package} <- WorkPackageRepository.get(config.repo, work_package_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package" => work_package_payload(work_package),
         "work_package_delivery" => WorkRequestPayloads.work_package_delivery(delivery),
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request)
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> close_error(reason)
    end
  end

  # The same close repeated by any terminal allowed to make it (the owner, or
  # any chief or architect for finished) returns the ending it recorded; only
  # the outcome and its evidence identify it. Ownership is checked first.
  defp close(repo, work_request_id, work_package_id, attrs, terminal) do
    existing = repo.get_by(WorkPackageDelivery, work_package_id: work_package_id)

    if existing && same_close?(existing, attrs),
      do: {:ok, existing},
      else: record_close(repo, work_request_id, work_package_id, attrs, terminal)
  end

  defp same_close?(%WorkPackageDelivery{outcome: outcome} = existing, %{"outcome" => outcome} = attrs) do
    outcome |> close_fields() |> Map.values() |> Enum.all?(&(Map.get(existing, String.to_existing_atom(&1)) == attrs[&1]))
  end

  defp same_close?(_existing, _attrs), do: false

  defp record_close(repo, work_request_id, work_package_id, attrs, terminal) do
    with {:ok, {delivery, cleanup_work_package, closeout_context}} <-
           mutate_product_tree(repo, work_request_id, "close_work_package", terminal_name(terminal), fn ->
             DeliveryCloseout.record_in_transaction(repo, work_request_id, work_package_id, attrs)
           end) do
      DashboardPubSub.broadcast_changed()
      :ok = DeliveryCloseout.cleanup_after_commit(repo, cleanup_work_package, delivery, closeout_context)
      {:ok, delivery}
    end
  end

  defp close_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in WorkPackageDelivery.close_outcomes(),
        do: {:ok, outcome},
        else: {:tool_error, {:invalid_enum, "outcome", WorkPackageDelivery.close_outcomes()}}
    end
  end

  # The tool's arguments, and the ending-row fields each one fills, per outcome.
  # Every listed argument is required for its outcome.
  defp close_fields("completed_no_pr"), do: %{"evidence" => "no_pr_evidence"}
  defp close_fields("superseded"), do: %{"successor_work_package_id" => "successor_work_package_id", "rationale" => "superseded_reason"}
  defp close_fields("abandoned"), do: %{"rationale" => "abandoned_rationale"}
  defp close_fields(_skipped_or_finished), do: %{}

  defp close_attrs(arguments, work_package_id, outcome, %Terminal{} = terminal) do
    with {:ok, supplied} <- close_evidence_arguments(arguments),
         {:ok, key} <- optional_string_argument(arguments, "idempotency_key", "close_work_package:#{work_package_id}:#{outcome}") do
      fields = close_fields(outcome)
      missing = fields |> Map.keys() |> Enum.reject(&Map.has_key?(supplied, &1)) |> Enum.sort()
      unused = supplied |> Map.keys() |> Enum.reject(&Map.has_key?(fields, &1)) |> Enum.sort()

      cond do
        missing != [] -> {:tool_error, {:close_argument, "missing_#{hd(missing)}", outcome, missing}}
        unused != [] -> {:tool_error, {:close_argument, "argument_not_used", outcome, unused}}
        true -> {:ok, close_row(supplied, fields, outcome, key, terminal)}
      end
    end
  end

  defp close_evidence_arguments(arguments) do
    Enum.reduce_while(["evidence", "successor_work_package_id", "rationale"], {:ok, %{}}, fn name, {:ok, supplied} ->
      case optional_string_argument(arguments, name) do
        {:ok, nil} -> {:cont, {:ok, supplied}}
        {:ok, value} -> {:cont, {:ok, Map.put(supplied, name, value)}}
        {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      end
    end)
  end

  defp close_row(supplied, fields, outcome, key, %Terminal{display_address: recorded_by}) do
    Enum.reduce(supplied, %{"outcome" => outcome, "idempotency_key" => key, "recorded_by" => recorded_by}, fn {name, value}, row ->
      Map.put(row, Map.fetch!(fields, name), value)
    end)
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

  defp run_architect_transaction(repo, fun, notify?) do
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

  defp product_tree_revision_reason("close_work_package"), do: "WorkPackage closed through MCP."

  defp close_error(%Ecto.Changeset{} = changeset),
    do: changeset_invalid_params_error("close_work_package", "invalid_work_package_delivery", changeset)

  defp close_error({:delivery_outcome_conflict, outcome}),
    do: close_refused("delivery_outcome_conflict", "ended", outcome, "none")

  defp close_error({:ending_not_allowed, status, outcome}),
    do: close_refused("ending_not_allowed", status, outcome, nil)

  defp close_error(:idempotency_key_conflict),
    do: {:error, -32_602, "Invalid params", %{"tool" => "close_work_package", "reason" => "idempotency_key_conflict"}}

  defp close_error(reason), do: architect_error(reason, "close_work_package")

  defp close_refused(reason, state, outcome, next_action) do
    data =
      %{"tool" => "close_work_package", "reason" => reason, "state" => state, "outcome" => outcome}
      |> optional_put("next_action", next_action)
      |> optional_put("allowed_outcomes", allowed_close_outcomes(state))

    {:error, -32_009, "Precondition Failed", data}
  end

  defp allowed_close_outcomes("ended"), do: nil
  defp allowed_close_outcomes(status), do: Enum.filter(WorkPackageDelivery.close_outcomes(), &(status in Lifecycle.ending_sources(&1)))

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

  defp architect_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"state" => "archived"})

  defp architect_error(reason, tool),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

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

  defp invalid_params_error(tool, {:close_argument, reason, outcome, arguments}),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason, "outcome" => outcome, "arguments" => arguments}}

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

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
