defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [optional_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    ErrorDetails,
    ProgressEvents,
    ToolResult
  }

  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec call(String.t(), Config.t(), Terminal.t(), map()) :: mcp_tool_result()
  def call("resolve_blocker", %Config{} = config, %Terminal{} = terminal, arguments) do
    actor = Actor.from_terminal(terminal)

    with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         idempotency_key = ["resolve_blocker", work_package_id, String.trim(idempotency_key)] |> Enum.join(":"),
         attrs = %{
           "summary" => summary,
           "body" => optional_argument(arguments, "body", nil),
           "status" => "resolved",
           "idempotency_key" => idempotency_key,
           "payload" =>
             Map.merge(caller_payload, %{
               "type" => "blocker",
               "source_tool" => "resolve_blocker",
               "blocker_id" => blocker_id,
               "resolution" => resolution,
               "active" => false
             })
         },
         {:ok, result} <- resolve_architect_blocker(config.repo, actor, work_package_id, blocker_id, attrs, idempotency_key) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "resolve_blocker")
    end
  end

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp resolve_architect_blocker(repo, %Actor{} = actor, work_package_id, blocker_id, attrs, idempotency_key) do
    run_architect_transaction(repo, fn ->
      with :ok <- lock_work_package(repo, work_package_id) do
        replay_or_resolve_architect_blocker(repo, actor, work_package_id, blocker_id, attrs, idempotency_key)
      end
    end)
  end

  defp replay_or_resolve_architect_blocker(repo, %Actor{} = actor, work_package_id, blocker_id, attrs, idempotency_key) do
    case ProgressEvents.existing_for_work_package(repo, work_package_id, idempotency_key) do
      {:ok, event} ->
        {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}

      {:error, :not_found} ->
        resolve_new_architect_blocker(repo, actor, work_package_id, blocker_id, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_new_architect_blocker(repo, %Actor{} = actor, work_package_id, blocker_id, attrs) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      case Enum.find(BlockerProjection.blockers(progress_events), &(&1.id == blocker_id)) do
        %{active: true} -> append_architect_blocker_resolution(repo, actor, work_package_id, attrs)
        %{} -> {:ok, ToolResult.tool_result(%{"already_resolved" => true, "blocker_id" => blocker_id})}
        nil -> {:tool_error, "blocker_not_found"}
      end
    end
  end

  defp append_architect_blocker_resolution(repo, %Actor{} = actor, work_package_id, attrs) do
    with {:ok, event} <-
           PlanningRepository.append_audit_progress_event_for_work_package(
             repo,
             actor,
             work_package_id,
             attrs
           ) do
      {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}
    end
  end

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error(:work_request_archived, tool),
    do: ErrorDetails.lifecycle_error(tool, :work_request_archived, %{"phase" => "archived"})

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
