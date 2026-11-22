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
    * an unknown input (CI that reports nothing, a review host or another PR
      the stacking check needs that can't be read) blocks qualifying, and
      unqualifies a ready package only once its PR head has moved off the head
      it qualified on.

  CI that reports nothing counts as known only in a repository that has never
  reported checks, and only on a manual `sync_pr` (`no_ci?`). An architect's
  `ci_override` for the current head accepts pending or no-state CI on both
  paths; recording a new head clears it. Failing CI is never accepted.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.OperationalProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestArtifact
  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
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
          optional(:no_ci?) => boolean(),
          optional(:base_matches?) => boolean(),
          optional(:stacked_on) => [String.t()] | :unknown
        }
  @type decision :: :qualify | {:unqualify, [String.t()]} | {:hold, [String.t()]}

  @doc """
  The review predicate for a package and PR head: `:none` when the package
  reviews in mode `none`, else the latest linked Review Suite state starting
  at the dispatch `review_id`.
  """
  @spec review(module(), WorkPackage.t(), String.t() | nil) :: review()
  def review(repo, %WorkPackage{id: id, review_mode: mode, review_id: review_id, launch_machine: route}, head_sha)
      when mode in ["fast", "normal", "deep"] and is_binary(review_id) do
    worker = repo |> Ownership.workers([id]) |> Map.get(id)
    machine = review_route(route, worker, HerdrCore.current())
    review_id |> ReviewStatus.read(machine) |> ReviewStatus.state(head_sha)
  end

  def review(_repo, %WorkPackage{}, _head_sha), do: :none

  @doc "Uses a local review read for a worker bound to the factory core, or returns the stored route."
  @spec review_route(String.t() | nil, WorkedOn.t() | nil, {:ok, HerdrCore.snapshot()} | :unavailable) ::
          String.t() | nil
  def review_route(route, %WorkedOn{terminal_key: key}, {:ok, %{core_id: core_id}}) do
    if match?({^core_id, _address}, Terminal.split_key(key)), do: nil, else: route
  end

  def review_route(route, _worker, _core), do: route

  @doc """
  The head a ready package was qualified on (its recorded PR head); a
  dispatched package has none. Read it before recording a new snapshot.
  """
  @spec candidate_head(module(), WorkPackage.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def candidate_head(repo, %WorkPackage{} = package) do
    if Lifecycle.ready?(package), do: attached_head(repo, package), else: {:ok, nil}
  end

  defp attached_head(repo, %WorkPackage{} = package) do
    with {:ok, attachments} <- PlanningRepository.pr_attachments(repo, [package.id]) do
      case attachments[package.id] do
        {:ok, %{head_sha: head_sha}} -> {:ok, head_sha}
        nil -> {:ok, nil}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Records a PR snapshot: the branch, the attached PR and the synced snapshot.
  A CI override recorded for another head is cleared, and a snapshot that
  reports checks marks its repository as having CI.
  """
  @spec record_pr(module(), Actor.t(), WorkPackage.t(), map()) :: :ok | {:error, term()}
  def record_pr(repo, %Actor{} = actor, %WorkPackage{} = package, payload) do
    branch = %{"type" => "branch", "source_tool" => "attach_branch", "branch" => payload["branch"], "head_sha" => payload["head_sha"], "observed_at" => payload["observed_at"]}

    with {:ok, _branch} <- append_event(repo, actor, package.id, branch, "branch_attached"),
         {:ok, _attachment} <- append_event(repo, actor, package.id, Map.put(payload, "source_tool", "attach_pr"), "pr_attached"),
         {:ok, _snapshot} <- append_event(repo, actor, package.id, Map.put(payload, "source_tool", "sync_pr"), "pr_synced"),
         {:ok, _changed?} <- PullRequestArtifact.upsert(repo, package.id, payload),
         {:ok, _package} <- clear_ci_override(repo, package, payload["head_sha"]) do
      close_pre_pr_review(repo, package.id)
      note_repository_ci(repo, payload)
    end
  end

  defp close_pre_pr_review(repo, id) do
    # A pre-PR display read started before this attachment cannot publish
    # review or outage evidence for the attached PR.
    query = from(observation in Observation, where: observation.work_package_id == ^id and observation.pr_absent)
    repo.update_all(query, set: [pr_absent: false])
  end

  @doc """
  Whether a PR snapshot recorded for this GitHub repository (`owner/name`) has
  ever reported checks. Kept apart from package history, so retention doesn't
  erase it.
  """
  @spec repository_has_ci?(module(), String.t()) :: boolean()
  def repository_has_ci?(repo, repository) when is_binary(repository) do
    repo.exists?(from(row in "sympp_repositories_with_ci", where: row.repository == ^String.downcase(repository)))
  end

  @doc "Marks a snapshot's repository as having CI when the snapshot reports checks."
  @spec note_repository_ci(module(), map()) :: :ok
  def note_repository_ci(repo, %{"repository" => repository, "check_summary" => %{"status" => status}})
      when is_binary(repository) and status in ["passing", "failing", "pending"] do
    repo.insert_all("sympp_repositories_with_ci", [%{repository: String.downcase(repository)}], on_conflict: :nothing)
    :ok
  end

  def note_repository_ci(_repo, _payload), do: :ok

  @doc "Records an architect's CI override for `head`, replacing any earlier one."
  @spec put_ci_override(module(), WorkPackage.t(), %{reason: String.t(), by: String.t(), head: String.t()}) ::
          {:ok, WorkPackage.t()} | {:error, term()}
  def put_ci_override(repo, %WorkPackage{} = package, %{reason: reason, by: by, head: head}) do
    package |> Ecto.Changeset.change(ci_override: %{"reason" => reason, "by" => by, "head" => head}) |> repo.update()
  end

  defp clear_ci_override(repo, %WorkPackage{ci_override: %{"head" => override_head}} = package, head) when override_head != head,
    do: package |> Ecto.Changeset.change(ci_override: nil) |> repo.update()

  defp clear_ci_override(_repo, %WorkPackage{} = package, _head), do: {:ok, package}

  defp ci_override?(%WorkPackage{ci_override: %{"head" => head}}, head) when is_binary(head), do: true
  defp ci_override?(%WorkPackage{}, _head), do: false

  @doc """
  Evaluates the predicates and readiness gates for `package` and returns the
  decision with every reason that keeps it from qualifying.
  """
  @spec decide(module(), WorkPackage.t(), pr_facts(), String.t() | nil) :: {:ok, decision()} | {:error, term()}
  def decide(repo, %WorkPackage{} = package, pr_facts, candidate_head) do
    with {:ok, state} <- PlanningRepository.get_state(repo, package.id),
         {:ok, graph} <- ExecutionGraph.evaluate(repo, package.work_request_id) do
      facts =
        pr_facts
        |> Map.put(:dependencies_delivered?, ExecutionGraph.require_ready(graph, package.id) == :ok)
        |> Map.put(:ci_override?, ci_override?(package, pr_facts.head_sha))

      gates = state |> OperationalProjection.readiness_failure_reasons() |> Enum.map(& &1["gate"])
      moved? = is_binary(candidate_head) and candidate_head != pr_facts.head_sha
      {:ok, decision(package, facts, gates, moved?)}
    end
  end

  # Readiness holds through an unknown input only on the head it was qualified
  # on; a new head's unknown CI, review or stacking is unproven.
  defp decision(%WorkPackage{} = package, facts, gates, moved?) do
    unknown = unknown_inputs(facts)
    scope = if Map.get(facts, :base_matches?) == false, do: ["pr_base_mismatch"], else: []
    reasons = reasons(Lifecycle.qualification(facts)) ++ scope
    definite = definite_reasons(facts, reasons, unknown, scope, moved?)

    cond do
      Lifecycle.dispatched?(package) and reasons == [] and gates == [] and unknown == [] -> :qualify
      Lifecycle.ready?(package) and definite != [] -> {:unqualify, definite}
      true -> {:hold, Enum.uniq(reasons ++ unknown ++ gates)}
    end
  end

  # On a moved head, CI that reports no state is unproven unless the architect
  # overrode CI for that head.
  defp definite_reasons(facts, reasons, unknown, _scope, true = _moved?) do
    ci = if Map.get(facts, :ci_status) == "unknown" and not facts.ci_override?, do: ["ci_unknown"], else: []
    Enum.uniq(reasons ++ unknown ++ ci)
  end

  defp definite_reasons(facts, _reasons, _unknown, scope, false = _moved?), do: reasons(Lifecycle.qualification(assume_known(facts))) ++ scope

  defp unknown_inputs(facts) do
    ci_known? = Map.get(facts, :no_ci?, false) or facts.ci_override?

    [
      {Map.get(facts, :ci_status) == "unknown" and not ci_known?, "ci_unknown"},
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
