defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion do
  @moduledoc """
  The WorkRequest's stored operator overrides and retention.

  Operator events: `complete` sets `operator_completed_at`; `archive` and
  `restore` set and clear `archived_at`. Restore also records `restored_at`,
  which restarts both retention clocks. Everything else about a WorkRequest's
  progress is derived by `Phase`.

  Retention archives `done` WorkRequests after the archive window (reason
  `age`), keeps at most ten done WorkRequests visible per repo and base branch
  (reason `limit`), archives WorkRequests still `intake` or `planned` after the
  never-started window (reason `never_started`, via `NeverStartedRetention`), and
  deletes archives older than the deletion window, except never-started ones.
  """

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings
  alias SymphonyElixir.SymphonyPlusPlus.SessionLocations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.NeverStartedRetention
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @archivable_phases ["done", "unresolved"]
  @default_archive_after_days 3
  @completed_visible_limit 10
  @delete_work_request_chunk_size 500

  @type retention_summary :: %{
          archived_count: non_neg_integer(),
          archived_ids: [String.t()],
          deleted_count: non_neg_integer(),
          deleted_ids: [String.t()]
        }
  @type delete_error :: Repository.error() | {:worktree_cleanup_failed, term()}
  @type retention_error ::
          delete_error()
          | :invalid_archive_after_days
          | :invalid_never_started_archive_after_days
          | :invalid_delete_after_days

  @spec default_archive_after_days() :: pos_integer()
  def default_archive_after_days, do: @default_archive_after_days

  @doc """
  Operator completion. Closes open clarification questions, resolves package
  blockers and queues cleanup of ended packages' worktrees. It does not stop
  workers or merge PRs. Refused on an archived WorkRequest.
  """
  @spec complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error() | :work_request_archived}
  def complete(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
           :ok <- Phase.require_writable(work_request),
           {:ok, work_packages} <- Repository.list_work_packages(repo, work_request_id),
           :ok <- clear_completed_attention(repo, work_request.id, work_packages),
           {:ok, updated} <- mark_operator_completed(repo, work_request) do
        updated
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc "Operator archive of a `done` or `unresolved` WorkRequest. Archiving again is a no-op."
  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error() | :not_completed}
  def archive(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
           {:ok, summary} <- Phase.load_one(repo, work_request),
           {:ok, archived} <- archive_in_phase(repo, work_request, summary.phase) do
        archived
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc """
  Operator restore. Clears the archive, restarts the retention clocks and
  resolves blockers whose target ended while the WorkRequest was archived.
  """
  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def restore(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    case Repository.get(repo, work_request_id) do
      {:ok, %WorkRequest{archived_at: nil} = work_request} ->
        {:ok, work_request}

      {:ok, %WorkRequest{} = work_request} ->
        repo.transaction(fn -> restore_archived(repo, work_request) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_archived(repo, %WorkRequest{} = work_request) do
    with {:ok, restored} <-
           work_request
           |> Ecto.Changeset.change(archived_at: nil, archive_reason: nil, restored_at: DateTime.utc_now(:microsecond))
           |> update_work_request(repo),
         :ok <- Lifecycle.resolve_blockers_on_ended_targets(repo, linked_work_packages(repo, restored.id)) do
      restored
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  @spec delete(Repository.repo(), String.t()) :: {:ok, String.t()} | {:error, delete_error()}
  def delete(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{}} <- Repository.get(repo, work_request_id) do
      delete_work_request_with_dependents(repo, work_request_id)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec retention_pass(Repository.repo()) :: {:ok, retention_summary()} | {:error, retention_error()}
  @spec retention_pass(Repository.repo(), keyword()) :: {:ok, retention_summary()} | {:error, retention_error()}
  def retention_pass(repo, opts \\ []) when is_atom(repo) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:microsecond) end)

    with {:ok, archive_after_days} <- archive_after_days(opts),
         {:ok, never_started_days} <- never_started_archive_after_days(opts),
         {:ok, delete_after_days} <- delete_after_days(opts),
         {:ok, archived_never_started} <- NeverStartedRetention.archive(repo, now, never_started_days),
         cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second),
         {:ok, candidates} <- retention_candidates(repo),
         {:ok, archived_for_age} <- archive_expired(repo, candidates, cutoff),
         {:ok, remaining} <- retention_candidates(repo),
         {:ok, archived_for_limit} <- archive_overflow(repo, remaining),
         {:ok, deleted_ids} <- delete_expired_archived(repo, now, delete_after_days) do
      archived_ids = archived_for_age ++ archived_for_limit ++ archived_never_started

      {:ok,
       %{
         archived_count: length(archived_ids),
         archived_ids: archived_ids,
         deleted_count: length(deleted_ids),
         deleted_ids: deleted_ids
       }}
    end
  end

  defp archive_in_phase(_repo, %WorkRequest{archived_at: %DateTime{}} = work_request, _phase), do: {:ok, work_request}

  defp archive_in_phase(repo, %WorkRequest{} = work_request, phase) when phase in @archivable_phases,
    do: archive_work_request(repo, work_request, "manual", &archivable_phase?/2)

  defp archive_in_phase(_repo, %WorkRequest{}, _phase), do: {:error, :not_completed}

  defp mark_operator_completed(_repo, %WorkRequest{operator_completed_at: %DateTime{}} = work_request), do: {:ok, work_request}

  defp mark_operator_completed(repo, %WorkRequest{} = work_request) do
    work_request
    |> Ecto.Changeset.change(operator_completed_at: DateTime.utc_now(:microsecond))
    |> update_work_request(repo)
  end

  defp clear_completed_attention(repo, work_request_id, work_packages) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      from(question in ClarificationQuestion,
        where: question.work_request_id == ^work_request_id and question.status == "open"
      ),
      set: [status: "closed", updated_at: now]
    )

    Lifecycle.apply_terminal_effects(repo, work_packages)
  end

  # Every unarchived done WorkRequest, with the time its retention clock started.
  defp retention_candidates(repo) do
    work_requests =
      repo.all(
        from(work_request in WorkRequest,
          where: is_nil(work_request.archived_at),
          order_by: [asc: work_request.inserted_at, asc: work_request.id]
        )
      )

    with {:ok, summaries} <- Phase.load(repo, work_requests) do
      {:ok,
       for %WorkRequest{} = work_request <- work_requests,
           %{completed_at: %DateTime{} = completed_at} <- [Map.fetch!(summaries, work_request.id)] do
         {work_request, retention_clock(completed_at, work_request.restored_at)}
       end}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp retention_clock(completed_at, nil), do: completed_at
  defp retention_clock(completed_at, restored_at), do: Enum.max([completed_at, restored_at], DateTime)

  defp archive_expired(repo, candidates, cutoff) do
    candidates
    |> Enum.filter(fn {_work_request, clock} -> DateTime.compare(clock, cutoff) != :gt end)
    |> Enum.map(&elem(&1, 0))
    |> archive_all(repo, "age", &done_since?(&1, &2, fn clock -> DateTime.compare(clock, cutoff) != :gt end))
  end

  defp archivable_phase?(_work_request, %{phase: phase}), do: phase in @archivable_phases

  defp archive_overflow(repo, candidates) do
    candidates
    |> Enum.group_by(fn {work_request, _clock} -> {work_request.repo, work_request.base_branch} end)
    |> Enum.flat_map(fn {_scope, scoped} ->
      scoped
      |> Enum.sort_by(fn {work_request, clock} -> {DateTime.to_unix(clock, :microsecond), DateTime.to_unix(work_request.inserted_at, :microsecond), work_request.id} end)
      |> Enum.drop(-@completed_visible_limit)
    end)
    |> archive_overflow_candidates(repo)
  end

  # An overflow candidate is archived only if its clock is unchanged, so a
  # concurrent restore keeps it visible.
  defp archive_overflow_candidates(candidates, repo) do
    Enum.reduce_while(candidates, {:ok, []}, fn {work_request, clock}, {:ok, archived_ids} ->
      eligible? = fn current, summary -> done_since?(current, summary, &(DateTime.compare(&1, clock) == :eq)) end

      case archive_work_request(repo, work_request, "limit", eligible?) do
        {:ok, %WorkRequest{id: id}} -> {:cont, {:ok, [id | archived_ids]}}
        {:error, :not_completed} -> {:cont, {:ok, archived_ids}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived_ids} -> {:ok, Enum.reverse(archived_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp done_since?(%WorkRequest{} = current, %{phase: "done", completed_at: %DateTime{} = completed_at}, clock_check),
    do: clock_check.(retention_clock(completed_at, current.restored_at))

  defp done_since?(%WorkRequest{}, _summary, _clock_check), do: false

  defp archive_all(work_requests, repo, archive_reason, eligible?) do
    work_requests
    |> Enum.reduce_while({:ok, []}, fn work_request, {:ok, archived_ids} ->
      case archive_work_request(repo, work_request, archive_reason, eligible?) do
        {:ok, %WorkRequest{id: id}} -> {:cont, {:ok, [id | archived_ids]}}
        {:error, :not_completed} -> {:cont, {:ok, archived_ids}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived_ids} -> {:ok, Enum.reverse(archived_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Eligibility is checked again inside the archive transaction against the
  # current WorkRequest, so a candidate that gained new work or was restored
  # since it was selected is not archived.
  defp archive_work_request(repo, %WorkRequest{id: id}, archive_reason, eligible?) when is_binary(id) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      with {:ok, %WorkRequest{archived_at: nil} = current} <- Repository.get(repo, id),
           {:ok, summary} <- Phase.load_one(repo, current),
           true <- eligible?.(current, summary),
           {1, _rows} <-
             repo.update_all(
               from(work_request in WorkRequest, where: work_request.id == ^id and is_nil(work_request.archived_at)),
               set: [archived_at: now, archive_reason: archive_reason, updated_at: now]
             ),
           :ok <- WorktreeCleanupQueue.enqueue_terminal(repo, linked_work_packages(repo, id)),
           {:ok, archived} <- Repository.get(repo, id) do
        archived
      else
        {:error, reason} -> repo.rollback(reason)
        _not_archivable -> repo.rollback(:not_completed)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp archive_after_days(opts) do
    case Keyword.get(opts, :archive_after_days, @default_archive_after_days) do
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_archive_after_days}
    end
  end

  defp delete_after_days(opts) do
    case Keyword.get(opts, :delete_after_days) do
      nil -> {:ok, nil}
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_delete_after_days}
    end
  end

  defp never_started_archive_after_days(opts) do
    case Keyword.get(opts, :never_started_archive_after_days, Settings.default().work_request_never_started_archive_after_days) do
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_never_started_archive_after_days}
    end
  end

  defp delete_expired_archived(_repo, _now, nil), do: {:ok, []}

  defp delete_expired_archived(repo, now, delete_after_days) do
    cutoff = DateTime.add(now, -delete_after_days * 24 * 60 * 60, :second)

    repo.all(
      from(work_request in WorkRequest,
        where: work_request.archived_at < ^cutoff,
        where: is_nil(work_request.archive_reason) or work_request.archive_reason != "never_started",
        order_by: [asc: work_request.archived_at, asc: work_request.id],
        select: work_request.id
      )
    )
    |> Enum.reduce_while({:ok, []}, fn work_request_id, {:ok, deleted_ids} ->
      case delete_archived_work_request(repo, work_request_id, cutoff) do
        {:ok, nil} -> {:cont, {:ok, deleted_ids}}
        {:ok, deleted_id} -> {:cont, {:ok, [deleted_id | deleted_ids]}}
        {:error, reason} -> maybe_skip_archived_cleanup_error(reason, deleted_ids)
      end
    end)
    |> case do
      {:ok, deleted_ids} -> {:ok, Enum.reverse(deleted_ids)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  # Deletes the archive only if it is still archived before the cutoff when the
  # transaction runs, so a concurrent restore wins.
  defp delete_archived_work_request(repo, work_request_id, cutoff) do
    repo.transaction(fn ->
      if still_archived_before?(repo, work_request_id, cutoff) do
        delete_still_archived_work_request(repo, work_request_id, cutoff)
      end
    end)
  end

  defp delete_still_archived_work_request(repo, work_request_id, cutoff) do
    work_packages = linked_work_packages(repo, work_request_id)

    with :ok <- enqueue_worktrees_for_deletion(repo, work_packages),
         :ok <- delete_work_request_dependents(repo, [work_request_id], Enum.map(work_packages, & &1.id)) do
      {count, _rows} =
        repo.delete_all(from(work_request in WorkRequest, where: work_request.id == ^work_request_id and work_request.archived_at < ^cutoff))

      if count == 1, do: work_request_id
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp still_archived_before?(repo, work_request_id, cutoff) do
    repo.exists?(from(work_request in WorkRequest, where: work_request.id == ^work_request_id and work_request.archived_at < ^cutoff))
  end

  defp delete_work_request_with_dependents(repo, work_request_id) do
    repo.transaction(fn ->
      work_packages = linked_work_packages(repo, work_request_id)

      with :ok <- enqueue_worktrees_for_deletion(repo, work_packages),
           :ok <- delete_work_request_dependents(repo, [work_request_id], Enum.map(work_packages, & &1.id)) do
        delete_work_request_row(repo, work_request_id)
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp delete_work_request_row(repo, work_request_id) do
    {count, _rows} =
      repo.delete_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^work_request_id
        )
      )

    case count do
      1 -> work_request_id
      0 -> repo.rollback(:not_found)
    end
  end

  defp linked_work_packages(repo, work_request_id) do
    repo.all(from(work_package in WorkPackage, where: work_package.work_request_id == ^work_request_id))
  end

  defp delete_work_request_dependents(repo, work_request_ids, work_package_ids) do
    with :ok <- preserve_archived_work_package_hides(repo, work_package_ids),
         :ok <- SessionLocations.delete_for_targets(repo, "work_request", work_request_ids),
         :ok <- SessionLocations.delete_for_targets(repo, "work_package", work_package_ids) do
      delete_archived_grant_scopes(repo, work_request_ids, work_package_ids)
    end
  end

  defp preserve_archived_work_package_hides(_repo, []), do: :ok

  defp preserve_archived_work_package_hides(repo, work_package_ids) do
    case OperatorSettingsRepository.get(repo) do
      {:ok, settings} ->
        hidden_work_package_ids = Enum.uniq(settings.hidden_work_package_ids ++ Enum.uniq(work_package_ids))

        case OperatorSettingsRepository.update(repo, %{"hidden_work_package_ids" => hidden_work_package_ids}) do
          {:ok, _settings} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_archived_grant_scopes(repo, work_request_ids, work_package_ids) do
    with {:ok, _work_request_count} <- delete_grant_scope_ids(repo, "work_request", work_request_ids),
         {:ok, _work_package_count} <- delete_grant_scope_ids(repo, "work_package", work_package_ids) do
      :ok
    end
  end

  defp delete_grant_scope_ids(_repo, _scope_type, []), do: {:ok, 0}

  defp delete_grant_scope_ids(repo, scope_type, scope_ids) do
    scope_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@delete_work_request_chunk_size)
    |> Enum.reduce({:ok, 0}, fn
      _ids, {:error, reason} ->
        {:error, reason}

      ids, {:ok, deleted_count} ->
        {count, _rows} =
          repo.delete_all(
            from(scope in "sympp_access_grant_scopes",
              where: scope.scope_type == ^scope_type,
              where: scope.scope_id in ^ids
            )
          )

        {:ok, deleted_count + count}
    end)
  end

  defp enqueue_worktrees_for_deletion(repo, work_packages) do
    case WorktreeCleanupQueue.enqueue_for_deletion(repo, work_packages) do
      :ok -> :ok
      {:error, reason} -> {:error, {:worktree_cleanup_failed, reason}}
    end
  end

  defp maybe_skip_archived_cleanup_error(reason, deleted_ids) do
    if hard_archived_cleanup_error?(reason) do
      {:halt, {:error, reason}}
    else
      {:cont, {:ok, deleted_ids}}
    end
  end

  defp hard_archived_cleanup_error?(:database_busy), do: true
  defp hard_archived_cleanup_error?({:constraint_failed, _constraint}), do: true
  defp hard_archived_cleanup_error?({:storage_failed, _message}), do: true
  defp hard_archived_cleanup_error?(%Ecto.Changeset{}), do: true
  defp hard_archived_cleanup_error?(_reason), do: false

  defp update_work_request(changeset, repo) do
    repo.update(changeset)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "busy") or String.contains?(String.downcase(message), "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
