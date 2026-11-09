defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle do
  @moduledoc """
  The only writer of WorkPackage status.

  A WorkPackage is `planned`, `dispatched`, `ready` or `ended`. Progress inside
  `dispatched` is derived from signals and never stored. An ended package has
  exactly one ending row (`WorkPackageDelivery`), which is the only record of
  how it ended; `DeliveryCloseout` writes that row and ends the package through
  `transition/4` in the same transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Ownership
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Blockers, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase, as: WorkRequestPhase

  @planned "planned"
  @dispatched "dispatched"
  @ready "ready"
  @ended "ended"
  @statuses [@planned, @dispatched, @ready, @ended]
  @open_statuses [@planned, @dispatched, @ready]
  @in_flight_statuses [@dispatched, @ready]

  @transitions %{
    dispatch: {[@planned], @dispatched},
    qualify: {[@dispatched], @ready},
    unqualify: {[@ready], @dispatched},
    end: {@open_statuses, @ended}
  }

  # The statuses each ending outcome may be recorded from.
  @ending_sources %{
    "pr_merged" => @in_flight_statuses,
    "finished" => @in_flight_statuses,
    "completed_no_pr" => @in_flight_statuses,
    "abandoned" => @in_flight_statuses,
    "skipped" => [@planned],
    "superseded" => @open_statuses
  }

  @type event :: :dispatch | :qualify | :unqualify | :end
  @type error :: :invalid_status | :stale_status | :not_found | term()

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec open_statuses() :: [String.t()]
  def open_statuses, do: @open_statuses

  @spec in_flight_statuses() :: [String.t()]
  def in_flight_statuses, do: @in_flight_statuses

  @spec planned?(WorkPackage.t() | map() | String.t() | nil) :: boolean()
  def planned?(package_or_status), do: status(package_or_status) == @planned

  @spec dispatched?(WorkPackage.t() | map() | String.t() | nil) :: boolean()
  def dispatched?(package_or_status), do: status(package_or_status) == @dispatched

  @spec ready?(WorkPackage.t() | map() | String.t() | nil) :: boolean()
  def ready?(package_or_status), do: status(package_or_status) == @ready

  @spec ended?(WorkPackage.t() | map() | String.t() | nil) :: boolean()
  def ended?(package_or_status), do: status(package_or_status) == @ended

  @spec in_flight?(WorkPackage.t() | map() | String.t() | nil) :: boolean()
  def in_flight?(package_or_status), do: status(package_or_status) in @in_flight_statuses

  @spec ending_sources(String.t()) :: [String.t()]
  def ending_sources(outcome), do: Map.get(@ending_sources, outcome, [])

  @doc """
  Applies one lifecycle event as a compare-and-set on the current status.

  Options:
    * `:outcome` (required for `:end`) - the ending outcome being recorded;
    * `:expected_contract_revision` - also require this contract revision.

  `:end` runs the terminal effects in the same transaction. The other events
  clear a cached WorkRequest completion, because the request has open work again.
  """
  @spec transition(module(), WorkPackage.t(), event(), keyword()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def transition(repo, %WorkPackage{} = work_package, event, opts \\ []) when is_atom(repo) and is_list(opts) do
    with {:ok, {from_statuses, next_status}} <- fetch_transition(event),
         :ok <- require_source(work_package, event, from_statuses, opts) do
      repo.transaction(fn -> write_with_effects(repo, work_package, event, next_status, opts) end)
      |> broadcast(repo)
    end
  end

  defp write_with_effects(repo, work_package, event, next_status, opts) do
    with {:error, reason} <- WorkRequestPhase.require_writable_package(repo, work_package.id), do: repo.rollback(reason)

    case write_status(repo, work_package, next_status, opts) do
      {:ok, updated} -> apply_effects(repo, event, updated)
      {:error, reason} -> repo.rollback(reason)
    end
  end

  @doc """
  Terminal effects for packages that just ended: end their worked-on rows,
  clear their active blockers, withdraw the open asks that name them and queue
  their worktree cleanup.
  """
  @spec apply_terminal_effects(module(), WorkPackage.t() | [WorkPackage.t()]) :: :ok | {:error, term()}
  def apply_terminal_effects(repo, %WorkPackage{} = work_package), do: apply_terminal_effects(repo, [work_package])
  def apply_terminal_effects(_repo, []), do: :ok

  def apply_terminal_effects(repo, work_packages) when is_atom(repo) and is_list(work_packages) do
    Enum.each(work_packages, &Ownership.end_subject(repo, "work_package", &1.id))
    work_package_ids = Enum.map(work_packages, & &1.id)

    with :ok <- clear_active_blockers(repo, work_package_ids),
         :ok <- Asks.withdraw_for_packages(repo, work_package_ids) do
      WorktreeCleanupQueue.enqueue_terminal(repo, work_packages)
    end
  end

  @doc """
  The qualification predicates for `qualify` and `unqualify`, evaluated for the
  current PR head. A package qualifies only when every predicate holds:

    1. the PR is open and not a draft;
    2. CI is green for the current head (an architect's manual `sync_pr` also
       accepts CI that reports no state at all);
    3. review is done for the current head, or the package needs no review;
    4. dependency inputs are current: prerequisites are available and the
       recorded consumed-input selection matches the current head.

  Returns the reasons for every predicate that does not hold.
  """
  @spec qualification(map()) :: :qualified | {:unqualified, [String.t()]}
  def qualification(facts) when is_map(facts) do
    ci_accepted = if Map.get(facts, :manual?, false), do: ["passing", "unknown"], else: ["passing"]

    [
      {Map.get(facts, :pr_state) != "open", "pr_not_open"},
      {Map.get(facts, :pr_draft?) == true, "pr_draft"},
      {Map.get(facts, :ci_status) not in ci_accepted, "ci_not_green"},
      {Map.get(facts, :review) not in [:done, :none], "review_not_done"},
      {Map.get(facts, :head_changed?) == true, "head_changed"},
      {Map.get(facts, :dependencies_available?) == false, "dependencies_unavailable"},
      {Map.get(facts, :dependency_inputs_current?) == false, "dependency_inputs_stale"}
    ]
    |> Enum.flat_map(fn
      {true, reason} -> [reason]
      {false, _reason} -> []
    end)
    |> case do
      [] -> :qualified
      reasons -> {:unqualified, reasons}
    end
  end

  @doc """
  The single `next_action` derivation for a package.

  Facts (all optional):
    * `:dependencies_met?` - false while a prerequisite is undelivered;
    * `:progress` - derived progress inside `dispatched`: `"launching"`,
      `"implementing"`, `"worker_exited"` or `"review_ci"`;
    * `:attention?` - CI failed, or review findings or a review that no longer
      covers the current head;
    * `:worker_idle?` - the worker terminal is idle;
    * `:merge_rights?` - false when the PR targets a repository sympp cannot merge.
  """
  @spec next_action(WorkPackage.t() | map() | String.t() | nil, map()) ::
          %{action: String.t() | nil, actor: String.t() | nil}
  def next_action(package_or_status, facts \\ %{}) when is_map(facts) do
    case status(package_or_status) do
      @planned -> planned_next_action(facts)
      @dispatched -> dispatched_next_action(facts)
      @ready -> ready_next_action(facts)
      _ended_or_unknown -> %{action: nil, actor: nil}
    end
  end

  defp planned_next_action(%{dependencies_met?: false}), do: %{action: "deliver_prerequisites", actor: "architect"}
  defp planned_next_action(_facts), do: %{action: "dispatch_work_package", actor: "architect"}

  defp dispatched_next_action(facts) do
    case Map.get(facts, :progress) do
      "launching" -> %{action: "run_launch_line", actor: "architect"}
      "worker_exited" -> %{action: "inspect_worker", actor: "architect"}
      "review_ci" -> review_ci_next_action(facts)
      _implementing -> %{action: "wait", actor: "worker"}
    end
  end

  defp review_ci_next_action(%{attention?: true, worker_idle?: true}), do: %{action: "inspect_worker", actor: "architect"}
  defp review_ci_next_action(_facts), do: %{action: "wait", actor: "worker"}

  # A ready package whose CI failed or whose review no longer covers its head is
  # re-synced, which unqualifies it.
  defp ready_next_action(%{attention?: true}), do: %{action: "sync_pr", actor: "architect"}
  defp ready_next_action(%{merge_rights?: false}), do: %{action: "finish", actor: "operator"}
  defp ready_next_action(_facts), do: %{action: "merge_pr", actor: "architect"}

  defp fetch_transition(event) do
    case Map.fetch(@transitions, event) do
      {:ok, transition} -> {:ok, transition}
      :error -> {:error, :invalid_status}
    end
  end

  defp require_source(%WorkPackage{status: status}, :end, _from_statuses, opts) do
    if status in ending_sources(Keyword.get(opts, :outcome)), do: :ok, else: {:error, :invalid_status}
  end

  defp require_source(%WorkPackage{status: status}, _event, from_statuses, _opts) do
    if status in from_statuses, do: :ok, else: {:error, :invalid_status}
  end

  defp write_status(repo, %WorkPackage{} = work_package, next_status, opts) do
    now = DateTime.utc_now(:microsecond)
    set = [status: next_status, updated_at: now] ++ dispatch_fields(next_status, work_package, now)

    work_package
    |> status_query(Keyword.get(opts, :expected_contract_revision))
    |> repo.update_all(set: set)
    |> case do
      {1, _rows} -> {:ok, repo.get!(WorkPackage, work_package.id)}
      {0, _rows} -> {:error, stale_status_error(repo, work_package.id)}
    end
  end

  defp dispatch_fields(@dispatched, %WorkPackage{dispatched_at: nil}, now), do: [dispatched_at: now]
  defp dispatch_fields(_next_status, _work_package, _now), do: []

  defp status_query(%WorkPackage{id: id, status: status}, nil) do
    from(package in WorkPackage, where: package.id == ^id and package.status == ^status)
  end

  defp status_query(%WorkPackage{id: id, status: status}, revision) do
    from(package in WorkPackage,
      where: package.id == ^id and package.status == ^status and package.contract_revision == ^revision
    )
  end

  defp stale_status_error(repo, id) do
    if repo.get(WorkPackage, id), do: :stale_status, else: :not_found
  end

  defp apply_effects(repo, :end, %WorkPackage{} = work_package) do
    case apply_terminal_effects(repo, work_package) do
      :ok -> work_package
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp apply_effects(_repo, _event, %WorkPackage{} = work_package), do: work_package

  defp broadcast({:ok, %WorkPackage{}} = result, repo) do
    unless repo.in_transaction?(), do: DashboardPubSub.broadcast_changed()
    result
  end

  defp broadcast(result, _repo), do: result

  # A blocker on an archived WorkRequest stays in its frozen history.
  defp clear_active_blockers(repo, work_package_ids) do
    with {:ok, events} <- PlanningRepository.list_progress_events(repo, work_package_ids) do
      events
      |> Enum.group_by(& &1.work_package_id)
      |> Enum.sort_by(fn {work_package_id, _events} -> work_package_id end)
      |> Enum.flat_map(fn {work_package_id, events} -> events |> BlockerProjection.blockers() |> Enum.filter(& &1.active) |> Enum.map(&{work_package_id, &1}) end)
      |> Enum.reduce_while(:ok, fn {work_package_id, blocker}, :ok -> clear_blocker(repo, work_package_id, blocker) end)
    end
  end

  defp clear_blocker(repo, work_package_id, blocker) do
    with :ok <- WorkRequestPhase.require_writable_package(repo, work_package_id),
         {:ok, _blocker, :changed} <-
           Blockers.append(repo, nil, work_package_id, blocker.id, false, "Cleared blocker when the package ended: #{blocker.summary || blocker.id}", nil) do
      {:cont, :ok}
    else
      {:error, :work_request_archived} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp status(%{status: status}), do: status
  defp status(%{"status" => status}), do: status
  defp status(status) when is_binary(status), do: status
  defp status(_value), do: nil
end
