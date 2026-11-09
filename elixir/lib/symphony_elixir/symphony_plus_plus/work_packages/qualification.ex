defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Qualification do
  @moduledoc """
  Qualify and unqualify, shared by the `Observer` and `sync_pr`.

  Both record the PR they saw the same way (`record_pr/4`), gather the same
  facts for `Lifecycle.qualification/1` and apply the same decision:

    * a dispatched package qualifies when every predicate holds for the
      current head, no readiness gate (active blocker, missing evidence or
      findings) is open and no input is unknown;
    * a ready package unqualifies when a predicate is known to be false, or
      its PR now targets another base branch;
    * an unknown input (CI that reports nothing to the poller, a review host
      or another PR the stacking check needs that can't be read) blocks
      qualifying and never unqualifies.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.OperationalProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{PullRequestArtifact, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.ReviewStatus
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackage}

  @type review :: :done | :none | :pending | :unknown
  @type pr_facts :: %{
          required(:pr_state) => String.t() | nil,
          required(:pr_draft?) => boolean(),
          required(:ci_status) => String.t() | nil,
          required(:review) => review(),
          required(:head_sha) => String.t() | nil,
          optional(:manual?) => boolean(),
          optional(:base_matches?) => boolean(),
          optional(:stacked_on) => [String.t()] | :unknown
        }
  @type decision :: :qualify | {:unqualify, [String.t()]} | {:hold, [String.t()]}

  @doc """
  The review predicate for a package and PR head: `:none` when the package
  reviews in mode `none`, else the Review Suite state read by `review_id`.
  """
  @spec review(WorkPackage.t(), String.t() | nil) :: review()
  def review(%WorkPackage{review_mode: mode, review_id: review_id, launch_machine: machine}, head_sha)
      when mode in ["fast", "normal", "deep"] and is_binary(review_id) do
    review_id |> ReviewStatus.read(machine) |> ReviewStatus.state(head_sha)
  end

  def review(%WorkPackage{}, _head_sha), do: :none

  @doc """
  The head a ready package was qualified on (its recorded PR head); a
  dispatched package has none. Read it before recording a new snapshot.
  """
  @spec candidate_head(module(), WorkPackage.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def candidate_head(repo, %WorkPackage{} = package) do
    if Lifecycle.ready?(package), do: attached_head(repo, package), else: {:ok, nil}
  end

  defp attached_head(repo, %WorkPackage{} = package) do
    with {:ok, state} <- PlanningRepository.get_state(repo, package.id) do
      case PullRequestProgress.current_pr_state(state.progress_events) do
        {:ok, current} -> {:ok, current.payload["head_sha"]}
        {:error, :missing_attached_pr} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Records a PR snapshot: the branch, the attached PR and the synced snapshot."
  @spec record_pr(module(), Actor.t(), WorkPackage.t(), map()) :: :ok | {:error, term()}
  def record_pr(repo, %Actor{} = actor, %WorkPackage{} = package, payload) do
    branch = %{"type" => "branch", "source_tool" => "attach_branch", "branch" => payload["branch"], "head_sha" => payload["head_sha"], "observed_at" => payload["observed_at"]}

    with {:ok, _branch} <- append_event(repo, actor, package.id, branch, "branch_attached"),
         {:ok, _attachment} <- append_event(repo, actor, package.id, Map.put(payload, "source_tool", "attach_pr"), "pr_attached"),
         {:ok, _snapshot} <- append_event(repo, actor, package.id, Map.put(payload, "source_tool", "sync_pr"), "pr_synced"),
         {:ok, _changed?} <- PullRequestArtifact.upsert(repo, package.id, payload) do
      :ok
    end
  end

  @doc """
  Evaluates the predicates and readiness gates for `package` and returns the
  decision with every reason that keeps it from qualifying.
  """
  @spec decide(module(), WorkPackage.t(), pr_facts(), String.t() | nil) :: {:ok, decision()} | {:error, term()}
  def decide(repo, %WorkPackage{} = package, pr_facts, candidate_head) do
    with {:ok, state} <- PlanningRepository.get_state(repo, package.id),
         {:ok, graph} <- ExecutionGraph.evaluate(repo, package.work_request_id) do
      facts = facts(package, graph, pr_facts, candidate_head)
      gates = state |> OperationalProjection.readiness_failure_reasons() |> Enum.map(& &1["gate"])
      {:ok, decision(package, facts, gates)}
    end
  end

  defp facts(%WorkPackage{} = package, graph, pr_facts, candidate_head) do
    Map.merge(pr_facts, %{
      head_changed?: is_binary(candidate_head) and candidate_head != pr_facts.head_sha,
      dependencies_delivered?: ExecutionGraph.require_ready(graph, package.id) == :ok
    })
  end

  defp decision(%WorkPackage{} = package, facts, gates) do
    unknown = unknown_inputs(facts)
    scope = if Map.get(facts, :base_matches?) == false, do: ["pr_base_mismatch"], else: []
    reasons = reasons(Lifecycle.qualification(facts)) ++ scope
    definite = reasons(Lifecycle.qualification(assume_known(facts))) ++ scope

    cond do
      Lifecycle.dispatched?(package) and reasons == [] and gates == [] and unknown == [] -> :qualify
      Lifecycle.ready?(package) and definite != [] -> {:unqualify, definite}
      true -> {:hold, Enum.uniq(reasons ++ unknown ++ gates)}
    end
  end

  # An architect's manual sync accepts CI that reports no state; the poller
  # treats it as unknown.
  defp unknown_inputs(facts) do
    [
      {Map.get(facts, :ci_status) == "unknown" and not Map.get(facts, :manual?, false), "ci_unknown"},
      {facts.review == :unknown, "review_unknown"},
      {Map.get(facts, :stacked_on) == :unknown, "stacking_unknown"}
    ]
    |> Enum.flat_map(fn
      {true, reason} -> [reason]
      {false, _reason} -> []
    end)
  end

  defp assume_known(facts) do
    facts
    |> Map.update!(:review, &if(&1 == :unknown, do: :done, else: &1))
    |> Map.update(:ci_status, nil, &if(&1 == "unknown", do: "passing", else: &1))
    |> Map.update(:stacked_on, [], &if(&1 == :unknown, do: [], else: &1))
  end

  defp reasons(:qualified), do: []
  defp reasons({:unqualified, reasons}), do: reasons

  @doc """
  Applies a decision: qualifies a dispatched package, or unqualifies a ready
  one and records why.
  """
  @spec apply_decision(module(), Actor.t(), WorkPackage.t(), decision(), String.t() | nil) ::
          {:ok, WorkPackage.t()} | {:error, term()}
  def apply_decision(repo, _actor, %WorkPackage{} = package, :qualify, _head_sha), do: Lifecycle.transition(repo, package, :qualify)

  def apply_decision(repo, %Actor{} = actor, %WorkPackage{} = package, {:unqualify, reasons}, head_sha) do
    event = %{"type" => "lifecycle", "event" => "unqualify", "reasons" => reasons, "head_sha" => head_sha}

    with {:ok, updated} <- Lifecycle.transition(repo, package, :unqualify),
         {:ok, _event} <- append_event(repo, actor, package.id, event, "unqualified") do
      {:ok, updated}
    end
  end

  def apply_decision(_repo, _actor, %WorkPackage{} = package, {:hold, _reasons}, _head_sha), do: {:ok, package}

  @doc "The reasons a decision leaves the package unqualified."
  @spec decision_reasons(decision()) :: [String.t()]
  def decision_reasons(:qualify), do: []
  def decision_reasons({_kind, reasons}), do: reasons

  @doc false
  @spec append_event(module(), Actor.t(), String.t(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def append_event(repo, %Actor{} = actor, work_package_id, payload, status) do
    fingerprint = :crypto.hash(:sha256, Jason.encode!(payload)) |> Base.encode16(case: :lower)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, actor, work_package_id, %{
      "summary" => summary(actor),
      "status" => status,
      "idempotency_key" => "architect_pr_sync:#{status}:#{fingerprint}",
      "payload" => payload
    })
  end

  defp summary(%Actor{type: "system"}), do: "Observer recorded provider PR evidence"
  defp summary(%Actor{}), do: "Architect accepted provider PR evidence"
end
