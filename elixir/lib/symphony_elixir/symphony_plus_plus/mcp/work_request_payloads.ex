defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestPayloads do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Asks
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.OperatorReport
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @type dashboard_error :: term()

  @spec worker_context(repo(), WorkPackage.t(), WorkPackage.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def worker_context(_repo, %WorkPackage{work_request_id: work_request_id}, _work_package) when work_request_id in [nil, ""] do
    {:ok, worker_completion()}
  end

  def worker_context(repo, %WorkPackage{} = context_anchor, %WorkPackage{} = work_package) do
    with {:ok, work_request} <- WorkRequestService.get(repo, context_anchor.work_request_id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request.id),
         {:ok, tree} <- ProductTree.tree_for_work_request(repo, work_request.id),
         {:ok, execution_graph} <- ProductTree.ExecutionGraph.evaluate(repo, work_request.id, work_packages),
         {:ok, selected_decisions} <-
           selected_worker_decisions(
             repo,
             work_request.id,
             execution_graph.effective_edges,
             tree.dependency_edges,
             context_anchor,
             work_package
           ) do
      packages_by_id = Map.new(work_packages, &{&1.id, &1})

      direct_dependencies =
        execution_graph.effective_edges
        |> Enum.filter(&(&1.dependent_work_package_id == context_anchor.id))
        |> Enum.map(& &1.prerequisite_work_package_id)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&Map.fetch!(packages_by_id, &1))
        |> Enum.map(&worker_dependency/1)

      {:ok,
       worker_completion()
       |> Map.put("parent_work_request", %{
         "id" => work_request.id,
         "title" => Redactor.redact_text(work_request.title),
         "goal" => Redactor.redact_text(work_request.human_description)
       })
       |> Map.put("direct_dependencies", direct_dependencies)
       |> Map.put("dependency_selections", Enum.filter(execution_graph.effective_edges, &(&1.dependent_work_package_id == context_anchor.id)))
       |> Map.put("selected_decisions", selected_decisions)}
    end
  end

  defp selected_worker_decisions(repo, work_request_id, effective_edges, dependency_edges, context_anchor, work_package) do
    dependency_ids =
      effective_edges
      |> Enum.filter(&(&1.dependent_work_package_id == context_anchor.id))
      |> Enum.flat_map(& &1.dependency_ids)
      |> MapSet.new()

    dependency_decision_ids =
      dependency_edges
      |> Enum.filter(&MapSet.member?(dependency_ids, &1.id))
      |> Enum.map(&get_in(&1.decision_ref || %{}, ["id"]))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    with {:ok, decisions} <- WorkRequestService.list_decisions(repo, work_request_id) do
      selected =
        Enum.filter(decisions, fn decision ->
          MapSet.member?(dependency_decision_ids, decision.id) or
            work_package_references_decision?(work_package, decision.id)
        end)

      {:ok, Enum.map(selected, &worker_decision/1)}
    end
  end

  defp work_package_references_decision?(%WorkPackage{} = work_package, decision_id) do
    [
      work_package.title,
      work_package.goal,
      work_package.product_description,
      work_package.engineering_scope,
      work_package.acceptance_criteria,
      work_package.validation_steps,
      work_package.stop_conditions,
      work_package.review_requirement
    ]
    |> Redactor.redact_output()
    |> Enum.any?(&contains_decision_reference?(&1, decision_id))
  end

  defp contains_decision_reference?(value, decision_id) when is_binary(value) do
    Regex.match?(~r/(?:^|[^A-Za-z0-9_-])#{Regex.escape(decision_id)}(?:$|[^A-Za-z0-9_-])/, value)
  end

  defp contains_decision_reference?(value, decision_id) when is_list(value),
    do: Enum.any?(value, &contains_decision_reference?(&1, decision_id))

  defp contains_decision_reference?(value, decision_id) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&contains_decision_reference?(&1, decision_id))

  defp contains_decision_reference?(_value, _decision_id), do: false

  defp worker_decision(%DecisionLogEntry{} = decision) do
    %{
      "id" => decision.id,
      "decision" => Redactor.redact_text(decision.decision),
      "rationale" => Redactor.redact_text(decision.rationale),
      "scope_impact" => Redactor.redact_text(decision.scope_impact)
    }
  end

  @spec work_request_cards(repo(), [WorkRequest.t()]) :: {:ok, [map()]} | {:error, term()}
  def work_request_cards(repo, work_requests) do
    with {:ok, summaries} <- Phase.load(repo, work_requests) do
      open_asks = Asks.open_counts(repo, Enum.map(work_requests, & &1.id))

      {:ok,
       Enum.map(work_requests, fn work_request ->
         work_request
         |> work_request_card()
         |> put_phase(Map.fetch!(summaries, work_request.id))
         |> optional_put("open_asks", open_asks[work_request.id])
       end)}
    end
  end

  @doc "Adds the WorkRequest's derived phase, and the operator's next action when there is one."
  @spec put_phase(map(), Phase.summary()) :: map()
  def put_phase(payload, %{phase: phase}) do
    payload
    |> Map.put("phase", phase)
    |> optional_put("next_action", Phase.next_action(phase))
  end

  @spec put_phase(map(), repo(), WorkRequest.t()) :: {:ok, map()} | {:error, term()}
  def put_phase(payload, repo, %WorkRequest{} = work_request) do
    with {:ok, summary} <- Phase.load_one(repo, work_request) do
      {:ok, put_phase(payload, summary)}
    end
  end

  defp optional_put(map, _key, nil), do: map
  defp optional_put(map, key, value), do: Map.put(map, key, value)

  @spec work_request_card(WorkRequest.t()) :: map()
  def work_request_card(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator(work_request),
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
    |> Dashboard.put_attribution("dispatched_by", work_request.dispatched_by)
  end

  @spec work_request_filter(nil | binary()) :: map()
  def work_request_filter(nil), do: %{}
  def work_request_filter(phase), do: %{"phase" => phase}

  @spec work_request_detail(repo(), WorkRequest.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, %WorkRequest{} = work_request, _opts) do
    asks = Map.get(Asks.by_work_request(repo, [work_request.id]), work_request.id, [])

    with {:ok, decisions} <- WorkRequestService.list_decisions(repo, work_request.id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request.id),
         {:ok, slice_visibility} <- DeliveryBoard.work_package_visibility(repo, work_request.id, work_packages),
         {:ok, operator_reports} <- OperatorReport.load_many(repo, [work_request]),
         {:ok, work_request_payload} <- put_phase(work_request(work_request), repo, work_request) do
      visible_work_packages = Map.fetch!(slice_visibility, :visible_work_packages)

      {:ok,
       %{
         "work_request" => Map.put(work_request_payload, "operator_report", Map.fetch!(operator_reports, work_request.id)),
         "asks" => Enum.map(asks, &Asks.public/1),
         "decision_log_entries" => Enum.map(decisions, &decision_log_entry/1),
         "work_packages" => Enum.map(visible_work_packages, &work_package/1),
         "summary" => work_request_summary(asks, decisions, visible_work_packages)
       }}
    end
  end

  @spec work_request_read(repo(), WorkRequest.t(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_read(repo, work_request, "full"), do: work_request_detail(repo, work_request, [])

  def work_request_read(repo, work_request, "summary") do
    with {:ok, payload} <- work_request_detail(repo, work_request, []),
         {:ok, board} <- DeliveryBoard.project(repo, work_request.id) do
      decisions = payload["decision_log_entries"]
      asks = payload["asks"]

      {:ok,
       %{
         "work_request" => Map.take(payload["work_request"], ~w(id title repo base_branch phase next_action human_description constraints operator_report)),
         "asks" => Enum.filter(asks, &(&1["state"] == "open")),
         "decision_log_entries" => decisions |> Enum.take(-5) |> Enum.map(&Map.take(&1, ~w(id sequence decision))) |> Enum.map(&Map.update!(&1, "decision", fn text -> one_line(text, 160) end)),
         "work_packages" => board |> delivery_board() |> Map.fetch!("work_packages") |> Enum.map(&work_package_read_summary/1),
         "summary" => payload["summary"],
         "omitted" => %{
           "package_contracts" => length(payload["work_packages"]),
           "resolved_asks" => Enum.count(asks, &(&1["state"] != "open")),
           "older_decisions" => max(length(decisions) - 5, 0),
           "decision_details" => length(decisions)
         },
         "help" => "Use read_work_request with detail: full for all contracts, asks and decisions; view: plan for dependencies."
       }}
    end
  end

  @doc """
  One package of a WorkRequest: its contract, group path, revision, status,
  next action, what it depends on and what depends on it. Summary keeps the
  contract to title and goal; full adds the whole contract and board state.
  """
  @spec work_package_read(repo(), WorkRequest.t(), WorkPackage.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def work_package_read(repo, %WorkRequest{} = work_request, %WorkPackage{} = package, detail) do
    with {:ok, work_request_payload} <- put_phase(work_request(work_request), repo, work_request),
         {:ok, board} <- DeliveryBoard.project(repo, work_request.id),
         {:ok, graph} <- ProductTree.execution_graph(repo, work_request.id) do
      row = board |> delivery_board() |> Map.fetch!("work_packages") |> Enum.find(%{}, &(&1["id"] == package.id))

      read =
        if row == %{},
          do: %{"next_action" => Lifecycle.next_action(package).action || "none"},
          else: work_package_read_summary(row)

      contract =
        if detail == "full",
          do: package |> work_package() |> Map.merge(plan_operational_work_package_fields(row)),
          else: %{"id" => package.id, "title" => Redactor.redact_text(package.title), "goal" => Redactor.redact_text(package.goal)}

      {:ok,
       %{
         "work_request" => Map.take(work_request_payload, ~w(id title phase next_action)),
         "work_package" =>
           contract
           |> Map.merge(%{"group" => Redactor.redact_text(package.group), "status" => package.status, "revision" => package.contract_revision})
           |> Map.merge(Map.take(read, ["next_action", "pr_url"]))
           |> Map.merge(%{
             "depends_on" => for(edge <- graph.effective_edges, edge.dependent_work_package_id == package.id, do: edge.prerequisite_work_package_id),
             "dependents" => for(edge <- graph.effective_edges, edge.prerequisite_work_package_id == package.id, do: edge.dependent_work_package_id)
           })
       }}
    end
  end

  defp work_package_read_summary(package) do
    activity = get_in(package, ["operational_state", "activity_signal"]) || %{}
    state = get_in(package, ["operational_state", "key"])

    %{
      "id" => package["id"],
      "title" => package["title"],
      "status" => package["raw_status"],
      "pr_url" => get_in(package, ["work_package", "pr", "url"]) || get_in(package, ["delivery", "pr_url"]),
      "next_action" => activity["next_action"] || package_next_action(state, package["raw_status"])
    }
  end

  # A merged PR the Observer could not record as delivered (its evidence is
  # incomplete or doesn't match the package) needs the architect.
  defp package_next_action("needs_closeout", _status), do: "sync_pr"
  defp package_next_action(_state, status), do: Lifecycle.next_action(status).action || "none"

  @spec plan_summary(map()) :: map()
  def plan_summary(payload) do
    plan = Map.update!(payload["plan"], "work_packages", &Enum.map(&1, fn package -> plan_package_summary(package) end))

    payload
    |> Map.put("work_request", Map.take(payload["work_request"], ~w(id title phase next_action)))
    |> Map.put("plan", plan)
    |> Map.put("omitted", %{"package_details" => length(plan["work_packages"])})
    |> Map.put("help", "Use read_work_request with view: plan and detail: full for complete package contracts.")
  end

  defp plan_package_summary(package) do
    package
    |> Map.take(~w(id title group sequence status attention_reason_codes))
    |> Map.put("state", get_in(package, ["operational_state", "key"]))
  end

  defp one_line(text, limit) do
    text = text |> String.split() |> Enum.join(" ")
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end

  @doc """
  The plan of a WorkRequest: its visible packages with their group paths and
  operational state, dependency intents and the effective execution graph.
  """
  @spec work_request_plan(repo(), WorkRequest.t(), [WorkPackage.t()], map()) :: {:ok, map()} | {:error, term()}
  def work_request_plan(repo, %WorkRequest{} = work_request, work_packages, delivery_board) do
    projection_work_package_payloads =
      delivery_board
      |> Map.fetch!(:work_packages)
      |> json_safe_payload()
      |> Enum.filter(&is_binary(get_in(&1, ["operational_state", "work_package_status"])))

    visible_work_packages = visible_work_packages_from_projection(work_packages, projection_work_package_payloads)

    plan =
      repo
      |> ProductTree.project(work_request.id, projection_work_package_payloads, visible_only?: true)
      |> public_plan()
      |> Map.put("work_packages", plan_work_package_payloads(visible_work_packages, projection_work_package_payloads))

    with {:ok, work_request_payload} <- put_phase(work_request(work_request), repo, work_request) do
      {:ok, %{"work_request" => work_request_payload, "plan" => plan}}
    end
  end

  @spec work_request(WorkRequest.t()) :: map()
  def work_request(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "human_description" => Redactor.redact_text(work_request.human_description),
      "constraints" => Redactor.redact_output(work_request.constraints || %{}),
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator(work_request),
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
    |> Dashboard.put_attribution("dispatched_by", work_request.dispatched_by)
  end

  @spec redacted_work_request_scope(WorkRequest.t()) :: map()
  def redacted_work_request_scope(%WorkRequest{} = work_request) do
    %{
      "repo" => Redactor.redact_text(work_request.repo),
      "base_branch" => Redactor.redact_text(work_request.base_branch)
    }
  end

  @spec work_request_mutation(WorkRequest.t()) :: map()
  def work_request_mutation(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  @spec decision_log_entry(DecisionLogEntry.t()) :: map()
  def decision_log_entry(%DecisionLogEntry{} = decision) do
    %{
      "id" => decision.id,
      "work_request_id" => decision.work_request_id,
      "sequence" => decision.sequence,
      "source_type" => Redactor.redact_text(decision.source_type),
      "source_id" => Redactor.redact_text(decision.source_id),
      "decision" => Redactor.redact_text(decision.decision),
      "rationale" => Redactor.redact_text(decision.rationale),
      "scope_impact" => Redactor.redact_text(decision.scope_impact),
      "created_by" => Redactor.redact_text(decision.created_by),
      "created_at" => timestamp(decision.created_at),
      "inserted_at" => timestamp(decision.inserted_at),
      "updated_at" => timestamp(decision.updated_at)
    }
  end

  @spec work_package(WorkPackage.t()) :: map()
  def work_package(%WorkPackage{} = work_package) do
    %{
      "id" => work_package.id,
      "work_request_id" => work_package.work_request_id,
      "group" => Redactor.redact_text(work_package.group),
      "sequence" => work_package.sequence,
      "title" => Redactor.redact_text(work_package.title),
      "goal" => Redactor.redact_text(work_package.goal),
      "kind" => work_package.kind,
      "repo" => Redactor.redact_text(work_package.repo),
      "base_branch" => Redactor.redact_text(work_package.base_branch),
      "branch_pattern" => Redactor.redact_text(work_package.branch_pattern),
      "allowed_file_globs" => Enum.map(work_package.allowed_file_globs || [], &Redactor.redact_text/1),
      "forbidden_file_globs" => Enum.map(work_package.forbidden_file_globs || [], &Redactor.redact_text/1),
      "acceptance_criteria" => Enum.map(work_package.acceptance_criteria || [], &Redactor.redact_text/1),
      "validation_steps" => Enum.map(work_package.validation_steps || [], &Redactor.redact_text/1),
      "review" => Redactor.redact_output(work_package.review_requirement),
      "stop_conditions" => Enum.map(work_package.stop_conditions || [], &Redactor.redact_text/1),
      "status" => work_package.status,
      "contract_revision" => work_package.contract_revision,
      "dispatched_at" => timestamp(work_package.dispatched_at),
      "inserted_at" => timestamp(work_package.inserted_at),
      "updated_at" => timestamp(work_package.updated_at)
    }
    |> Dashboard.put_attribution("dispatched_by", work_package.dispatched_by)
  end

  @spec public_plan(map()) :: map()
  def public_plan(projection) when is_map(projection) do
    projection = json_safe_payload(projection)

    projection
    |> Map.put("dependencies", public_dependencies(Map.get(projection, "dependency_edges", [])))
    |> Map.drop(["dependency_edges", "memberships"])
  end

  @spec work_package_delivery(WorkPackageDelivery.t()) :: map()
  def work_package_delivery(%WorkPackageDelivery{} = delivery) do
    %{
      "id" => delivery.id,
      "work_request_id" => delivery.work_request_id,
      "work_package_id" => delivery.work_package_id,
      "outcome" => delivery.outcome,
      "idempotency_key" => Redactor.redact_text(delivery.idempotency_key),
      "recorded_by" => Redactor.redact_text(delivery.recorded_by),
      "recorded_at" => timestamp(delivery.recorded_at),
      "pr_url" => Redactor.redact_text(delivery.pr_url),
      "pr_number" => delivery.pr_number,
      "pr_repository" => Redactor.redact_text(delivery.pr_repository),
      "pr_merged_at" => timestamp(delivery.pr_merged_at),
      "merge_commit_sha" => Redactor.redact_text(delivery.merge_commit_sha),
      "no_pr_evidence" => Redactor.redact_text(delivery.no_pr_evidence),
      "successor_work_package_id" => delivery.successor_work_package_id,
      "superseded_reason" => Redactor.redact_text(delivery.superseded_reason),
      "abandoned_rationale" => Redactor.redact_text(delivery.abandoned_rationale),
      "inserted_at" => timestamp(delivery.inserted_at),
      "updated_at" => timestamp(delivery.updated_at)
    }
  end

  @spec delivery_board(map()) :: map()
  def delivery_board(delivery_board) do
    delivery_board
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  @spec delivery_board(map(), String.t()) :: map()
  def delivery_board(board, "full"), do: delivery_board(board)

  def delivery_board(board, "summary") do
    board
    |> delivery_board()
    |> Map.update!("work_packages", fn work_packages ->
      Enum.map(work_packages, fn work_package ->
        work_package
        |> Map.take(["id", "title", "raw_status", "delivery_outcome", "attention_reason_codes", "merge_eligibility"])
        |> Map.put("state", get_in(work_package, ["operational_state", "key"]))
        |> Map.put("pr_url", get_in(work_package, ["work_package", "pr", "url"]) || get_in(work_package, ["delivery", "pr_url"]))
      end)
    end)
  end

  defp visible_work_packages_from_projection(work_packages, projection_work_package_payloads) do
    visible_work_package_ids =
      projection_work_package_payloads
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(work_packages, &MapSet.member?(visible_work_package_ids, &1.id))
  end

  defp plan_work_package_payloads(visible_work_packages, projection_work_package_payloads) do
    projection_work_package_payloads_by_id = Map.new(projection_work_package_payloads, &{map_get(&1, :id), &1})

    Enum.map(visible_work_packages, fn %WorkPackage{} = work_package ->
      work_package
      |> work_package()
      |> Map.merge(plan_operational_work_package_fields(Map.get(projection_work_package_payloads_by_id, work_package.id, %{})))
    end)
  end

  defp plan_operational_work_package_fields(projection_work_package_payload) when is_map(projection_work_package_payload) do
    projection_work_package_payload
    |> Map.take(["raw_status", "delivery_outcome", "operational_state", "attention_reason_codes"])
    |> Map.put("status", map_get(projection_work_package_payload, :raw_status))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp work_request_creator(%WorkRequest{} = work_request) do
    %{
      "kind" => work_request.creator_kind,
      "name" => Redactor.redact_text(work_request.creator_name),
      "via" => work_request.created_via
    }
  end

  defp work_request_summary(asks, decisions, work_packages) do
    %{
      "open_ask_count" => Enum.count(asks, &(&1.state == "open")),
      "decision_count" => length(decisions),
      "work_package_count" => length(work_packages),
      "planned_work_package_count" => Enum.count(work_packages, &(&1.status == "planned")),
      "dispatched_work_package_count" => Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
      "ended_work_package_count" => Enum.count(work_packages, &Lifecycle.ended?/1)
    }
  end

  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_get(_value, _key), do: nil

  defp worker_completion do
    %{"completion" => %{"next_owner" => "architect", "next_action" => "return_pr_or_evidence"}}
  end

  defp worker_dependency(%WorkPackage{} = work_package) do
    %{
      "id" => work_package.id,
      "title" => Redactor.redact_text(work_package.title),
      "status" => work_package.status
    }
  end

  # "from" depends on "to". Older ledgers may store the same dependency as
  # "to blocks from".
  defp public_dependencies(edges) do
    edges
    |> Enum.filter(&(Map.get(&1, "kind") in ["depends_on", "blocks"]))
    |> Enum.map(fn edge ->
      {from, to} = dependency_pair(Map.get(edge, "kind"), get_in(edge, ["source", "id"]), get_in(edge, ["target", "id"]))

      edge
      |> Map.take(["id", "reason", "candidate_head_sha", "created_by", "created_at"])
      |> Map.merge(%{"from" => from, "to" => to})
    end)
  end

  defp dependency_pair("blocks", source, target), do: {target, source}
  defp dependency_pair(_kind, source, target), do: {source, target}

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
