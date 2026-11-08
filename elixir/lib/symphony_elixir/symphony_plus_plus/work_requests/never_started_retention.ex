defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.NeverStartedRetention do
  @moduledoc false

  import Ecto.Query, only: [from: 2, exclude: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Repository, WorkRequest}

  # Legacy dispatches may predate dispatched_at; these states already imply execution.

  @spec archive(Repository.repo(), DateTime.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, Repository.error()}
  def archive(repo, now, days) do
    cutoff = DateTime.add(now, -days * 24 * 60 * 60, :second)

    repo.transaction(fn ->
      query = candidates(cutoff)
      requests = repo.all(query)
      ids = never_started_ids(repo, requests)

      if ids != [] do
        repo.update_all(from(request in exclude(query, :order_by), where: request.id in ^ids),
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

  defp candidates(cutoff) do
    from(request in WorkRequest,
      where: is_nil(request.archived_at) and is_nil(request.completed_at),
      where: fragment("COALESCE(?, ?)", request.never_started_restored_at, request.inserted_at) <= type(^cutoff, :utc_datetime_usec),
      where: fragment("NOT EXISTS (SELECT 1 FROM sympp_work_package_deliveries WHERE work_request_id = ?)", request.id),
      order_by: [asc: request.inserted_at, asc: request.id]
    )
  end

  defp never_started_ids(_repo, []), do: []

  defp never_started_ids(repo, requests) do
    ids = Enum.map(requests, & &1.id)

    started_ids =
      repo.all(
        from(package in WorkPackage,
          where: package.work_request_id in ^ids,
          where:
            not is_nil(package.dispatched_at) or package.status in ^Lifecycle.in_flight_statuses() or
              fragment("EXISTS (SELECT 1 FROM sympp_agent_runs WHERE work_package_id = ?)", package.id),
          select: package.work_request_id
        )
      )
      |> Enum.concat(repo.all(from(worked_on in WorkedOn, where: worked_on.subject_kind == "work_request" and worked_on.subject_id in ^ids, select: worked_on.subject_id)))
      |> MapSet.new()

    Enum.reject(ids, &MapSet.member?(started_ids, &1))
  end
end
