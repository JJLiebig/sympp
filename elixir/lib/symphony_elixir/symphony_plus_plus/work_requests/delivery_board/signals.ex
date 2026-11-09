defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, ExecutionGraph}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @request_chunk_size 400
  @string_limit 240

  @spec execution_graphs(module(), [WorkRequest.t()], map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execution_graphs(_repo, [], _work_packages_by_request, _deliveries_by_slice_id, _opts), do: {:ok, %{}}

  def execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts) do
    load_execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts)
  end

  defp load_execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)
    product_trees_by_request = preloaded_product_trees(opts)
    missing_work_request_ids = Enum.reject(work_request_ids, &Map.has_key?(product_trees_by_request, &1))

    edges_by_request = execution_edges_by_request(repo, missing_work_request_ids)

    deliveries_by_request =
      deliveries_by_slice_id
      |> Map.values()
      |> Enum.group_by(& &1.work_request_id)

    Enum.reduce_while(work_requests, {:ok, %{}}, fn %WorkRequest{} = work_request, {:ok, graphs} ->
      work_packages = Map.get(work_packages_by_request, work_request.id, [])
      deliveries = Map.get(deliveries_by_request, work_request.id, [])

      product_tree =
        product_tree_for_request(work_request.id, product_trees_by_request, edges_by_request)

      case ExecutionGraph.successors(repo, work_packages) do
        {:ok, successors} ->
          graph = ExecutionGraph.evaluate(product_tree, work_packages, deliveries, successors)
          {:cont, {:ok, Map.put(graphs, work_request.id, scope_execution_graph(graph, work_packages, opts))}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  rescue
    error in Exqlite.Error ->
      if missing_product_tree_schema_error?(error), do: {:ok, %{}}, else: normalize_exqlite_error(error)
  end

  defp preloaded_product_trees(opts) do
    case Keyword.fetch(opts, :product_trees_by_request) do
      {:ok, product_trees} when is_map(product_trees) -> product_trees
      :error -> %{}
      {:ok, _other} -> %{}
    end
  end

  defp product_tree_for_request(work_request_id, product_trees_by_request, edges_by_request) do
    case Map.fetch(product_trees_by_request, work_request_id) do
      {:ok, {:ok, product_tree}} ->
        product_tree

      {:ok, {:error, _reason}} ->
        %{dependency_edges: []}

      :error ->
        %{dependency_edges: Map.get(edges_by_request, work_request_id, [])}
    end
  end

  defp execution_edges_by_request(_repo, []), do: %{}

  defp execution_edges_by_request(repo, work_request_ids) do
    work_request_ids
    |> Enum.chunk_every(@request_chunk_size)
    |> Enum.flat_map(fn request_id_chunk ->
      repo.all(
        from(edge in DependencyEdge,
          where: edge.work_request_id in ^request_id_chunk,
          order_by: [asc: edge.work_request_id, asc: edge.kind, asc: edge.created_at, asc: edge.id]
        )
      )
    end)
    |> Enum.group_by(& &1.work_request_id)
  end

  @spec pr(map(), map() | nil, map() | nil) :: map()
  def pr(metadata, delivery \\ nil, observed \\ nil) do
    case map_value(metadata, "pr") do
      nil ->
        %{status: "none"}

      %{} = pr ->
        raw_head_sha = map_value(pr, "head_sha")

        raw_current_head_sha =
          map_value(pr, "current_head_sha") ||
            metadata |> map_value("branch") |> map_value("head_sha")

        head_sha = bounded_string(raw_head_sha)
        current_head_sha = bounded_string(raw_current_head_sha)

        %{
          status: pr_status(pr),
          url: bounded_string(map_value(pr, "url")),
          number: integer_value(first_map_value(pr, ["number", "pr_number"])),
          repository: bounded_string(first_map_value(pr, ["repository", "pr_repository"])),
          head_sha: head_sha,
          current_head_sha: current_head_sha,
          created_at: map_value(pr, "created_at"),
          updated_at: map_value(pr, "updated_at"),
          observed_at: map_value(pr, "observed_at"),
          source: if(map_value(pr, "provider_reference"), do: "provider", else: "recorded_pr"),
          merged_at: map_value(pr, "merged_at"),
          head_changed_at: map_value(pr, "head_changed_at"),
          head_matches:
            if(filled_string?(raw_head_sha) and filled_string?(raw_current_head_sha),
              do: PullRequest.head_sha_matches?(raw_head_sha, raw_current_head_sha)
            ),
          checks: checks(map_value(pr, "check_summary"), map_value(pr, "checks_changed_at"), failing_checks(observed, raw_head_sha)),
          github_review: github_review(observed, raw_head_sha)
        }
        |> reject_nil_values()

      _invalid ->
        %{status: "unavailable"}
    end
    |> override_pr_status(delivery)
  end

  @spec review(WorkPackage.t(), map()) :: map() | nil
  def review(work_package, metadata), do: review(work_package, metadata, nil)

  @doc """
  The review signal: the Review Suite cycle the Observer read by `review_id`
  for packages dispatched with a review mode, else the contract's declared
  review requirement.
  """
  @spec review(WorkPackage.t(), map(), map() | nil) :: map() | nil
  def review(%WorkPackage{review_mode: mode, review_id: review_id}, _metadata, observation) when mode in ["fast", "normal", "deep"] do
    %{
      type: "review-suite",
      mode: mode,
      status: map_value(observation, "status") || "pending",
      evidence_id: review_id,
      current: observation |> map_value("current") |> integer_value(),
      total: observation |> map_value("total") |> integer_value(),
      step: observation |> map_value("step") |> bounded_string(),
      accepted_head: observation |> map_value("accepted_head") |> bounded_string(),
      reviewed_head: reviewed_head(observation),
      validation: observation |> map_value("validation") |> Sanitizer.redacted_json(),
      provider_status: observation |> map_value("provider_status") |> bounded_string(),
      next_action: observation |> map_value("next_action") |> bounded_string(),
      round: observation |> map_value("round") |> integer_value(),
      steps: map_value(observation, "steps"),
      round_history: map_value(observation, "round_history"),
      started_at: map_value(observation, "started_at"),
      round_started_at: map_value(observation, "round_started_at"),
      observed_at: map_value(observation, "observed_at"),
      observation_state: review_observation_state(observation)
    }
    |> reject_nil_values()
  end

  def review(%WorkPackage{review_requirement: nil}, _metadata, _observation), do: nil

  def review(%WorkPackage{review_requirement: requirement}, _metadata, observation) when is_map(requirement) do
    type = bounded_string(map_value(requirement, "type"))
    args = map_value(requirement, "args")
    evidence = [observation, args]

    %{
      type: type,
      mode: evidence |> signal_value(["mode"]) |> bounded_string(),
      args: if(is_map(args), do: Sanitizer.redacted_json(args)),
      status: map_value(observation, "status") || if(filled_string?(type), do: "pending", else: "unavailable"),
      current: evidence |> signal_value(["current", "completed", "completed_count"]) |> integer_value(),
      total: evidence |> signal_value(["total", "total_count"]) |> integer_value(),
      step: evidence |> signal_value(["step", "stage"]) |> bounded_string(),
      evidence_id: evidence |> signal_value(["evidence_id", "reference", "id"]) |> bounded_string(),
      reviewed_head: evidence |> signal_value(["head_sha", "reviewed_head"]) |> bounded_string(),
      current_head: observation |> map_value("current_head") |> bounded_string(),
      validation: observation |> map_value("validation") |> Sanitizer.redacted_json(),
      provider_status: observation |> map_value("provider_status") |> bounded_string(),
      next_action: observation |> map_value("next_action") |> bounded_string(),
      round: observation |> map_value("round") |> integer_value(),
      steps: map_value(observation, "steps"),
      round_history: map_value(observation, "round_history"),
      started_at: map_value(observation, "started_at"),
      round_started_at: map_value(observation, "round_started_at"),
      observed_at: map_value(observation, "observed_at"),
      observation_state: review_observation_state(observation)
    }
    |> reject_nil_values()
  end

  def review(%WorkPackage{}, _metadata, _observation), do: %{status: "unavailable"}

  # The head Review Suite actually reviewed, shown only when the review was
  # carried to another head (a merge or rebase with an unchanged patch).
  defp reviewed_head(observation) do
    reviewed = observation |> map_value("reviewed_head") |> bounded_string()
    if reviewed == observation |> map_value("accepted_head") |> bounded_string(), do: nil, else: reviewed
  end

  @spec board_state(WorkPackage.t(), map(), map() | nil) :: map()
  def board_state(work_package, summary, delivery) do
    pr = Map.get(summary, :pr_signal, %{})
    review = Map.get(summary, :review_signal) || %{}
    outcome = delivery && delivery.outcome
    track = board_track(summary, pr, outcome)
    {stage, entered_at, source} = board_stage(work_package, pr, review, delivery)

    %{
      stage: stage,
      entered_at: stage_timestamp(entered_at),
      source: source,
      track: track,
      outcome: outcome,
      delivered: if(outcome, do: outcome in ["pr_merged", "completed_no_pr"], else: pr[:status] == "merged")
    }
  end

  defp board_track(_summary, _pr, "completed_no_pr"), do: "no_pr"
  defp board_track(_summary, _pr, "pr_merged"), do: "pr"

  defp board_track(summary, pr, _outcome) do
    if summary[:merge_required] == true or is_integer(pr[:number]) or is_binary(pr[:url]), do: "pr", else: "no_pr"
  end

  defp board_stage(_package, _pr, _review, %{outcome: "pr_merged"} = delivery),
    do: {"done", delivery.pr_merged_at, "recorded_delivery"}

  defp board_stage(_package, _pr, _review, %{outcome: "completed_no_pr"} = delivery),
    do: {"done", delivery.recorded_at, "recorded_delivery"}

  defp board_stage(_package, _pr, _review, %{outcome: "finished"} = delivery),
    do: {"done", delivery.recorded_at, "recorded_delivery"}

  defp board_stage(_package, _pr, _review, %{outcome: "legacy", legacy_status: legacy_status} = delivery) when legacy_status in ["merged", "closed"],
    do: {"done", delivery.recorded_at, "recorded_delivery"}

  defp board_stage(_package, _pr, _review, %{outcome: _outcome}), do: {nil, nil, "recorded_delivery"}

  defp board_stage(%{status: "ended"}, _pr, _review, _delivery), do: {nil, nil, "recorded_status"}

  defp board_stage(_package, %{status: "merged"} = pr, _review, _delivery),
    do: {"done", pr[:merged_at], pr[:source] || "recorded_pr"}

  defp board_stage(_package, _pr, %{status: "in_progress"} = review, _delivery),
    do: {"review", review[:round_started_at] || review[:started_at], "provider"}

  defp board_stage(%{status: "ready"}, _pr, _review, _delivery), do: {"merge", nil, "recorded_status"}

  defp board_stage(package, pr, _review, _delivery) do
    cond do
      pr[:status] == "open" and pr[:head_matches] != false ->
        {"checks", nil, pr[:source] || "recorded_pr"}

      package.dispatched_at ->
        {"build", package.dispatched_at, "dispatched"}

      package.status == "dispatched" ->
        {"build", nil, "recorded_status"}

      true ->
        {"queued", package.inserted_at, "created"}
    end
  end

  defp stage_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp stage_timestamp(value), do: Sanitizer.timestamp(value)

  defp review_observation_state(nil), do: "unknown"
  defp review_observation_state(%{"status" => "not_started"}), do: "current"

  defp review_observation_state(observation) do
    if map_value(observation, "provider_status") in ["stale", "invalidated", "head_changed_after_review"], do: "stale", else: "current"
  end

  @doc """
  The package's worker terminal as the Observer recorded it: its address,
  whether it is live or finished, and its working/idle state from the
  factory's core.
  """
  @spec worker_terminal(WorkedOn.t() | nil) :: map() | nil
  def worker_terminal(nil), do: nil

  def worker_terminal(%WorkedOn{} = row) do
    status =
      case {row.state, Terminal.split_key(row.terminal_key)} do
        {"live", {core_id, address}} -> HerdrCore.status_state(core_id, address)
        {"live", :error} -> "unknown"
        {state, _key} -> state
      end

    %{address: row.display_address, state: row.state, status: status}
  end

  @spec activity(WorkPackage.t(), map(), map(), [map()]) :: map()
  def activity(work_package, summary, operational_state, events) do
    worker = map_value(summary, "worker_signal") || %{}
    review = map_value(summary, "review_signal") || %{}
    runtime = map_value(summary, "runtime_state") || %{}
    stage = activity_stage(work_package, operational_state, review)
    latest_event = List.last(events)
    started_at = review_started_at(stage, review)
    {waiting_reason, next_actor, next_action} = next_activity(work_package, summary, review, worker)

    %{
      work_package_id: work_package.id,
      accountable_owner: accountable_owner(work_package.owner_id),
      current_actor: runtime[:current_actor],
      stage: stage,
      started_at: started_at,
      elapsed_seconds: elapsed_seconds(started_at),
      waiting_reason: waiting_reason,
      next_actor: next_actor,
      next_action: next_action,
      last_update_at: latest_timestamp([work_package.updated_at, map_value(latest_event, "created_at"), worker[:last_activity]]),
      last_update: latest_event |> map_value("summary") |> bounded_string(),
      observation_state: observation_state(runtime, work_package),
      observed_at: review[:observed_at]
    }
    |> reject_nil_values()
    |> Sanitizer.redacted_json()
  end

  defp accountable_owner(nil), do: nil
  defp accountable_owner(id), do: %{id: id, source: "work_package"}

  defp activity_stage(%{status: status}, _operational_state, %{status: "in_progress"}) when status != "ended", do: "reviewing"
  defp activity_stage(%{status: "ready"}, _operational_state, _review), do: "ready"

  defp activity_stage(_work_package, operational_state, _review), do: operational_state.key

  defp review_started_at("reviewing", review), do: review[:round_started_at] || review[:started_at]
  defp review_started_at(_stage, _review), do: nil

  defp elapsed_seconds(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)
      _invalid -> nil
    end
  end

  defp elapsed_seconds(_value), do: nil

  defp latest_timestamp(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&Sanitizer.timestamp_sort_value/1, fn -> nil end)
    |> Sanitizer.timestamp()
  end

  defp next_activity(%{status: "ended"}, _summary, _review, _worker), do: {nil, nil, nil}

  defp next_activity(work_package, summary, review, worker) do
    dependency = map_value(summary, "dependency_signal") || %{}
    eligibility = Map.get(summary, :merge_eligibility, %{})
    unmet = Map.get(dependency, :unmet_work_package_ids, [])
    checks_failing? = get_in(summary, [:pr_signal, :checks, :status]) == "failing"

    terminal = Map.get(summary, :worker_terminal)

    facts = %{
      dependencies_met?: unmet == [],
      stacked_on: Map.get(summary, :stacked_on, []),
      progress: progress(summary),
      attention?: checks_failing? or review[:status] in ["inspection_needed", "failed"],
      # A worker that is idle or has exited can't act on failing CI or findings.
      worker_idle?: match?(%{status: "idle"}, terminal) or match?(%{state: "finished"}, terminal)
    }

    %{action: action, actor: actor} = Lifecycle.next_action(work_package, facts)
    # Merge eligibility adds dependency reasons on top of ready.
    action = if Lifecycle.ready?(work_package) and not facts.attention? and is_binary(eligibility[:next_action]), do: eligibility[:next_action], else: action

    {waiting_reason(work_package, summary, review, worker, eligibility, unmet, checks_failing?), actor, action}
  end

  @doc """
  Derived progress inside `dispatched`, from what the Observer saw: an open PR
  means review and CI are running; otherwise the worker terminal is working
  (`implementing`), has finished without a PR (`worker_exited`), or hasn't
  been seen yet (`launching`). Workers on machines the factory's core can't
  see stay `launching` until their PR appears.
  """
  @spec progress(map()) :: String.t()
  def progress(summary) do
    cond do
      get_in(summary, [:pr_signal, :status]) == "open" -> "review_ci"
      match?(%{state: "live"}, Map.get(summary, :worker_terminal)) -> "implementing"
      match?(%{state: "finished"}, Map.get(summary, :worker_terminal)) -> "worker_exited"
      true -> "launching"
    end
  end

  defp waiting_reason(work_package, summary, review, worker, eligibility, unmet, checks_failing?) do
    cond do
      reason = Enum.find(Map.get(eligibility, :reason_codes, []), &(&1 != "not_ready")) -> reason
      unmet != [] -> "unmet_dependencies"
      Map.get(summary, :stacked_on, []) != [] -> "stacked_on_unmerged_work"
      get_in(summary, [:blocker_state, :active?]) -> "active_blocker"
      checks_failing? -> "validation_failed"
      Lifecycle.dispatched?(work_package) and progress(summary) == "worker_exited" -> "worker_exited"
      true -> runtime_waiting_reason(work_package, review, worker)
    end
  end

  defp runtime_waiting_reason(work_package, review, worker) do
    cond do
      worker[:status] == "stale" -> "runtime_stale"
      review[:status] == "failed" -> "review_findings"
      review[:status] == "inspection_needed" -> "review_head_changed"
      review[:next_action] == "wait" -> "review_in_progress"
      Lifecycle.ready?(work_package) -> "awaiting_integration"
      true -> nil
    end
  end

  defp observation_state(%{stale?: true}, _package), do: "stale"
  defp observation_state(%{active_agent_run_ids: [_ | _]}, _package), do: "current"
  defp observation_state(%{current_actor: actor}, _package) when is_map(actor), do: "current"

  defp observation_state(_runtime, %{status: "planned"}) do
    "queued"
  end

  defp observation_state(_runtime, _package), do: "unknown"

  @spec dependency_context(map()) :: map()
  def dependency_context(execution_graphs) when is_map(execution_graphs) do
    effective_edges =
      execution_graphs
      |> Map.values()
      |> Enum.flat_map(&(map_value(&1, "effective_edges") |> List.wrap()))

    unmet_dependencies =
      execution_graphs
      |> Map.values()
      |> Enum.flat_map(&(map_value(&1, "unmet_dependencies") |> List.wrap()))

    %{
      incoming_by_work_package_id:
        effective_edges
        |> Enum.group_by(&map_value(&1, "dependent_work_package_id"))
        |> Map.new(fn {work_package_id, edges} ->
          incoming_ids =
            edges
            |> Enum.map(&map_value(&1, "prerequisite_work_package_id"))
            |> Enum.filter(&filled_string?/1)
            |> Enum.uniq()
            |> Enum.sort()

          {work_package_id, incoming_ids}
        end),
      unmet_by_work_package_id:
        unmet_dependencies
        |> Map.new(fn dependency ->
          {map_value(dependency, "work_package_id"), dependency |> map_value("prerequisite_work_package_ids") |> List.wrap() |> MapSet.new()}
        end)
    }
  end

  @spec dependency(WorkPackage.t(), map()) :: map() | nil
  def dependency(%WorkPackage{} = work_package, context) do
    dependency_indexes =
      Map.get(context, :dependency_indexes) ||
        context
        |> Map.get(:execution_graphs, %{})
        |> dependency_context()

    incoming_ids =
      dependency_indexes
      |> Map.get(:incoming_by_work_package_id, %{})
      |> Map.get(work_package.id, [])

    unmet_ids =
      dependency_indexes
      |> Map.get(:unmet_by_work_package_id, %{})
      |> Map.get(work_package.id, MapSet.new())

    if incoming_ids == [] do
      nil
    else
      inputs =
        Enum.map(incoming_ids, fn prerequisite_id ->
          %{
            work_package_id: prerequisite_id,
            status: dependency_input_status(prerequisite_id, unmet_ids, context)
          }
        end)

      %{
        satisfied: Enum.count(inputs, &(&1.status == "satisfied")),
        required: length(inputs),
        active: Enum.count(inputs, &(&1.status == "active")),
        blocked: Enum.count(inputs, &(&1.status == "blocked")),
        unmet_work_package_ids:
          inputs
          |> Enum.reject(&(&1.status == "satisfied"))
          |> Enum.map(& &1.work_package_id),
        inputs: inputs
      }
    end
  end

  defp scope_execution_graph(graph, work_packages, opts) do
    case Keyword.get(opts, :visible_work_package_ids, :all) do
      visible_ids when is_list(visible_ids) ->
        visible_ids = MapSet.new(visible_ids)

        work_packages
        |> Enum.map(& &1.id)
        |> Enum.filter(&MapSet.member?(visible_ids, &1))
        |> then(&ExecutionGraph.scope(graph, &1))

      _all ->
        graph
    end
  end

  defp pr_status(pr) do
    cond do
      PullRequestProgress.merged?(pr) -> "merged"
      filled_string?(map_value(pr, "url")) or is_integer(first_map_value(pr, ["number", "pr_number"])) -> "open"
      true -> "unavailable"
    end
  end

  defp override_pr_status(signal, %{outcome: "pr_merged"}), do: %{signal | status: "merged"}
  defp override_pr_status(signal, _delivery), do: signal

  defp checks(nil, _changed_at, _failing), do: nil
  defp checks(value, _changed_at, _failing) when not is_map(value), do: %{status: "unavailable"}

  defp checks(value, changed_at, failing) do
    %{
      status: value |> first_map_value(["conclusion", "state", "status"]) |> PullRequestProgress.check_status(),
      current: integer_value(first_map_value(value, ["current", "completed", "completed_count"])),
      total: integer_value(first_map_value(value, ["total", "total_count", "check_count"])),
      failing: failing,
      changed_at: changed_at
    }
    |> reject_nil_values()
  end

  # The Observer's detail read of failing check names, for the recorded head.
  defp failing_checks(%{"head_sha" => head, "ci" => %{"failing" => [_ | _] = names}}, head), do: Enum.map(names, &bounded_string/1)
  defp failing_checks(_observed, _head), do: nil

  # The Review Suite GitHub step's receipt: a Codex review of the current head.
  # It is shown only; it never stands in for the local review.
  defp github_review(%{"github_review" => %{"commit" => head, "state" => state}}, head) when is_binary(head), do: bounded_string(state)
  defp github_review(_observed, _head), do: nil

  defp dependency_input_status(work_package_id, unmet_ids, context) do
    activity = get_in(context, [:activity_contexts, work_package_id]) || WorkPackageActivity.empty_context()

    cond do
      not MapSet.member?(unmet_ids, work_package_id) -> "satisfied"
      get_in(activity, [:blocker_state, :active?]) == true -> "blocked"
      get_in(activity, [:runtime_state, :active?]) == true -> "active"
      true -> "waiting"
    end
  end

  defp signal_value(maps, keys) do
    Enum.find_value(maps, fn
      %{} = map -> first_map_value(map, keys)
      _value -> nil
    end)
  end

  defp bounded_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @string_limit)
    end
  end

  defp bounded_string(_value), do: nil
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp first_map_value(map, keys), do: Enum.find_value(keys, &map_value(map, &1))

  defp map_value(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_map_value(map, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    _error in ArgumentError -> nil
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp missing_product_tree_schema_error?(error) do
    error
    |> Exception.message()
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
