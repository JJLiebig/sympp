defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch do
  @moduledoc """
  The ledger half of dispatching a WorkPackage.

  A planned package moves to `dispatched` and records its review mode, a newly
  minted Review Suite id (none for mode `none`) and the Herdr machine its
  worker launches on. Dispatching a package that is already `dispatched`
  replays: it keeps the stored review mode and id, so the worker's worktree and
  review stay the same. Preparing the worktree and writing the worker's
  assignment happen after this commits (`MCP.WorkPackageLaunch`).
  """

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, LedgerNamespace}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestPayloads
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type dispatch_result :: %{
          work_request: WorkRequest.t(),
          work_package: WorkPackage.t(),
          replay?: boolean()
        }

  @doc """
  Dispatches or replays one package. Options: `review_mode` (required, one of
  `WorkPackage.review_modes/0`), `launch_machine` and `dispatched_by`.
  """
  @spec dispatch(module(), String.t(), String.t(), keyword()) ::
          {:ok, dispatch_result()} | {:error, term()}
  def dispatch(repo, work_request_id, work_package_id, opts)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and is_list(opts) do
    # SQLite permits only one writer per ledger. Queue dispatches before checking
    # out connections, rather than making competing BEGIN IMMEDIATE calls wait
    # inside SQLite while the current dispatch still needs to execute queries.
    lock = {{__MODULE__, LedgerNamespace.key(Config.default(repo: repo))}, self()}

    :global.trans(lock, fn -> dispatch_locked(repo, work_request_id, work_package_id, opts) end, [node()])
  end

  defp dispatch_locked(repo, work_request_id, work_package_id, opts) do
    repo.transaction(
      fn ->
        case dispatch_transaction(repo, work_request_id, work_package_id, opts) do
          {:ok, result} -> result
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> DashboardPubSub.broadcast_changed_on_success()
  rescue
    error in Exqlite.Error ->
      if String.downcase(error.message) in ["database is locked", "database is busy"] do
        {:error, :database_busy}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp dispatch_transaction(repo, work_request_id, work_package_id, opts) do
    review_mode = Keyword.fetch!(opts, :review_mode)

    with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
         :ok <- Phase.require_writable(work_request),
         {:ok, %WorkPackage{} = work_package} <- Repository.get_work_package(repo, work_request_id, work_package_id),
         {:ok, dispatched, replay?} <- dispatch_package(repo, work_request, work_package, review_mode, opts) do
      {:ok, %{work_request: work_request, work_package: dispatched, replay?: replay?}}
    end
  end

  defp dispatch_package(repo, work_request, %WorkPackage{status: "planned"} = work_package, review_mode, opts) do
    with {:ok, execution_graph} <- ExecutionGraph.evaluate(repo, work_request.id),
         :ok <- ExecutionGraph.require_ready(execution_graph, work_package.id),
         :ok <- require_supported_branch_pattern(work_package.branch_pattern),
         {:ok, creation} <- CreateWork.activate(repo, work_package, broadcast?: false),
         {:ok, dispatched} <-
           creation.work_package
           |> Ecto.Changeset.change(
             dispatched_by: Keyword.get(opts, :dispatched_by),
             review_mode: review_mode,
             review_id: mint_review_id(review_mode),
             launch_machine: Keyword.get(opts, :launch_machine)
           )
           |> repo.update() do
      {:ok, dispatched, false}
    end
  end

  defp dispatch_package(repo, _work_request, %WorkPackage{status: "dispatched", review_mode: review_mode} = work_package, review_mode, opts) do
    machine = Keyword.get(opts, :launch_machine)

    if is_nil(machine) or machine == work_package.launch_machine do
      {:ok, work_package, true}
    else
      with {:ok, updated} <- work_package |> Ecto.Changeset.change(launch_machine: machine) |> repo.update(),
           do: {:ok, updated, true}
    end
  end

  defp dispatch_package(_repo, _work_request, %WorkPackage{status: "dispatched"} = work_package, _review_mode, _opts),
    do: {:error, {:review_mode_conflict, work_package.review_mode}}

  defp dispatch_package(_repo, _work_request, %WorkPackage{status: status}, _review_mode, _opts),
    do: {:error, {:invalid_work_package_status, status}}

  # Review Suite accepts a caller-supplied id matching `rvw_[a-z0-9]{8,32}`.
  defp mint_review_id("none"), do: nil
  defp mint_review_id(_review_mode), do: "rvw_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc """
  The redacted assignment a worker reads: package contract, context and prior
  progress. A product description or engineering scope that only
  repeats the WorkRequest's or the package's goal is left out.
  """
  @spec assignment(module(), WorkPackage.t()) :: {:ok, map()} | {:error, term()}
  def assignment(repo, %WorkPackage{} = work_package) do
    with {:ok, state} <- PlanningRepository.get_state(repo, work_package.id),
         {:ok, context} <- WorkRequestPayloads.worker_context(repo, work_package, work_package),
         {:ok, progress} <- WorkerContext.virtual_file_payload(state, "progress.md"),
         {:ok, handoff} <- WorkerContext.virtual_file_payload(state, "handoff.md") do
      work_package_payload =
        work_package
        |> WorkRequestPayloads.work_package()
        |> put_distinct("product_description", work_package.product_description, get_in(context, ["parent_work_request", "goal"]))
        |> put_distinct("engineering_scope", work_package.engineering_scope, work_package.goal)

      {:ok,
       context
       |> Map.merge(%{
         "prior_progress" => progress,
         "work_package" => work_package_payload,
         "delivery_context" => handoff
       })
       |> Redactor.json_safe()
       |> Redactor.redact_output()}
    end
  end

  defp put_distinct(payload, _key, value, value), do: payload
  defp put_distinct(payload, key, value, _repeated), do: Map.put(payload, key, value)

  @spec error_message(term()) :: String.t()
  def error_message(:not_found), do: "WorkRequest or WorkPackage was not found"
  def error_message(:work_request_archived), do: "WorkRequest is archived; restore it before dispatch"
  def error_message({:invalid_work_package_status, status}), do: "WorkPackage is #{status}; only a planned package dispatches, and a dispatched one replays"
  def error_message({:review_mode_conflict, stored}), do: "WorkPackage was dispatched with review_mode #{stored}; replay it with the same review_mode"

  def error_message({:execution_graph_cycle, cycles}),
    do: "WorkRequest execution graph contains a cycle across WorkPackages: #{inspect(cycles)}"

  def error_message({:unmet_work_package_dependencies, work_package_id, prerequisite_ids, _waiting_for}) do
    "WorkPackage #{work_package_id} depends on undelivered work: #{Enum.join(prerequisite_ids, ", ")}"
  end

  def error_message({:unsupported_branch_pattern, branch_pattern, reason}) do
    "WorkPackage branch_pattern #{inspect(branch_pattern)} is unsupported: #{BranchPattern.error_message(reason)}"
  end

  def error_message(reason), do: CreateWork.error_message(reason)

  @doc """
  What a package refused for undelivered prerequisites waits for. Only
  delivered closure satisfies a dependency: a merged PR, completion without a
  PR, or the delivery of every successor of a superseded or skipped package.
  """
  @spec waiting_next_action([map()]) :: String.t()
  def waiting_next_action(waiting_for) do
    {ended, open} = Enum.split_with(waiting_for, & &1.ended_as)

    wait =
      if open != [],
        do: ["wait for delivered closure (merged PR or completed without a PR) of #{Enum.map_join(open, ", ", &waited/1)}, then dispatch"],
        else: []

    dead_ends = Enum.map(ended, &"#{waited(&1)} ended #{&1.ended_as} and never delivers: #{dead_end_action(&1.ended_as)}")

    Enum.join(wait ++ dead_ends, "; ")
  end

  # Only a superseded or skipped package delivers through a successor.
  defp dead_end_action(outcome) when outcome in ["superseded", "skipped"], do: "add a successor that delivers it or remove the dependency"
  defp dead_end_action(_outcome), do: "remove the dependency or depend on a package that delivers it"

  defp waited(%{work_package_id: id, successor_of: nil}), do: id
  defp waited(%{work_package_id: id, successor_of: predecessor}), do: "#{id} (successor of #{predecessor})"

  defp require_supported_branch_pattern(branch_pattern) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsupported_branch_pattern, branch_pattern, reason}}
    end
  end
end
