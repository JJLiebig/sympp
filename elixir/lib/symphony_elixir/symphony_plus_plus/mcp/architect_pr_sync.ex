defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectPRSync do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [optional_list_argument: 2, optional_string_argument: 2]

  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{
    Client,
    DefaultClient,
    DryClient,
    MergeReconciler,
    PullRequest,
    PullRequestProgress
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, DependencyInputs}
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, Qualification, WorkPackage, WorkPackageActivity}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  @spec sync(module(), Actor.t(), WorkPackage.t(), map()) :: {:ok, map()} | {:error, term()} | {:tool_error, term()}
  def sync(repo, %Actor{} = actor, %WorkPackage{} = work_package, arguments)
      when is_map_key(arguments, "url") or is_map_key(arguments, "number") do
    client = Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient)

    with {:ok, expected_head} <- optional_string_argument(arguments, "head_sha"),
         {:ok, dependency_inputs} <- optional_list_argument(arguments, "dependency_inputs"),
         {:ok, ref} <- PullRequest.parse(arguments, work_package.repo),
         {:ok, metadata} <- Client.fetch_pull_request(client, ref, provider_snapshot: true),
         {:ok, payload} <- PullRequest.provider_snapshot(metadata, ref, expected_head),
         :ok <- require_delivery_scope(work_package, payload),
         :ok <- require_exact_head(payload, expected_head),
         :ok <- require_merge_evidence(payload),
         pr_facts = pr_facts(work_package, metadata, payload),
         {:ok, result} <- persist(repo, actor, work_package, payload, pr_facts, dependency_inputs) do
      if PullRequestProgress.merged?(payload) do
        MergeReconciler.reconcile_work_package(repo, work_package.id, pr_payload: payload, client: DryClient, metadata: payload)
      else
        {:ok, result}
      end
    end
  end

  def sync(repo, %Actor{} = actor, %WorkPackage{} = work_package, %{"head_sha" => _head} = arguments) do
    with {:ok, state} <- PlanningRepository.get_state(repo, work_package.id),
         {:ok, current} <- PullRequestProgress.current_pr_state(state.progress_events) do
      sync(repo, actor, work_package, Map.put(arguments, "url", current.ref.url))
    end
  end

  def sync(_repo, %Actor{}, %WorkPackage{}, %{"dependency_inputs" => _inputs}),
    do: {:tool_error, "dependency_inputs needs the PR: pass url, number or head_sha"}

  def sync(repo, %Actor{}, %WorkPackage{} = work_package, _arguments) do
    MergeReconciler.reconcile_work_package(repo, work_package.id)
  end

  defp require_delivery_scope(work_package, payload) do
    repo_matches? = RepoIdentity.scope_match?(work_package.repo, payload["repository"], local_path_remotes?: true)
    expected_base = BaseBranch.canonicalize(work_package.base_branch)
    actual_base = BaseBranch.canonicalize(payload["base_branch"])

    cond do
      not repo_matches? -> {:error, :repository_mismatch}
      expected_base != actual_base -> {:error, :base_branch_mismatch}
      true -> :ok
    end
  end

  defp require_exact_head(_payload, nil), do: :ok
  defp require_exact_head(%{"head_sha" => head}, head), do: :ok
  defp require_exact_head(_payload, _head), do: {:error, :provider_head_mismatch}

  defp require_merge_evidence(payload) do
    if PullRequestProgress.merged?(payload), do: PullRequest.validate_merge_evidence(payload), else: :ok
  end

  defp persist(repo, actor, work_package, payload, pr_facts, dependency_inputs) do
    repo.transaction(fn ->
      with :ok <- lock_package(repo, work_package),
           {:ok, current} <- WorkPackageRepository.get(repo, work_package.id),
           :ok <- require_handoff(repo, current, payload),
           {:ok, candidate_head} <- Qualification.candidate_head(repo, current),
           :ok <- Qualification.record_pr(repo, actor, current, payload),
           :ok <- record_dependency_inputs(repo, actor, current, payload, dependency_inputs),
           {:ok, decision} <- decide(repo, current, pr_facts, candidate_head, payload),
           {:ok, updated} <- Qualification.apply_decision(repo, actor, current, decision, payload["head_sha"]) do
        result(updated, payload, decision, pr_facts)
      else
        {:tool_error, reason} -> repo.rollback({:tool_error, reason})
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      result -> result
    end
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  # A merged PR is recorded by the merge path, not qualified.
  defp decide(repo, current, pr_facts, candidate_head, payload) do
    if PullRequestProgress.merged?(payload),
      do: {:ok, {:hold, []}},
      else: Qualification.decide(repo, current, pr_facts, candidate_head)
  end

  defp result(updated, payload, decision, pr_facts) do
    result = %{status: updated.status, head_sha: payload["head_sha"], readiness_reasons: Qualification.decision_reasons(decision)}

    if pr_facts.review == :unknown,
      do: Map.put(result, :next_action, "review state unknown: check #{review_machine(updated)}"),
      else: result
  end

  defp review_machine(%WorkPackage{launch_machine: machine}) when is_binary(machine) and machine != "", do: machine
  defp review_machine(_package), do: "the worker's machine"

  # Which prerequisite inputs the current PR head consumed. A green PR can't
  # prove this, so the architect states it; the selection is validated against
  # the package's dependencies and the head just synced.
  defp record_dependency_inputs(_repo, _actor, _package, _payload, nil), do: :ok

  defp record_dependency_inputs(repo, actor, %WorkPackage{} = package, payload, selections) do
    selection = %{"type" => "dependency_inputs", "source_tool" => "sync_pr", "head_sha" => payload["head_sha"], "dependency_inputs" => selections}

    with :ok <- DependencyInputs.validate_selection(repo, package.id, selection),
         {:ok, _event} <- Qualification.append_event(repo, actor, package.id, Map.put(selection, "selection_revisions", selection_revisions(repo, selections)), "dependency_inputs_selected") do
      :ok
    end
  end

  # When a dependency's selection changes, the dependent must attest again, even
  # to the same input; the selections' revisions keep that attestation distinct
  # from an earlier one with the same payload.
  defp selection_revisions(repo, selections) do
    ids = Enum.map(selections, & &1["dependency_id"])

    repo.all(from(edge in DependencyEdge, where: edge.id in ^ids, select: {edge.id, edge.selection_updated_at}))
    |> Map.new(fn {id, updated_at} -> {id, updated_at && DateTime.to_iso8601(updated_at)} end)
  end

  # The review host is read before the transaction: it can take seconds.
  defp pr_facts(work_package, metadata, payload) do
    review = if PullRequestProgress.merged?(payload), do: :none, else: Qualification.review(work_package, payload["head_sha"])

    %{
      manual?: true,
      pr_state: metadata |> Map.get("state") |> normalize_state(),
      pr_draft?: Map.get(metadata, "draft") == true,
      ci_status: get_in(payload, ["check_summary", "status"]),
      review: review,
      head_sha: payload["head_sha"]
    }
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: nil

  defp require_handoff(repo, package, payload) do
    if PullRequestProgress.merged?(payload) do
      require_merged_handoff(repo, package, payload)
    else
      with :ok <- require_unowned(repo, package.id), do: require_in_flight(package)
    end
  end

  defp require_merged_handoff(repo, %WorkPackage{} = package, payload) do
    if Lifecycle.planned?(package),
      do: {:error, :invalid_work_package_status},
      else: require_same_pr(repo, package, payload)
  end

  defp require_same_pr(repo, %WorkPackage{} = package, payload) do
    with {:ok, state} <- PlanningRepository.get_state(repo, package.id),
         {:ok, current} <- PullRequestProgress.current_pr_state(state.progress_events),
         true <- PullRequestProgress.same_pr?(payload, current.ref) do
      :ok
    else
      false -> {:error, :pr_reference_mismatch}
      {:error, :missing_attached_pr} -> :ok
      error -> error
    end
  end

  defp require_in_flight(%WorkPackage{} = package) do
    if Lifecycle.in_flight?(package), do: :ok, else: {:error, :invalid_work_package_status}
  end

  defp lock_package(repo, work_package) do
    query = from(package in WorkPackage, where: package.id == ^work_package.id and package.contract_revision == ^work_package.contract_revision)

    case repo.update_all(query, set: [id: work_package.id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :stale_contract_revision}
    end
  end

  defp require_unowned(repo, work_package_id) do
    # A stale/missing observation never authorizes accepting over an existing claim.
    runtime = WorkPackageActivity.context(repo, work_package_id).runtime_state
    if runtime.active? or runtime.stale?, do: {:error, :active_runtime}, else: :ok
  end
end
