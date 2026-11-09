defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Blockers do
  @moduledoc """
  Package blockers. A blocker is declared or cleared by id (`set_blocker`);
  each change is a progress event on the package, and the latest event per id
  is the blocker's state. Ending a package clears its blockers.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, Id}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{Actor, Redactor}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase

  @source_tool "set_blocker"

  @type repo :: module()

  @doc "The `source_tool` every blocker event carries."
  @spec source_tool() :: String.t()
  def source_tool, do: @source_tool

  @doc """
  Declares (`active: true`, needs a summary) or clears a blocker on a package
  that hasn't ended. Setting a blocker to the state it already has changes
  nothing; clearing an unknown blocker fails `blocker_not_found`.
  """
  @spec set(repo(), Actor.t() | nil, String.t(), String.t(), boolean(), String.t() | nil) ::
          {:ok, map(), :changed | :unchanged} | {:error, term()}
  def set(repo, actor, work_package_id, blocker_id, active, summary) when is_boolean(active) do
    with {:ok, blocker_id} <- text(blocker_id, :invalid_blocker_id),
         {:ok, summary} <- summary(active, summary) do
      change = fn -> set_in_transaction(repo, actor, work_package_id, blocker_id, active, summary) end

      repo.transaction(fn -> transaction_result(repo, change.()) end, mode: :immediate)
      |> case do
        {:ok, {blocker, :changed}} ->
          DashboardPubSub.broadcast_changed()
          {:ok, blocker, :changed}

        {:ok, {blocker, how}} ->
          {:ok, blocker, how}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp transaction_result(_repo, {:ok, blocker, how}), do: {blocker, how}
  defp transaction_result(repo, {:error, reason}), do: repo.rollback(reason)

  defp set_in_transaction(repo, actor, work_package_id, blocker_id, active, summary) do
    with {:ok, %WorkPackage{} = work_package} <- lock(repo, work_package_id),
         :ok <- require_open(work_package),
         :ok <- Phase.require_writable_package(repo, work_package.id),
         {:ok, current} <- current(repo, work_package.id, blocker_id) do
      case {active, current} do
        {false, nil} -> {:error, :blocker_not_found}
        {false, %{active: false}} -> {:ok, current, :unchanged}
        {true, %{active: true, summary: ^summary}} -> {:ok, current, :unchanged}
        {true, _current} -> append(repo, actor, work_package.id, blocker_id, true, summary, nil)
        {false, _active} -> append(repo, actor, work_package.id, blocker_id, false, summary || "Cleared blocker: #{current.summary || blocker_id}", nil)
      end
    end
  end

  @doc """
  Writes one blocker event in the caller's transaction and returns the
  blocker's new state. Used by `set/6`, the operator's clear action and ending
  a package.
  """
  @spec append(repo(), Actor.t() | nil, String.t(), String.t(), boolean(), String.t(), String.t() | nil) ::
          {:ok, map(), :changed} | {:error, term()}
  def append(repo, actor, work_package_id, blocker_id, active, summary, body) do
    attrs = %{
      "summary" => summary,
      "body" => body,
      "status" => if(active, do: "blocked", else: "resolved"),
      "idempotency_key" => Enum.join([@source_tool, blocker_id, Id.random("evt")], ":"),
      "payload" => %{"type" => "blocker", "source_tool" => @source_tool, "blocker_id" => blocker_id, "active" => active}
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
