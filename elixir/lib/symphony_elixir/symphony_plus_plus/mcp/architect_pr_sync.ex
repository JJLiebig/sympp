defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectPRSync do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments, only: [optional_string_argument: 2]

  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{
    Client,
    DefaultClient,
    DryClient,
    MergeReconciler,
    PullRequest,
    PullRequestArtifact,
    PullRequestProgress
  }

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackage, WorkPackageActivity}

  @spec sync(module(), Session.t(), WorkPackage.t(), map()) :: {:ok, map()} | {:error, term()} | {:tool_error, term()}
  def sync(repo, %Session{} = session, %WorkPackage{} = work_package, arguments)
      when is_map_key(arguments, "url") or is_map_key(arguments, "number") do
    client = Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient)

    with {:ok, expected_head} <- optional_string_argument(arguments, "head_sha"),
         {:ok, ref} <- PullRequest.parse(arguments, work_package.repo),
         {:ok, metadata} <- Client.fetch_pull_request(client, ref, provider_snapshot: true),
         {:ok, payload} <- PullRequest.provider_snapshot(metadata, ref, expected_head),
         :ok <- require_delivery_scope(work_package, payload),
         :ok <- require_exact_head(payload, expected_head),
         :ok <- require_merge_evidence(payload),
         {:ok, result} <- persist(repo, session, work_package, payload, pr_facts(metadata, payload)) do
      if PullRequestProgress.merged?(payload) do
        MergeReconciler.reconcile_work_package(repo, work_package.id, pr_payload: payload, client: DryClient, metadata: payload)
      else
        {:ok, result}
      end
    end
  end

  def sync(repo, %Session{} = session, %WorkPackage{} = work_package, %{"head_sha" => _head} = arguments) do
    with {:ok, state} <- PlanningRepository.get_state(repo, work_package.id),
         {:ok, current} <- PullRequestProgress.current_pr_state(state.progress_events) do
      sync(repo, session, work_package, Map.put(arguments, "url", current.ref.url))
    end
  end

  def sync(repo, %Session{}, %WorkPackage{} = work_package, _arguments) do
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

  defp persist(repo, session, work_package, payload, pr_facts) do
    repo.transaction(fn ->
      with :ok <- lock_package(repo, work_package),
           {:ok, current} <- WorkPackageRepository.get(repo, work_package.id),
           :ok <- require_handoff(repo, current, payload),
           {:ok, candidate_head} <- candidate_head(repo, current),
           :ok <- append_snapshot(repo, session, current, payload),
           {:ok, graph} <- ExecutionGraph.evaluate(repo, current.work_request_id),
           qualification = Lifecycle.qualification(qualification_facts(current, graph, pr_facts, candidate_head, payload)),
           {:ok, updated} <- reconcile_qualification(repo, session, current, qualification, payload) do
        %{status: updated.status, head_sha: payload["head_sha"], readiness_reasons: qualification_reasons(qualification)}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp pr_facts(metadata, payload) do
    %{
      pr_state: metadata |> Map.get("state") |> normalize_state(),
      pr_draft?: Map.get(metadata, "draft") == true,
      ci_status: get_in(payload, ["check_summary", "status"])
    }
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: nil

  # A ready package's candidate head is frozen; a dispatched package has none.
  defp candidate_head(repo, %WorkPackage{} = package) do
    if Lifecycle.ready?(package) do
      with {:ok, state} <- PlanningRepository.get_state(repo, package.id) do
        case PullRequestProgress.current_pr_state(state.progress_events) do
          {:ok, current} -> {:ok, current.payload["head_sha"]}
          {:error, :missing_attached_pr} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:ok, nil}
    end
  end

  defp qualification_facts(%WorkPackage{} = package, graph, pr_facts, candidate_head, payload) do
    incoming = Enum.filter(graph.effective_edges, &(&1.dependent_work_package_id == package.id))

    Map.merge(pr_facts, %{
      manual?: true,
      # Review state is not observed yet: until dispatch records a review mode,
      # a package needs no review to qualify.
      review: :none,
      head_changed?: is_binary(candidate_head) and candidate_head != payload["head_sha"],
      dependencies_available?: ExecutionGraph.require_ready(graph, package.id) == :ok,
      dependency_inputs_current?: not Enum.any?(incoming, &Enum.any?(&1.constraints, fn constraint -> not constraint.input_current end))
    })
  end

  defp qualification_reasons(:qualified), do: []
  defp qualification_reasons({:unqualified, reasons}), do: reasons

  defp reconcile_qualification(repo, session, %WorkPackage{} = package, qualification, payload) do
    cond do
      PullRequestProgress.merged?(payload) -> {:ok, package}
      Lifecycle.dispatched?(package) and qualification == :qualified -> Lifecycle.transition(repo, package, :qualify)
      Lifecycle.ready?(package) and qualification != :qualified -> unqualify(repo, session, package, qualification, payload)
      true -> {:ok, package}
    end
  end

  defp unqualify(repo, session, %WorkPackage{} = package, qualification, payload) do
    event = %{"type" => "lifecycle", "event" => "unqualify", "reasons" => qualification_reasons(qualification), "head_sha" => payload["head_sha"]}

    with {:ok, updated} <- Lifecycle.transition(repo, package, :unqualify),
         {:ok, _event} <- append_event(repo, session, package.id, event, "unqualified") do
      {:ok, updated}
    end
  end

  defp require_handoff(repo, package, payload) do
    if PullRequestProgress.merged?(payload) do
      require_merged_handoff(repo, package, payload)
    else
      with :ok <- require_unowned(repo, package.id), do: require_in_flight(package)
    end
  end

  defp require_merged_handoff(repo, %WorkPackage{} = package, payload) do
    if Lifecycle.planned?(package) do
      {:error, :invalid_work_package_status}
    else
      with {:ok, state} <- PlanningRepository.get_state(repo, package.id),
           {:ok, current} <- PullRequestProgress.current_pr_state(state.progress_events) do
        if PullRequestProgress.same_pr?(payload, current.ref), do: :ok, else: {:error, :pr_reference_mismatch}
      else
        {:error, :missing_attached_pr} -> :ok
        error -> error
      end
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

  defp append_snapshot(repo, session, work_package, payload) do
    branch = %{"type" => "branch", "source_tool" => "attach_branch", "branch" => payload["branch"], "head_sha" => payload["head_sha"], "observed_at" => payload["observed_at"]}

    with {:ok, _branch} <- append_event(repo, session, work_package.id, branch, "branch_attached"),
         {:ok, _attachment} <- append_event(repo, session, work_package.id, Map.put(payload, "source_tool", "attach_pr"), "pr_attached"),
         {:ok, _snapshot} <- append_event(repo, session, work_package.id, Map.put(payload, "source_tool", "sync_pr"), "pr_synced"),
         {:ok, _changed?} <- PullRequestArtifact.upsert(repo, work_package.id, payload) do
      :ok
    end
  end

  defp append_event(repo, session, work_package_id, payload, status) do
    fingerprint = :crypto.hash(:sha256, Jason.encode!(payload)) |> Base.encode16(case: :lower)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, %{
      "summary" => "Architect accepted provider PR evidence",
      "status" => status,
      "idempotency_key" => "architect_pr_sync:#{status}:#{fingerprint}",
      "payload" => payload
    })
  end
end
