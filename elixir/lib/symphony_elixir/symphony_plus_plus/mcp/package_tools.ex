defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PackageTools do
  @moduledoc """
  Owner-gated writes and reads on one WorkPackage, named by `work_package_id`:
  task plan reads, findings and progress. The server
  checks that the caller owns the package's WorkRequest before these run.
  """

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [optional_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    ProgressEvents,
    TaskPlanTools,
    ToolResult,
    Writer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  @tools [
    "read_task_plan",
    "append_finding",
    "append_progress"
  ]
  @finding_replay_retry_attempts 50

  @typep result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Terminal.t() | nil, map()) :: result()
  def call("read_task_plan", %Config{} = config, _terminal, arguments) do
    with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, result} <- TaskPlanTools.read_task_plan(config.repo, work_package_id) do
      {:ok, result}
    else
      {:tool_error, reason} -> invalid_params_error("read_task_plan", reason)
      {:error, reason} -> worker_error(reason, "read_task_plan")
    end
  end

  def call(name, %Config{} = config, %Terminal{} = terminal, arguments) when name in @tools do
    case required_argument(arguments, "work_package_id") do
      {:ok, work_package_id} -> write(name, config.repo, Writer.new(terminal, work_package_id), arguments)
      {:tool_error, reason} -> invalid_params_error(name, reason)
    end
  end

  defp write("append_finding", repo, %Writer{} = writer, arguments), do: append_finding_for_package(repo, writer, arguments)

  defp write("append_progress", _repo, %Writer{}, %{"payload" => %{"type" => "architect_operator_report"}}) do
    {:error, -32_602, "Invalid params", %{"tool" => "append_progress", "reason" => "operator_report_moved", "next_action" => "set_report"}}
  end

  defp write("append_progress", repo, %Writer{} = writer, arguments) do
    payload =
      case Map.get(arguments, "payload") do
        %{"type" => "blocker", "active" => true} -> %{"type" => "blocker", "source_tool" => "report_blocker", "active" => true}
        _ordinary_progress -> %{}
      end

    append_progress_for_package(repo, writer, arguments, "append_progress", payload)
  end

  defp append_finding_for_package(repo, %Writer{} = writer, arguments) do
    work_package_id = writer.work_package_id

    with {:ok, title} <- required_argument(arguments, "title"),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         idempotency_key = String.trim(idempotency_key),
         {:ok, finding_id} <- optional_finding_id(arguments, writer, idempotency_key),
         attrs = %{
           "id" => finding_id,
           "work_package_id" => work_package_id,
           "title" => title,
           "body" => body,
           "severity" => optional_argument(arguments, "severity", "info"),
           "idempotency_key" => idempotency_key,
           "caller_supplied_id" => Map.has_key?(arguments, "id")
         },
         {:ok, finding} <- append_authenticated_idempotent_finding(repo, writer, finding_id, attrs) do
      {:ok, ToolResult.agent_tool_result(%{"finding" => %{"id" => finding.id, "title" => finding.title, "severity" => finding.severity}})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "append_finding", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "append_finding")
    end
  end

  defp append_authenticated_idempotent_finding(repo, %Writer{} = writer, finding_id, attrs) do
    work_package_id = writer.work_package_id

    transaction_fun = fn ->
      append_authenticated_idempotent_finding_tx(repo, writer, work_package_id, finding_id, attrs)
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:error, :finding_insert_conflict} ->
        replay_finding_after_insert_conflict(repo, work_package_id, finding_id, attrs)

      result ->
        result
    end
  end

  defp append_authenticated_idempotent_finding_tx(repo, %Writer{} = writer, work_package_id, finding_id, attrs) do
    with {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding(finding_id, attrs),
         {:error, :id_already_exists} <-
           repo
           |> PlanningRepository.list_findings(work_package_id)
           |> find_existing_finding_by_idempotency(attrs),
         :ok <- ProgressEvents.reject_ready_evidence_mutation(repo, writer, work_package_id, "append_finding") do
      case PlanningRepository.append_finding(repo, attrs) do
        {:ok, finding} ->
          {:ok, finding}

        {:error, reason} when reason in [:id_already_exists, :idempotency_key_conflict] ->
          {:error, :finding_insert_conflict}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp replay_finding_after_insert_conflict(repo, work_package_id, finding_id, attrs) do
    replay_attempts = finding_replay_retry_attempts()

    case find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, replay_attempts) do
      {:error, :id_already_exists} ->
        find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, replay_attempts)

      result ->
        result
    end
  end

  defp find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding(finding_id, attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding_by_idempotency(attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp retry_finding_replay_read({:error, reason}, retry_fun, attempts_left)
       when reason in [:id_already_exists, :database_busy] and attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_finding_replay_read(result, _retry_fun, _attempts_left), do: result

  defp find_existing_finding({:ok, findings}, finding_id, attrs) do
    case Enum.find(findings, &(&1.id == finding_id)) do
      %{} = finding ->
        if finding_idempotency_match?(finding, attrs) do
          idempotent_finding_result(finding, attrs)
        else
          {:tool_error, "idempotency_conflict"}
        end

      nil ->
        {:error, :id_already_exists}
    end
  end

  defp find_existing_finding({:error, reason}, _finding_id, _attrs), do: {:error, reason}

  defp find_existing_finding_by_idempotency({:ok, findings}, attrs) do
    case Enum.find(findings, &finding_idempotency_match?(&1, attrs)) do
      %{} = finding -> idempotent_finding_result(finding, attrs)
      nil -> {:error, :id_already_exists}
    end
  end

  defp find_existing_finding_by_idempotency({:error, reason}, _attrs), do: {:error, reason}

  defp finding_idempotency_match?(finding, attrs), do: finding.idempotency_key == Map.get(attrs, "idempotency_key")

  defp idempotent_finding_result(finding, attrs) do
    fields = if Map.get(attrs, "caller_supplied_id"), do: ["id", "title", "body", "severity"], else: ["title", "body", "severity"]
    expected = Map.take(attrs, fields)
    actual = Map.take(%{"id" => finding.id, "title" => finding.title, "body" => finding.body, "severity" => finding.severity}, fields)

    if expected == actual, do: {:ok, finding}, else: {:tool_error, "idempotency_conflict"}
  end

  defp optional_finding_id(arguments, writer, idempotency_key) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:tool_error, "invalid_id"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, generated_finding_id(writer, idempotency_key)}

      _id ->
        {:tool_error, "invalid_id"}
    end
  end

  defp generated_finding_id(writer, idempotency_key) do
    material = [writer.work_package_id, writer.actor.idempotency_scope, idempotency_key] |> Enum.join(":")
    "finding_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp finding_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
  end

  defp append_progress_for_package(repo, %Writer{} = writer, arguments, tool, payload) do
    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments) do
      idempotency_key = ProgressEvents.scoped_idempotency_key(tool, String.trim(idempotency_key), writer)

      attrs = %{
        "summary" => summary,
        "body" => optional_argument(arguments, "body", nil),
        "status" => optional_argument(arguments, "status", "recorded"),
        "idempotency_key" => idempotency_key,
        "payload" => ProgressEvents.merge_payload(tool, caller_payload, payload)
      }

      ProgressEvents.append_or_replay(repo, writer, attrs, idempotency_key, tool)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
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

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, :work_package_terminal}, resource), do: terminal_auth_error(resource)
  defp worker_error({:unauthorized, {:work_request_terminal, terminal_state}}, resource), do: work_request_terminal_auth_error(resource, terminal_state)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error({:work_request_terminal, terminal_state}, resource), do: work_request_terminal_auth_error(resource, terminal_state)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, reason), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp terminal_auth_error(resource), do: {:error, -32_001, "Unauthorized", put_architect_next_step(%{"resource" => resource, "reason" => "work_package_terminal"})}

  defp work_request_terminal_auth_error(resource, terminal_state) do
    {:error, -32_001, "Unauthorized",
     %{
       "resource" => resource,
       "reason" => "work_request_terminal",
       "terminal_state" => reason_text(terminal_state)
     }}
  end

  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp put_architect_next_step(payload) do
    payload
    |> Map.put("next_owner", "architect")
    |> Map.put("next_action", "return_to_architect")
  end
end
