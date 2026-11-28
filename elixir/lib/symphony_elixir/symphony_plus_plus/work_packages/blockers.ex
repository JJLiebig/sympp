defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Blockers do
  @moduledoc """
  Package blockers keyed by their target. The latest event per blocker is
  its state. Ending a package clears its blockers.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, Id}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{Actor, Redactor}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerObservations, BlockerTarget, Phase, PlanEdit}

  @source_tool "set_blocker"

  @type repo :: module()

  @doc "Declares a typed blocker or clears one. The operator clear route names the stored id."
  @spec set(repo(), Actor.t() | nil, String.t(), map() | String.t(), boolean(), String.t() | nil) ::
          {:ok, map(), :changed | :unchanged} | {:error, term()}
  def set(repo, actor, work_package_id, input, active, summary) when is_boolean(active) do
    with {:ok, summary} <- summary(active, summary),
         {:ok, blocker} <- declaration(actor, input, active, summary) do
      snapshots = BlockerTarget.initial_snapshot(if(active, do: [blocker.target], else: []))
      transact(repo, fn -> set_in_transaction(repo, actor, work_package_id, blocker, snapshots) end)
    end
  end

  defp declaration(nil, id, false, summary) when is_binary(id) do
    with {:ok, id} <- text(id, :invalid_blocker_id), do: {:ok, %{id: id, target: nil, active: false, summary: summary}}
  end

  defp declaration(_actor, input, active, summary) do
    with {:ok, target} <- BlockerTarget.normalize(input), do: {:ok, %{id: BlockerTarget.id(target), target: target, active: active, summary: summary}}
  end

  defp transact(repo, change) do
    case repo.transaction(fn -> transaction_result(repo, change.()) end, mode: :immediate) do
      {:ok, {blocker, :changed}} ->
        DashboardPubSub.broadcast_changed()
        {:ok, blocker, :changed}

      {:ok, {blocker, how}} ->
        {:ok, blocker, how}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transaction_result(_repo, {:ok, blocker, how}), do: {blocker, how}
  defp transaction_result(repo, {:error, reason}), do: repo.rollback(reason)

  defp set_in_transaction(repo, actor, work_package_id, blocker, snapshots) do
    with {:ok, %WorkPackage{} = work_package} <- lock(repo, work_package_id),
         :ok <- require_open(work_package),
         :ok <- Phase.require_writable_package(repo, work_package.id) do
      apply_declaration(repo, actor, work_package, blocker, snapshots)
    end
  end

  defp apply_declaration(repo, actor, package, %{target: %{"kind" => "work_package"}} = blocker, _snapshots),
    do: PlanEdit.set_blocker(repo, package, blocker, actor && actor.id)

  defp apply_declaration(repo, actor, package, %{id: id, active: true} = blocker, snapshots) do
    state = BlockerTarget.state(repo, blocker.target, snapshots)
    target = Map.put(blocker.target, "state", state)

    with :ok <- require_external_pr(repo, package.id, blocker.target),
         :ok <- BlockerObservations.require_acyclic(repo, {"work_package", package.id}, [target]),
         {:ok, current} <- current(repo, package.id, id) do
      if current && current.target == blocker.target && current.summary == blocker.summary && observed_state(current) == state,
        do: {:ok, current, :unchanged},
        else: append(repo, actor, package.id, blocker, state)
    end
  end

  defp apply_declaration(repo, actor, package, %{id: id, summary: summary}, _snapshots) do
    case current(repo, package.id, id) do
      {:ok, nil} -> {:error, :blocker_not_found}
      {:ok, %{active: false} = blocker} -> {:ok, blocker, :unchanged}
      {:ok, blocker} -> append(repo, actor, package.id, %{blocker | summary: summary || "Cleared blocker: #{blocker.summary || id}"}, "cleared")
      {:error, _reason} = error -> error
    end
  end

  defp require_external_pr(repo, package_id, %{"kind" => "pr", "id" => id}) do
    with {:ok, attachments} <- PlanningRepository.pr_attachments(repo, [package_id]) do
      if BlockerTarget.attached_pr_id(attachments[package_id]) == id, do: {:error, :blocker_cycle}, else: :ok
    end
  end

  defp require_external_pr(_repo, _package_id, _target), do: :ok

  @spec observed_state(map()) :: BlockerTarget.state()
  def observed_state(blocker), do: if(blocker.unknown, do: "unknown", else: blocker.state)

  @spec observe(repo(), String.t(), map(), BlockerTarget.state()) :: term()
  def observe(repo, package_id, blocker, state) do
    event_id = blocker.event_id

    transact(repo, fn ->
      with %WorkPackage{status: status} when status != "ended" <- repo.get(WorkPackage, package_id),
           :ok <- Phase.require_writable_package(repo, package_id),
           {:ok, %{event_id: ^event_id}} <- current(repo, package_id, blocker.id) do
        append(repo, Actor.observer(), package_id, blocker, state)
      else
        {:error, _reason} = error -> error
        _changed_or_missing -> {:ok, blocker, :unchanged}
      end
    end)
  end

  @doc "Appends one blocker state in the caller's transaction."
  @spec append(repo(), Actor.t() | nil, String.t(), map(), BlockerTarget.state()) :: {:ok, map(), :changed} | {:error, term()}
  def append(repo, actor, work_package_id, %{id: id, target: target, summary: summary}, state) do
    active = state != "cleared"

    attrs = %{
      "summary" => summary,
      "status" => if(active, do: "blocked", else: "resolved"),
      "idempotency_key" => Enum.join([@source_tool, id, Id.random("evt")], ":"),
      "payload" => %{"type" => "blocker", "source_tool" => @source_tool, "blocker_id" => id, "active" => active, "target" => target, "state" => state}
    }

    result =
      case actor do
        %Actor{} -> PlanningRepository.append_audit_progress_event_for_work_package(repo, actor, work_package_id, attrs)
        nil -> PlanningRepository.append_progress_event(repo, Map.put(attrs, "work_package_id", work_package_id))
      end

    with {:ok, event} <- result do
      {:ok, BlockerProjection.blockers([event]) |> hd(), :changed}
    end
  end

  defp current(repo, work_package_id, blocker_id) do
    with {:ok, events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, events |> BlockerProjection.blockers() |> Enum.find(&(&1.id == blocker_id))}
    end
  end

  # Serializes blocker changes on one package.
  defp lock(repo, work_package_id) when is_binary(work_package_id) do
    case repo.update_all(from(package in WorkPackage, where: package.id == ^work_package_id), set: [id: work_package_id]) do
      {1, _rows} -> {:ok, repo.get!(WorkPackage, work_package_id)}
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp lock(_repo, _work_package_id), do: {:error, :not_found}

  defp require_open(%WorkPackage{status: "ended"}), do: {:error, :work_package_ended}
  defp require_open(%WorkPackage{}), do: :ok

  defp summary(true, summary), do: text(summary, :missing_summary)
  defp summary(false, nil), do: {:ok, nil}
  defp summary(false, summary), do: text(summary, :invalid_summary)

  defp text(value, reason) when is_binary(value) do
    case value |> String.trim() |> Redactor.redact_text() do
      "" -> {:error, reason}
      text -> {:ok, text}
    end
  end

  defp text(_value, reason), do: {:error, reason}
end
