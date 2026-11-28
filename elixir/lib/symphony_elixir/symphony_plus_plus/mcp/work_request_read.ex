defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestRead do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments, only: [optional_string_argument: 2, required_argument: 2]

  alias SymphonyElixir.SymphonyPlusPlus.{Asks, Ownership, ProductTree}
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{ToolCatalog, WorkRequestPayloads, WorkRequestReadPage, WorkRequestScope}
  alias SymphonyElixir.SymphonyPlusPlus.Observer.ReviewRefresh
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, DeliveryBoard, OperatorReport, Phase}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService

  @views ToolCatalog.work_request_views()
  @live_views ~w(overview plan board)
  @overview_bytes 5_250
  @flagged_page_size 12
  @package_fields ~w(id title goal group status kind repo base_branch branch_pattern allowed_file_globs forbidden_file_globs acceptance_criteria validation_steps review stop_conditions)
  @package_row_fields ~w(id work_request_id sequence title group status contract_revision updated_at owner_id review_mode)a
  @delivery_fields ~w(work_request_id work_package_id outcome legacy_status successor_work_package_id recorded_at pr_merged_at)a

  @spec call(module(), map()) :: {:ok, map()} | {:error, term()} | {:tool_error, String.t()}
  def call(repo, arguments) do
    with {:ok, view} <- view(arguments),
         {:ok, id} <- required_argument(arguments, "work_request_id"),
         {:ok, cursor} <- optional_string_argument(arguments, "cursor"),
         {:ok, request} <- WorkRequestScope.scoped_work_request(repo, id) do
      read(repo, request, view, cursor, arguments)
    end
  rescue
    error in Exqlite.Error ->
      message = Exception.message(error)

      if String.contains?(String.downcase(message), ["busy", "locked"]),
        do: {:error, :database_busy},
        else: {:error, {:storage_failed, message}}
  end

  defp read(repo, request, view, cursor, _arguments) when view in @live_views do
    # The board needs fresh review evidence. An overview at intake would
    # otherwise cache an empty review scope until the next sweep.
    if view == "board" and is_nil(request.archived_at), do: ReviewRefresh.request(repo, {:request, request.id}, true)

    snapshot(repo, fn ->
      with {:ok, current} <- WorkRequestService.get(repo, request.id) do
        read_live(repo, current, view, cursor)
      end
    end)
  end

  defp read(repo, request, "flagged_decisions", cursor, _arguments), do: flagged_decisions(repo, request.id, cursor)

  defp read(repo, request, view, cursor, arguments) do
    with {:ok, payload, subject} <- snapshot(repo, fn -> document(repo, request, view, arguments) end) do
      WorkRequestReadPage.document(payload, {request.id, view, subject}, cursor)
    end
  end

  defp snapshot(repo, fun) do
    case repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp view(arguments) do
    case Map.get(arguments, "view", "overview") do
      view when view in @views -> {:ok, view}
      _other -> {:tool_error, "invalid_view"}
    end
  end

  defp read_live(repo, request, view, cursor) do
    packages = packages(repo, request.id)
    deliveries = deliveries(repo, request.id)
    {ended, live} = Enum.split_with(packages, &Lifecycle.ended?/1)

    with {:ok, phases} <- Phase.load(repo, [request], packages, repo, deliveries) do
      phase = Map.fetch!(phases, request.id).phase
      work_request = %{"id" => request.id, "phase" => phase} |> put_present("next_action", Phase.next_action(phase))
      payload = %{"work_request" => work_request, "ended" => ended_counts(ended, deliveries)}
      read_live_view(repo, request, view, payload, {packages, live, deliveries}, cursor)
    end
  end

  defp read_live_view(repo, request, "plan", payload, {packages, live, deliveries}, cursor) do
    plan(repo, request, payload, packages, live, deliveries, cursor)
  end

  defp read_live_view(repo, request, view, payload, {packages, live, deliveries}, cursor) do
    with {:ok, rows} <- live_board(repo, request, packages, live, deliveries) do
      case view do
        "overview" -> overview(repo, request, payload, rows, cursor)
        "board" -> board(request, payload, rows, cursor)
      end
    end
  end

  defp overview(repo, request, payload, rows, cursor) do
    asks =
      repo.all(
        from(ask in Ask,
          where: ask.work_request_id == ^request.id and ask.state == "open",
          order_by: [desc: ask.inserted_at, desc: ask.id],
          select: %{id: ask.id, question: ask.question}
        )
      )
      |> Enum.map(&%{"id" => &1.id, "question" => preview(&1.question, 100)})

    query = from(decision in DecisionLogEntry, where: decision.work_request_id == ^request.id)

    decisions =
      repo.all(
        from(decision in query,
          order_by: [desc: decision.flagged, desc: decision.sequence],
          limit: 3,
          select: struct(decision, [:id, :decision, :flagged, :review_state])
        )
      )

    report = report_preview(OperatorReport.public(request.report))
    phase = payload["work_request"]["phase"]
    request_blockers = OperatorReport.blockers(request.report)
    {action, actor} = request_action(phase, asks, request_blockers, rows)

    work_request =
      payload["work_request"]
      |> Map.merge(%{
        "title" => preview(request.title, 100),
        "repo" => preview(request.repo, 240),
        "next_action" => preview(action, 140)
      })
      |> put_present("next_actor", request_actor(repo, request.id, actor))
      |> put_present("operator_report", report)

    payload =
      Map.merge(payload, %{
        "work_request" => work_request,
        "work_packages" => Enum.map(rows, &overview_row(&1, phase)),
        "blockers" => blocker_rows(request_blockers, []),
        "asks" => asks,
        "decisions" => Enum.map(decisions, &headline/1),
        "older_decision_count" => repo.aggregate(query, :count, :id) - length(decisions)
      })

    WorkRequestReadPage.rows(payload, [~w(asks), ~w(blockers), ~w(work_packages)], {request.id, "overview"}, cursor, @overview_bytes)
  end

  defp plan(repo, request, payload, packages, live, deliveries, cursor) do
    with {:ok, tree} <- ProductTree.tree_for_work_request(repo, request.id),
         {:ok, successors} <- ExecutionGraph.successors(repo, packages) do
      graph = ExecutionGraph.evaluate(tree, packages, Map.values(deliveries), successors)
      live_ids = MapSet.new(live, & &1.id)
      reasons = Map.new(tree.dependency_edges, &{&1.id, &1.reason})

      dependencies =
        for edge <- graph.effective_edges, MapSet.member?(live_ids, edge.dependent_work_package_id) do
          prerequisite = edge.prerequisite_work_package_id
          delivery = deliveries[prerequisite]

          %{"from" => edge.dependent_work_package_id, "to" => prerequisite, "delivered" => edge.delivered}
          |> put_present("outcome", delivery && delivery.outcome)
          |> put_present("reason", Enum.find_value(edge.dependency_ids, &reasons[&1]) |> preview(120))
          |> put_waiting_for(Enum.map(edge.waiting_for, & &1.work_package_id))
        end

      plan =
        %{
          "work_packages" => Enum.map(live, &%{"id" => &1.id, "group" => clip(Redactor.redact_text(&1.group), 700), "revision" => &1.contract_revision, "status" => &1.status}),
          "dependencies" => dependencies
        }
        |> put_present("revision", tree.latest_revision && tree.latest_revision.revision_number)

      WorkRequestReadPage.rows(
        Map.put(payload, "plan", plan),
        [~w(plan work_packages), ~w(plan dependencies)],
        {request.id, "plan"},
        cursor
      )
    end
  end

  defp board(request, payload, rows, cursor) do
    phase = payload["work_request"]["phase"]
    recovery = if phase == "archived", do: %{}, else: recovery_actions(rows)
    board = %{"work_packages" => Enum.map(rows, &board_row(&1, phase)), "blockers" => blocker_rows(OperatorReport.blockers(request.report), rows), "recovery" => recovery}

    WorkRequestReadPage.rows(
      Map.put(payload, "delivery_board", board),
      [~w(delivery_board work_packages), ~w(delivery_board blockers)],
      {request.id, "board"},
      cursor
    )
  end

  defp blocker_rows(request_blockers, rows) do
    package_blockers =
      for row <- rows,
          blockers = get_in(row, [:work_package, :blockers]) || [],
          blocker <- Enum.sort_by(blockers, & &1.id),
          do: Map.put(blocker, :work_package_id, row.id)

    Enum.map(request_blockers ++ package_blockers, fn blocker ->
      blocker
      |> Map.take([:id, :target, :summary, :state, :unknown, :next_action, :hold, :work_package_id])
      |> Map.update(:summary, nil, &preview(&1, 140))
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)
    end)
  end

  defp document(_repo, request, "request", _arguments) do
    payload = request |> WorkRequestPayloads.work_request() |> Map.take(~w(id title repo base_branch work_type human_description constraints desired_dispatch_shape))
    {:ok, %{"work_request" => payload}, nil}
  end

  defp document(repo, request, "package", arguments) do
    with {:ok, package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, package} <- WorkRequestService.get_work_package(repo, request.id, package_id),
         {:ok, graph} <- ProductTree.execution_graph(repo, request.id, packages(repo, request.id)) do
      contract =
        package
        |> WorkRequestPayloads.work_package()
        |> Map.take(@package_fields)
        |> Map.merge(%{
          "revision" => package.contract_revision,
          "depends_on" => for(edge <- graph.effective_edges, edge.dependent_work_package_id == package.id, do: edge.prerequisite_work_package_id),
          "dependents" => for(edge <- graph.effective_edges, edge.prerequisite_work_package_id == package.id, do: edge.dependent_work_package_id)
        })

      {:ok, %{"work_package" => contract}, package_id}
    end
  end

  defp document(repo, request, "ask", arguments) do
    with {:ok, id} <- required_argument(arguments, "ask_id"),
         %Ask{} = ask <- repo.get_by(Ask, id: id, work_request_id: request.id) do
      {:ok, %{"ask" => Asks.public(ask)}, id}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp document(repo, request, "decision", arguments) do
    with {:ok, id} <- required_argument(arguments, "decision_id"),
         %DecisionLogEntry{} = decision <- repo.get_by(DecisionLogEntry, id: id, work_request_id: request.id) do
      {:ok, %{"decision" => WorkRequestPayloads.decision_log_entry(decision)}, id}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp flagged_decisions(repo, id, cursor) do
    scope = {id, "flagged_decisions"}

    with {:ok, before_sequence} <- WorkRequestReadPage.position(scope, cursor) do
      query = from(decision in DecisionLogEntry, where: decision.work_request_id == ^id and decision.flagged == true)

      query =
        if before_sequence > 0 do
          from(decision in query, where: decision.sequence < ^before_sequence)
        else
          query
        end

      {decisions, extra} =
        repo.all(
          from(decision in query,
            order_by: [desc: decision.sequence],
            limit: ^(@flagged_page_size + 1),
            select: struct(decision, [:id, :decision, :flagged, :review_state, :sequence])
          )
        )
        |> Enum.split(@flagged_page_size)

      payload = %{"work_request_id" => id, "decisions" => Enum.map(decisions, &headline/1)}
      next_cursor = if extra != [], do: WorkRequestReadPage.cursor(scope, List.last(decisions).sequence)
      payload = put_present(payload, "next_cursor", next_cursor)
      WorkRequestReadPage.document(payload, scope, nil)
    end
  end

  defp packages(repo, id) do
    repo.all(
      from(package in WorkPackage,
        where: package.work_request_id == ^id,
        order_by: [asc: package.sequence, asc: package.id],
        select: struct(package, @package_row_fields)
      )
    )
  end

  defp deliveries(repo, id) do
    repo.all(
      from(delivery in WorkPackageDelivery,
        where: delivery.work_request_id == ^id,
        select: struct(delivery, @delivery_fields)
      )
    )
    |> Map.new(&{&1.work_package_id, &1})
  end

  defp live_board(_repo, _request, _packages, [], _deliveries), do: {:ok, []}

  defp live_board(repo, request, packages, live, deliveries) do
    live_by_id = Map.new(live, &{&1.id, &1})

    # The builder still needs ended packages for dependency resolution. Only live
    # packages need their documents and progress loaded to derive actionable state.
    ended_contexts =
      for package <- packages, not Map.has_key?(live_by_id, package.id), into: %{} do
        {package.id, %{work_package: package, progress_events: []}}
      end

    with {:ok, board} <-
           DeliveryBoard.project(repo, request.id,
             work_request: request,
             work_packages: packages,
             visible_work_package_ids: Enum.map(packages, & &1.id),
             work_package_contexts: ended_contexts,
             deliveries_by_slice_id: Map.new(deliveries, fn {id, delivery} -> {{request.id, id}, delivery} end)
           ) do
      {:ok, for(row <- board.work_packages, package = live_by_id[row.id], do: Map.put(row, :review_mode, package.review_mode))}
    end
  end

  defp ended_counts(ended, deliveries) do
    Enum.frequencies_by(ended, fn package ->
      case deliveries[package.id] do
        %{outcome: outcome} -> outcome
        nil -> "unknown"
      end
    end)
  end

  defp request_action("archived", _asks, _report, _rows), do: {Phase.next_action("archived"), "operator"}
  defp request_action("done", _asks, _report, _rows), do: {"done", nil}
  defp request_action("unresolved", _asks, _report, _rows), do: {Phase.next_action("unresolved"), "operator"}
  defp request_action(_phase, [_ | _], _report, _rows), do: {"answer_ask", "operator"}

  defp request_action(phase, _asks, blockers, rows) do
    case Signals.blocker_action(blockers) do
      action when action in ["replan", "reclassify"] -> {action, "architect"}
      "wait" -> request_wait(blockers, rows)
      nil when phase == "intake" -> {"edit_plan", "architect"}
      nil -> Enum.find_value(rows, &actionable_package/1) || activity(List.first(rows))
    end
  end

  defp request_wait(blockers, rows) do
    prerequisites = for %{state: "waiting", target: %{"kind" => "work_package", "id" => id}} <- blockers, do: id
    Enum.find_value(rows, fn row -> if row.id in prerequisites, do: actionable_package(row) end) || {"wait", nil}
  end

  defp actionable_package(row) do
    case activity(row) do
      {action, actor} when action not in [nil, "wait"] -> {action, actor}
      _waiting -> nil
    end
  end

  defp request_actor(repo, id, "architect") do
    case Ownership.owner(repo, id) do
      %{display_address: address} -> address
      nil -> "architect"
    end
  end

  defp request_actor(_repo, _id, actor), do: actor

  defp report_preview(nil), do: nil

  defp report_preview(report) do
    for {field, key, max_bytes} <- [{"brief", "text", 320}, {"eta", "text", 100}, {"parking", "reason", 140}],
        entry = report[field],
        is_map(entry),
        into: %{} do
      {field, entry |> Map.drop(["targets"]) |> Map.replace_lazy(key, &preview(&1, max_bytes)) |> Map.replace_lazy("hold", &preview(&1, max_bytes))}
    end
  end

  defp headline(decision) do
    %{"id" => decision.id, "headline" => preview(decision.decision, 120)}
    |> put_present("review_state", if(decision.flagged, do: decision.review_state || "recorded"))
  end

  defp overview_row(row, phase) do
    {action, _actor} = activity(row, phase)
    stage = row.operational_state.activity_signal["stage"]

    %{"id" => row.id, "title" => preview(row.title, 70), "status" => row.raw_status, "next_action" => preview(action, 140)}
    |> put_present("stage", if(stage != row.raw_status, do: stage))
    |> put_present("pr_url", pr(row)[:url])
  end

  defp board_row(row, phase) do
    {action, actor} = activity(row, phase)
    signal = row.operational_state.activity_signal
    summary = row.work_package || %{}
    pr = pr(row)

    %{
      "id" => row.id,
      "state" => row.operational_state.key,
      "status" => row.raw_status,
      "next_action" => preview(action, 140),
      "next_actor" => actor,
      "merge_eligibility" => merge_eligibility(row, phase)
    }
    |> put_present("waiting_reason", signal["waiting_reason"])
    |> put_present("observation_stale", if(summary[:observation_stale] not in [nil, []], do: summary[:observation_stale]))
    |> put_blockers(summary)
    |> put_waiting_for(summary[:stacked_on] || [])
    |> put_prerequisite(summary)
    |> put_present("worker", get_in(summary, [:worker_terminal, :address]))
    |> put_present("pr_url", pr[:url])
    |> put_present("head_sha", pr[:head_sha])
    |> put_present("current_head_sha", if(pr[:current_head_sha] != pr[:head_sha], do: pr[:current_head_sha]))
    |> put_present("ci", ci(pr, summary))
    |> put_present("review", review(summary))
    |> put_present("review_mode", if(action in ["run_launch_line", "inspect_worker"], do: row.review_mode))
  end

  defp merge_eligibility(_row, "archived"), do: %{eligible: false, reason_codes: ["work_request_archived"], next_action: "restore"}
  defp merge_eligibility(row, _phase), do: Map.take(row.merge_eligibility, [:eligible, :reason_codes, :next_action])

  defp activity(_row, "archived"), do: {"restore", "operator"}
  defp activity(row, _phase), do: activity(row)

  defp activity(nil), do: {"wait", nil}
  defp activity(%{operational_state: %{key: "needs_closeout"}}), do: {"sync_pr", "architect"}

  defp activity(row) do
    signal = row.operational_state.activity_signal
    {signal["next_action"], signal["next_actor"]}
  end

  defp pr(row) do
    case get_in(row, [:work_package, :pr_signal]) do
      %{} = signal when map_size(signal) > 1 -> signal
      _missing -> get_in(row, [:work_package, :pr]) || %{}
    end
  end

  defp ci(pr, summary) do
    case pr[:checks] do
      %{} = checks ->
        failing = checks[:failing] |> List.wrap() |> List.first() |> preview(120)

        checks
        |> Map.take([:status, :current, :total])
        |> put_present("failing", failing)
        |> put_present("override", if(pr[:head_sha] && get_in(summary, [:ci_override, :head]) == pr[:head_sha], do: true))

      _missing ->
        nil
    end
  end

  defp review(%{review_signal: %{} = review}) do
    Map.take(review, [:status, :evidence_id, :accepted_head, :reviewed_head, :current_head, :round, :provider_status])
  end

  defp review(_summary), do: nil

  defp recovery_actions(rows) do
    rows
    |> Enum.map(&elem(activity(&1), 0))
    |> Enum.uniq()
    |> Map.new(&{&1, recovery(&1)})
    |> Map.reject(fn {_action, hint} -> is_nil(hint) end)
  end

  defp recovery("run_launch_line"), do: "If no worker holds the package, repeat dispatch_work_package with its review_mode and run launch_line."
  defp recovery("inspect_worker"), do: "Check the worker and PR. Repeat dispatch_work_package with its review_mode to refresh the assignment."
  defp recovery("sync_pr"), do: "Read the PR on GitHub and sync_pr with its URL."
  defp recovery("replan"), do: "Replace the impossible prerequisite or change the plan."
  defp recovery("reclassify"), do: "Ask the operator to clear the legacy package hold after recording its replacement."
  defp recovery(_action), do: nil

  defp put_blockers(row, summary) do
    ids = get_in(summary, [:blocker_state, :active_ids]) || []
    visible = ids |> Enum.filter(&(byte_size(&1) <= 256)) |> Enum.take(8)
    more = length(ids) - length(visible)

    row
    |> put_present("blocker_ids", if(visible != [], do: visible))
    |> put_present("more_blockers", if(more > 0, do: more))
  end

  defp put_prerequisite(%{"waiting_for" => _} = row, _summary), do: row
  defp put_prerequisite(row, summary), do: put_waiting_for(row, get_in(summary, [:dependency_signal, :unmet_work_package_ids]) || [])

  defp put_waiting_for(row, []), do: row

  defp put_waiting_for(row, ids) do
    {waiting, rest} = Enum.split(ids, 8)

    row
    |> Map.put("waiting_for", waiting)
    |> put_present("more_prerequisites", if(rest != [], do: length(rest)))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp preview(nil, _max_bytes), do: nil

  defp preview(text, max_bytes) do
    text |> Redactor.redact_text() |> String.split() |> Enum.join(" ") |> clip(max_bytes)
  end

  defp clip(nil, _max_bytes), do: nil

  defp clip(text, max_bytes) do
    if byte_size(text) > max_bytes do
      text
      |> binary_part(0, max_bytes - 3)
      |> :unicode.characters_to_binary()
      |> case do
        {:incomplete, prefix, _trailing} -> prefix <> "…"
        prefix -> prefix <> "…"
      end
    else
      text
    end
  end
end
