defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.NeverStartedRetention do
  @moduledoc """
  Archives WorkRequests that never started once the never-started window has
  passed since creation, or since the operator's last restore: phase `intake`,
  or phase `planned` with no package ever dispatched or ended (no ending row and
  every package still planned, never dispatched). Edits do not restart the window.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Phase, Repository, WorkRequest}

  @never_started_phases ["intake", "planned"]

  @spec archive(Repository.repo(), DateTime.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, Repository.error()}
  def archive(repo, now, days) do
    cutoff = DateTime.add(now, -days * 24 * 60 * 60, :second)

    repo.transaction(fn ->
      requests = repo.all(candidates(cutoff))

      ids =
        case Phase.load(repo, requests) do
          {:ok, summaries} ->
            started = started_ids(repo, Enum.map(requests, & &1.id))
            Enum.filter(Enum.map(requests, & &1.id), &(summaries[&1].phase in @never_started_phases and not MapSet.member?(started, &1)))

          {:error, reason} ->
            repo.rollback(reason)
        end

      if ids != [] do
        repo.update_all(from(request in WorkRequest, where: request.id in ^ids and is_nil(request.archived_at)),
          set: [archived_at: now, archive_reason: "never_started", updated_at: now]
        )
      end

      ids
    end)
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)
      normalized = String.downcase(message)

      if String.contains?(normalized, "locked") or String.contains?(normalized, "busy"),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  defp started_ids(_repo, []), do: MapSet.new()

  defp started_ids(repo, ids) do
    dispatched_or_past_planned =
      repo.all(
        from(package in WorkPackage,
          where: package.work_request_id in ^ids,
          where: package.status != "planned" or not is_nil(package.dispatched_at),
          select: package.work_request_id
        )
      )

    ended = repo.all(from(delivery in WorkPackageDelivery, where: delivery.work_request_id in ^ids, select: delivery.work_request_id))
    MapSet.new(dispatched_or_past_planned ++ ended)
  end

  defp candidates(cutoff) do
    from(request in WorkRequest,
      where: is_nil(request.archived_at) and is_nil(request.operator_completed_at),
      where: fragment("COALESCE(?, ?)", request.restored_at, request.inserted_at) <= type(^cutoff, :utc_datetime_usec),
      order_by: [asc: request.inserted_at, asc: request.id]
    )
  end
end
