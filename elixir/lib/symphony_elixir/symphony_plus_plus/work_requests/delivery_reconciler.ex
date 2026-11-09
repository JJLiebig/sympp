defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler do
  @moduledoc """
  Records a `pr_merged` ending for a package from the merge evidence in its
  progress events: the attached PR, its latest synced snapshot and any merge
  reconciliation event. The evidence must name the package's repository and
  base branch and carry the merge time and merge commit. The Observer and
  `sync_pr` reach it through `GitHub.MergeReconciler`.
  """

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @default_recorded_by "work_request_delivery_reconciler"
  @terminal_without_pr_reason "no_structured_pr_merge_evidence"

  @doc """
  Records the package's `pr_merged` ending when its evidence is complete.

  Returns `{:ok, %{status: "applied" | "skipped", reason: ..., applied_count: 0 | 1}}`;
  a failed write is `{:error, {:delivery_reconciliation_failed, reason}}`.
  Options: `:recorded_by`, and `:record_work_package_delivery` (tests).
  """
  @spec reconcile_work_package(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_work_package(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{work_request_id: request_id} = work_package when is_binary(request_id) ->
        with {:ok, work_request} <- WorkRequestService.get(repo, request_id) do
          repo |> reconcile(work_request, work_package, opts) |> result(work_package)
        end

      _missing_or_unlinked ->
        {:ok, %{status: "not_linked", work_package_id: work_package_id, applied_count: 0}}
    end
  end

  defp reconcile(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, opts) do
    cond do
      outcome = existing_outcome(repo, work_package) -> {:skip, "already_closeout", %{delivery_outcome: outcome}}
      Lifecycle.planned?(work_package) -> {:skip, "not_dispatched", %{}}
      true -> apply_closeout(repo, work_request, work_package, opts)
    end
  end

  defp existing_outcome(repo, %WorkPackage{id: id}) do
    case repo.get_by(WorkPackageDelivery, work_package_id: id) do
      %WorkPackageDelivery{outcome: outcome} -> outcome
      nil -> nil
    end
  end

  defp apply_closeout(repo, work_request, work_package, opts) do
    with {:ok, events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, evidence} <- merged_pr_evidence(events),
         :ok <- validate_repository(work_package, evidence),
         :ok <- validate_base_branch(work_package, evidence),
         {:ok, merged_at} <- required_merged_at(evidence),
         {:ok, merge_commit_sha} <- required_merge_commit_sha(evidence) do
      attrs = %{
        outcome: "pr_merged",
        idempotency_key: idempotency_key(work_request, work_package, evidence, merge_commit_sha),
        recorded_by: Keyword.get(opts, :recorded_by, @default_recorded_by),
        pr_url: evidence.url,
        pr_number: evidence.number,
        pr_repository: evidence.repository,
        pr_merged_at: merged_at,
        merge_commit_sha: merge_commit_sha
      }

      case record_work_package_delivery(repo, work_request, work_package, attrs, opts) do
        {:ok, delivery} -> {:applied, delivery}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp result({:applied, delivery}, %WorkPackage{} = work_package),
    do: {:ok, %{status: "applied", reason: "github_pr_merged", work_package_id: work_package.id, delivery_id: delivery.id, applied_count: 1}}

  defp result({:skip, reason, extras}, %WorkPackage{} = work_package),
    do: {:ok, Map.merge(%{status: "skipped", reason: reason, work_package_id: work_package.id, applied_count: 0}, extras)}

  defp result({:error, reason}, _work_package), do: {:error, {:delivery_reconciliation_failed, reason_text(reason)}}

  defp merged_pr_evidence(events) do
    events = PullRequestProgress.chronological_events(events)

    case PullRequestProgress.current_pr_state(events, ["attach_pr"]) do
      {:ok, pr_state} ->
        pr_sync = latest_payload(events, &(pr_snapshot_payload?(&1) and PullRequestProgress.same_pr?(&1, pr_state.ref)))
        merge_reconciliation = latest_payload(events, &(merge_reconciliation_payload?(&1) and PullRequestProgress.same_pr?(&1, pr_state.ref)))

        if PullRequestProgress.merged?(pr_state.payload) or PullRequestProgress.merged?(pr_sync) or merge_reconciliation_payload?(merge_reconciliation) do
          {:ok, evidence_from(pr_state.payload, pr_sync, merge_reconciliation, pr_state.ref)}
        else
          {:skip, @terminal_without_pr_reason, %{}}
        end

      {:error, :missing_attached_pr} ->
        {:skip, @terminal_without_pr_reason, %{}}

      {:error, reason} ->
        {:skip, Atom.to_string(reason), %{}}
    end
  end

  defp latest_payload(events, match?) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn %ProgressEvent{} = event ->
      payload = PullRequestProgress.stringify_keys(event.payload || %{})
      if match?.(payload), do: payload
    end)
  end

  defp pr_snapshot_payload?(%{"type" => "pr", "source_tool" => "sync_pr"}), do: true
  defp pr_snapshot_payload?(_payload), do: false

  defp merge_reconciliation_payload?(%{"type" => "github_pr_merge_reconciliation", "source_tool" => "operator_sync_prs"} = payload),
    do: PullRequestProgress.merged?(payload)

  defp merge_reconciliation_payload?(_payload), do: false

  defp evidence_from(pr_payload, pr_sync, merge_payload, ref) do
    %{
      url: ref.url,
      repository: ref.repository,
      number: ref.number,
      base_branch: clean_string(first_present([map_value(pr_sync, "base_branch"), map_value(pr_payload, "base_branch")])),
      head_sha: clean_string(first_present(Enum.map([merge_payload, pr_sync, pr_payload], &map_value(&1, "head_sha")))),
      merged_at: first_present([map_value(pr_sync, "merged_at"), map_value(merge_payload, "merged_at"), map_value(pr_payload, "merged_at")]),
      merge_commit_sha: first_present([map_value(pr_sync, "merge_commit_sha"), map_value(merge_payload, "merge_commit_sha"), map_value(pr_payload, "merge_commit_sha")])
    }
  end

  defp validate_repository(%WorkPackage{} = work_package, evidence) do
    cond do
      is_nil(clean_string(work_package.repo)) or is_nil(clean_string(evidence.repository)) -> {:skip, "missing_repository", %{}}
      not RepoIdentity.scope_match?(work_package.repo, evidence.repository, local_path_remotes?: true) -> {:skip, "repository_mismatch", %{}}
      true -> :ok
    end
  end

  defp validate_base_branch(%WorkPackage{} = work_package, evidence) do
    expected = clean_string(work_package.base_branch)
    actual = clean_string(evidence.base_branch)

    cond do
      is_nil(expected) or is_nil(actual) -> {:skip, "missing_base_branch", %{expected_base_branch: expected, actual_base_branch: actual}}
      expected != actual -> {:skip, "base_branch_mismatch", %{expected_base_branch: expected, actual_base_branch: actual}}
      true -> :ok
    end
  end

  defp required_merged_at(evidence) do
    case parse_datetime(evidence.merged_at) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:skip, "missing_strong_pr_evidence", %{missing: "pr_merged_at"}}
    end
  end

  defp required_merge_commit_sha(evidence) do
    case clean_string(evidence.merge_commit_sha) do
      nil -> {:skip, "missing_strong_pr_evidence", %{missing: "merge_commit_sha"}}
      merge_commit_sha -> {:ok, merge_commit_sha}
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, DateTime.truncate(datetime, :microsecond)}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp record_work_package_delivery(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, attrs, opts) do
    case Keyword.get(opts, :record_work_package_delivery) do
      fun when is_function(fun, 4) -> fun.(repo, work_request.id, work_package.id, attrs)
      _missing -> WorkRequestService.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    end
  end

  defp idempotency_key(%WorkRequest{} = work_request, %WorkPackage{} = work_package, evidence, merge_commit_sha) do
    material = Enum.join([work_request.id, work_package.id, evidence.url, evidence.head_sha, merge_commit_sha], ":")
    "delivery_reconciler:" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp map_value(nil, _key), do: nil
  defp map_value(%{} = map, key), do: Map.get(map, key)

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _value -> true
    end)
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
