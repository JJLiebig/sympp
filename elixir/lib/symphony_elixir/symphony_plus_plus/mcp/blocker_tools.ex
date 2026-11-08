defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_argument: 3,
      optional_string_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [optional_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    ProgressEvents,
    Session,
    ToolResult
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: mcp_tool_result()
  def call("resolve_blocker", %Config{} = config, %Session{assignment: %{grant_role: "architect"}} = session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id", Session.work_package_id(session)),
         {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         {:ok, actor} <- actor_for_package_resource(config.repo, session, :blocker, work_package_id),
         :ok <- PlanningService.authorize_package_action(config.repo, actor, :blocker_resolve, work_package_id, :blocker),
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
         {:ok, result} <- resolve_architect_blocker(config.repo, session, work_package_id, blocker_id, attrs, idempotency_key) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "resolve_blocker")
    end
  end

  defp actor_for_package_resource(repo, %Session{} = session, resource_type, work_package_id) do
    with {:ok, target} <- PlanningService.package_resource_target(repo, work_package_id, resource_type) do
      ActorResolver.from_session(session, PlanningService.package_surface_actor_opts(session.assignment, target))
    end
  end

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp resolve_architect_blocker(repo, %Session{} = session, work_package_id, blocker_id, attrs, idempotency_key) do
    run_architect_transaction(repo, fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, work_package_id) do
        replay_or_resolve_architect_blocker(repo, session, work_package_id, blocker_id, attrs, idempotency_key)
      end
    end)
  end

  defp replay_or_resolve_architect_blocker(repo, %Session{} = session, work_package_id, blocker_id, attrs, idempotency_key) do
    case ProgressEvents.existing_for_work_package(repo, work_package_id, idempotency_key) do
      {:ok, event} ->
        {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}

      {:error, :not_found} ->
        resolve_new_architect_blocker(repo, session, work_package_id, blocker_id, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_new_architect_blocker(repo, %Session{} = session, work_package_id, blocker_id, attrs) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      case Enum.find(BlockerProjection.blockers(progress_events), &(&1.id == blocker_id)) do
        %{active: true} -> append_architect_blocker_resolution(repo, session, work_package_id, attrs)
        %{} -> {:ok, ToolResult.tool_result(%{"already_resolved" => true, "blocker_id" => blocker_id})}
        nil -> {:tool_error, "blocker_not_found"}
      end
    end
  end

  defp append_architect_blocker_resolution(repo, %Session{} = session, work_package_id, attrs) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <- reject_ready_blocker_provenance(work_package, attrs),
         {:ok, event} <-
           PlanningRepository.append_audit_progress_event_for_work_package(
             repo,
             session.assignment,
             work_package_id,
             attrs
           ),
         {:ok, _work_package} <- WorkPackageRepository.reactivate_if_unblocked(repo, work_package_id) do
      {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}
    end
  end

  defp reject_ready_blocker_provenance(%WorkPackage{status: "ready_for_merge"}, %{"payload" => payload})
       when is_map_key(payload, "dependency_inputs"),
       do: {:tool_error, "already_ready"}

  defp reject_ready_blocker_provenance(_work_package, _attrs), do: :ok

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
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp architect_error(:architect_grant_required, resource), do: auth_error({:unauthorized, :architect_grant_required}, resource)
  defp architect_error(:insufficient_capability, resource), do: auth_error({:unauthorized, :insufficient_capability}, resource)
  defp architect_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp architect_error({:authorization_policy_denied, code, message, data}, _resource), do: {:error, code, message, data}
  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:phase_scope_not_available, _missing_evidence}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:ambiguous_phase_scope, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
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
