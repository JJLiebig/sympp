defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ProgressEvents do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ErrorDetails
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Writer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyInputs
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @terminal_work_package_statuses ["ended"]

  @finding_replay_retry_attempts 50
  @ready_evidence_tools [
    "append_finding",
    "append_progress",
    "attach_branch",
    "sync_pr"
  ]

  @type repo :: module()
  @type mcp_error :: {:error, integer(), String.t(), map()}
  @type worker_result :: {:ok, map()} | {:tool_error, term()} | {:error, term()} | mcp_error()

  @spec append_or_replay(repo(), Writer.t(), map(), String.t(), String.t()) :: worker_result()
  def append_or_replay(repo, %Writer{} = writer, attrs, idempotency_key, tool) do
    append_or_replay(repo, writer, writer.work_package_id, attrs, idempotency_key, tool)
  end

  @spec append_or_replay(repo(), Writer.t(), String.t(), map(), String.t(), String.t()) :: worker_result()
  def append_or_replay(repo, %Writer{} = writer, work_package_id, attrs, idempotency_key, tool) do
    case existing(repo, writer, work_package_id, idempotency_key) do
      {:ok, event} -> replay(repo, writer, event, attrs, tool)
      {:error, :not_found} -> append_new_or_replay(repo, writer, work_package_id, attrs, idempotency_key, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp existing(repo, %Writer{} = writer, work_package_id, idempotency_key) do
    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           writer.actor.idempotency_scope
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> existing_work_package_progress_event(repo, work_package_id, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec existing_for_work_package(repo(), String.t(), String.t()) :: {:ok, ProgressEvent.t()} | {:error, term()}
  def existing_for_work_package(repo, work_package_id, idempotency_key) do
    existing_work_package_progress_event(repo, work_package_id, idempotency_key)
  end

  @spec metadata_attrs(Writer.t(), map(), String.t(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:tool_error, term()}
  def metadata_attrs(%Writer{} = writer, arguments, tool, status, payload) do
    payload = Map.put(payload, "source_tool", tool)

    arguments =
      Map.put_new(arguments, "summary", status)
      |> Map.put_new("status", status)
      |> Map.put_new("idempotency_key", metadata_idempotency_key(payload))
      |> canonical_metadata_event_status(tool, status)

    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         :ok <- validate_metadata_caller_payload(tool, caller_payload) do
      idempotency_key = scoped_idempotency_key(tool, String.trim(idempotency_key), writer)

      {:ok, idempotency_key,
       %{
         "summary" => summary,
         "body" => optional_argument(arguments, "body", nil),
         "status" => optional_argument(arguments, "status", "recorded"),
         "idempotency_key" => idempotency_key,
         "payload" => merge_payload(tool, caller_payload, payload)
       }}
    end
  end

  @spec scoped_idempotency_key(String.t(), String.t(), Writer.t()) :: String.t()
  def scoped_idempotency_key(tool, idempotency_key, %Writer{} = writer) when tool in ["attach_branch", "sync_pr"] do
    [tool, writer.work_package_id, idempotency_key] |> Enum.join(":")
  end

  def scoped_idempotency_key(tool, idempotency_key, %Writer{}), do: tool <> ":" <> idempotency_key

  @spec metadata_idempotency_key(map()) :: String.t()
  def metadata_idempotency_key(payload) do
    "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  @spec merge_payload(String.t(), map(), map()) :: map()
  def merge_payload("append_progress", caller_payload, tool_payload) do
    caller_payload
    |> drop_protected_append_progress_payload()
    |> Map.merge(tool_payload)
  end

  def merge_payload(_tool, caller_payload, tool_payload) when tool_payload == %{} do
    Map.drop(caller_payload, ["source_tool"])
  end

  def merge_payload(_tool, caller_payload, tool_payload), do: Map.merge(caller_payload, tool_payload)

  @spec payload(ProgressEvent.t() | nil) :: map() | nil
  def payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "idempotency_key" => Redactor.redact_text(event.idempotency_key),
      "payload" => Redactor.redact_output(event.payload || %{})
    }
  end

  def payload(nil), do: nil

  defp append_new_or_replay(repo, %Writer{} = writer, work_package_id, attrs, idempotency_key, tool) do
    transaction_fun = fn ->
      with :ok <- reject_ready_evidence_mutation(repo, writer, work_package_id, tool, attrs),
           :ok <- DependencyInputs.validate_progress(repo, work_package_id, attrs) do
        PlanningRepository.append_audit_progress_event_for_work_package(repo, writer.actor, work_package_id, attrs)
      end
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:ok, event} ->
        {:ok, ToolResult.agent_tool_result(%{"progress_event" => payload(event)})}

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}

      {:error, :idempotency_key_conflict} ->
        replay_with_retry(
          repo,
          writer,
          work_package_id,
          attrs,
          idempotency_key,
          tool,
          progress_replay_retry_attempts()
        )

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  @spec reject_ready_evidence_mutation(repo(), Writer.t(), String.t()) ::
          :ok | {:tool_error, term()} | {:error, term()}
  def reject_ready_evidence_mutation(repo, %Writer{} = writer, tool) when tool in @ready_evidence_tools do
    reject_ready_evidence_mutation(repo, writer, writer.work_package_id, tool)
  end

  def reject_ready_evidence_mutation(_repo, %Writer{}, _tool), do: :ok

  @spec reject_ready_evidence_mutation(repo(), Writer.t(), String.t(), String.t()) ::
          :ok | {:tool_error, term()} | {:error, term()}
  def reject_ready_evidence_mutation(repo, %Writer{} = writer, work_package_id, tool) when tool in @ready_evidence_tools do
    reject_ready_evidence_mutation(repo, writer, work_package_id, tool, %{})
  end

  def reject_ready_evidence_mutation(_repo, %Writer{}, _work_package_id, _tool), do: :ok

  defp reject_ready_evidence_mutation(repo, writer, work_package_id, tool, attrs) when tool in @ready_evidence_tools do
    with :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <- reject_terminal_target(work_package) do
      reject_ready_work_package(work_package, writer, tool, attrs)
    end
  end

  defp reject_ready_evidence_mutation(_repo, _session, _work_package_id, _tool, _attrs), do: :ok

  defp reject_ready_work_package(
         %WorkPackage{status: "ready"},
         %Writer{},
         "append_progress",
         %{"payload" => %{"type" => "blocker", "source_tool" => "report_blocker", "active" => true} = payload}
       ) do
    blocker_id = Map.get(payload, "blocker_id")

    cond do
      Map.has_key?(payload, "dependency_inputs") -> {:tool_error, "already_ready"}
      is_nil(blocker_id) -> :ok
      is_binary(blocker_id) and String.trim(blocker_id) != "" -> :ok
      true -> {:tool_error, "invalid_blocker_id"}
    end
  end

  defp reject_ready_work_package(%WorkPackage{status: "ready"}, _session, _tool, _attrs) do
    {:tool_error, "already_ready"}
  end

  defp reject_ready_work_package(%WorkPackage{}, _session, _tool, _attrs), do: :ok

  defp reject_terminal_target(%WorkPackage{status: status}) when status in @terminal_work_package_statuses,
    do: {:error, :work_package_terminal}

  defp reject_terminal_target(%WorkPackage{}), do: :ok

  defp replay_with_retry(repo, %Writer{} = writer, work_package_id, attrs, idempotency_key, tool, attempts_left) do
    retry_fun = fn ->
      replay_with_retry(repo, writer, work_package_id, attrs, idempotency_key, tool, attempts_left - 1)
    end

    repo
    |> replay(writer, work_package_id, attrs, idempotency_key, tool)
    |> retry_missing(retry_fun, attempts_left)
  end

  defp replay(_repo, %Writer{}, %ProgressEvent{} = event, attrs, tool), do: replay_matching(event, attrs, tool)

  defp replay(repo, %Writer{} = writer, work_package_id, attrs, idempotency_key, tool) do
    case existing(repo, writer, work_package_id, idempotency_key) do
      {:ok, event} -> replay(repo, writer, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp existing_work_package_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} -> matching_progress_event(progress_events, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_progress_event(progress_events, idempotency_key) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp retry_missing({:error, _code, _message, %{"reason" => "not_found"}}, retry_fun, attempts_left) when attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_missing(result, _retry_fun, _attempts_left), do: result

  defp replay_matching(%ProgressEvent{} = event, attrs, tool) do
    if progress_replay_matches?(event, attrs) do
      {:ok, ToolResult.agent_tool_result(%{"progress_event" => payload(event)})}
    else
      {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "idempotency_conflict"}}
    end
  end

  defp progress_replay_matches?(%ProgressEvent{} = event, attrs) do
    normalized_payload = normalized_progress_payload(event, attrs)

    event.summary == Map.get(attrs, "summary") and
      event.body == Map.get(attrs, "body") and
      event.status == Map.get(attrs, "status") and
      progress_payload_replay_matches?(event.payload, normalized_payload)
  end

  defp progress_payload_replay_matches?(%{"type" => "pr"} = existing, %{"type" => "pr"} = normalized) do
    existing = Map.drop(existing, ["head_changed_at", "checks_changed_at"])
    normalized = Map.drop(normalized, ["head_changed_at", "checks_changed_at"])
    absent_provider_dates = Enum.reject(["created_at", "updated_at"], &Map.has_key?(existing, &1))
    normalized = Map.drop(normalized, absent_provider_dates)

    existing == normalized
  end

  defp progress_payload_replay_matches?(existing, normalized), do: existing == normalized

  defp normalized_progress_payload(%ProgressEvent{} = event, attrs) do
    attrs
    |> Map.merge(%{
      "id" => "replay_probe",
      "work_package_id" => event.work_package_id,
      "sequence" => 1,
      "created_at" => event.created_at || DateTime.utc_now(:microsecond)
    })
    |> ProgressEvent.create_changeset(trusted_audit_metadata: true)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:payload)
  end

  defp canonical_metadata_event_status(arguments, _tool, _status), do: arguments

  defp validate_metadata_caller_payload(_tool, _caller_payload), do: :ok

  defp drop_protected_append_progress_payload(caller_payload) do
    Map.delete(caller_payload, "source_tool")
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp progress_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
  end

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp worker_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
