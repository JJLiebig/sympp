defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.NeverStartedRetention do
  @moduledoc """
  Archives WorkRequests still in phase `intake` or `planned` once the
  never-started window has passed since creation, or since the operator's last
  restore. Edits do not restart the window.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Phase, Repository, WorkRequest}

  @never_started_phases ["intake", "planned"]

  @spec archive(Repository.repo(), DateTime.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, Repository.error()}
  def archive(repo, now, days) do
    cutoff = DateTime.add(now, -days * 24 * 60 * 60, :second)

    repo.transaction(fn ->
      requests = repo.all(candidates(cutoff))

      ids =
        case Phase.load(repo, requests) do
          {:ok, summaries} -> Enum.filter(Enum.map(requests, & &1.id), &(summaries[&1].phase in @never_started_phases))
          {:error, reason} -> repo.rollback(reason)
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

  defp candidates(cutoff) do
    from(request in WorkRequest,
      where: is_nil(request.archived_at) and is_nil(request.operator_completed_at),
      where: fragment("COALESCE(?, ?)", request.restored_at, request.inserted_at) <= type(^cutoff, :utc_datetime_usec),
      order_by: [asc: request.inserted_at, asc: request.id]
    )
  end
end
