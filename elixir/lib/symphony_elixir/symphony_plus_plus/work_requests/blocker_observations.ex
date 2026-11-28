defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.BlockerObservations do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Blockers, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerTarget, WorkRequest}

  @type watching :: {[WorkRequest.t()], [{String.t(), String.t(), map()}]}
  @type subject :: {String.t(), String.t()}
  @type transition :: {String.t(), BlockerTarget.target(), BlockerTarget.state()}

  @spec watch(module()) :: watching()
  def watch(repo), do: watch(repo, false)

  defp watch(repo, include_archived?) do
    requests =
      repo.all(
        from(request in WorkRequest,
          where: (^include_archived? or is_nil(request.archived_at)) and fragment("json_type(?, '$.parking.targets') = 'array'", request.report)
        )
      )

    events =
      repo.all(
        from(event in ProgressEvent,
          join: package in WorkPackage,
          on: package.id == event.work_package_id,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status != "ended" and (^include_archived? or is_nil(request.archived_at)) and fragment("json_extract(?, '$.type') = 'blocker'", event.payload),
          select: {{request.id, package.id}, event}
        )
      )

    packages =
      for {{request_id, package_id}, group} <- Enum.group_by(events, &elem(&1, 0), &elem(&1, 1)),
          known = last_known_package_states(group),
          %{active: true, target: %{}} = blocker <- BlockerProjection.blockers(group),
          do: {request_id, package_id, Map.put(blocker, :last_known_state, known[blocker.id])}

    {Enum.filter(requests, &request_waiting?/1), packages}
  end

  defp last_known_package_states(events) do
    events
    |> Enum.reject(&(&1.payload["state"] == "unknown"))
    |> BlockerProjection.blockers()
    |> Map.new(&{&1.id, if(&1.active, do: &1.state)})
  end

  @spec pr_entries(watching()) :: list()
  def pr_entries(watching), do: for({_subject, target} <- targets(watching), entry = BlockerTarget.pr_entry(target), do: entry)

  @spec require_acyclic(module(), subject(), [BlockerTarget.target()], :all | :declared) :: :ok | {:error, term()}
  def require_acyclic(repo, {kind, id} = subject, targets, mode \\ :all) do
    cond do
      Enum.any?(targets, &match?(%{"kind" => ^kind, "id" => ^id}, &1)) ->
        {:error, :blocker_cycle}

      Enum.any?(targets, &(&1["kind"] != "ask" and &1["state"] != "cleared")) ->
        check_dependencies(repo, subject, targets, mode)

      true ->
        :ok
    end
  end

  defp check_dependencies(repo, subject, targets, mode) do
    with edges when mode == :all or edges != [] <- targets(watch(repo, true)),
         {:ok, graph} <- dependency_graph(repo, edges),
         false <- cyclic?(graph, subject, targets, mode == :all) do
      :ok
    else
      [] -> :ok
      true -> {:error, :blocker_cycle}
      {:error, _reason} = error -> error
    end
  end

  defp dependency_graph(repo, targets) do
    parents =
      repo.all(
        from(package in WorkPackage,
          where: package.status != "ended" and not is_nil(package.work_request_id),
          select: {package.id, package.work_request_id}
        )
      )
      |> Map.new()

    with {:ok, attachments} <- PlanningRepository.pr_attachments(repo, Map.keys(parents)) do
      prs = for {id, attachment} <- attachments, ref = BlockerTarget.attached_pr_id(attachment), do: {ref, id}

      {:ok,
       %{
         repo: repo,
         parents: parents,
         packages: Enum.group_by(parents, &elem(&1, 1), &elem(&1, 0)),
         prs: Enum.group_by(prs, &elem(&1, 0), &elem(&1, 1)),
         declared: Enum.group_by(targets, &elem(&1, 0), &elem(&1, 1))
       }}
    end
  end

  defp cyclic?(graph, subject, targets, via_declaration? \\ true) do
    pending = for target <- targets, vertex <- vertices(target, graph), do: {vertex, via_declaration?}
    reaches?(pending, subject, graph, %{})
  end

  defp reaches?([], _goal, _graph, _seen), do: false
  defp reaches?([{goal, true} | _rest], goal, _graph, _seen), do: true
  defp reaches?([{goal, false} | rest], goal, graph, seen), do: reaches?(rest, goal, graph, seen)

  defp reaches?([step | rest], goal, graph, seen) do
    next = if Map.has_key?(seen, step), do: rest, else: neighbours(step, graph) ++ rest
    reaches?(next, goal, graph, Map.put(seen, step, true))
  end

  defp neighbours({vertex, via_declaration?}, graph) do
    declared = for target <- Map.get(graph.declared, vertex, []), neighbor <- vertices(target, graph), do: {neighbor, true}
    declared ++ Enum.map(prerequisites(vertex, graph), &{&1, via_declaration?})
  end

  defp prerequisites({"work_request", id}, graph), do: package_vertices(Map.get(graph.packages, id, []))

  defp prerequisites({"work_package", id}, graph) do
    with request_id when is_binary(request_id) <- graph.parents[id],
         {:ok, plan} <- ExecutionGraph.evaluate(graph.repo, request_id) do
      for edge <- plan.effective_edges,
          edge.dependent_work_package_id == id and BlockerTarget.dependency_state(edge.waiting_for) == "waiting",
          wait <- edge.waiting_for,
          do: {"work_package", wait.work_package_id}
    else
      _unavailable -> []
    end
  end

  defp vertices(%{"state" => "cleared"}, _graph), do: []

  # An attached PR can reopen. Its active declaration remains a dependency
  # even if the last successful observation found the PR closed.
  defp vertices(%{"kind" => "pr", "id" => id}, graph), do: package_vertices(Map.get(graph.prs, id, []))

  defp vertices(%{"kind" => "work_request", "id" => id} = target, graph) do
    # An undelivered request can be replanned or restored while the wait is active.
    if BlockerTarget.state(graph.repo, target, %{}) == "cleared", do: [], else: [{"work_request", id}]
  end

  defp vertices(%{"kind" => "work_package", "id" => id}, graph) do
    with {:ok, waits} <- BlockerTarget.package_waits(graph.repo, id),
         "waiting" <- BlockerTarget.dependency_state(waits) do
      for wait <- waits, do: {"work_package", wait.work_package_id}
    else
      _resolved_or_unavailable -> []
    end
  end

  defp vertices(_target, _graph), do: []

  defp package_vertices(ids), do: Enum.map(ids, &{"work_package", &1})
  defp request_waiting?(request), do: is_nil(request.report["parking"]["resumed_at"]) and Enum.any?(request.report["parking"]["targets"], &(&1["state"] != "cleared"))

  defp targets({requests, packages}) do
    reports = for request <- requests, do: {request, request.report["parking"]["targets"]}
    events = for {request_id, id, blocker} <- packages, do: {request_id, id, blocker, Map.put(blocker.target, "state", blocker.state)}
    declaration_edges(reports, events)
  end

  defp declaration_edges(reports, events) do
    request_edges = for {request, targets} <- reports, target <- targets, target["state"] != "cleared", do: {{"work_request", request.id}, target}
    request_edges ++ Enum.map(events, fn {_request_id, id, _blocker, target} -> {{"work_package", id}, target} end)
  end

  @spec evaluate(module(), [BlockerTarget.target()], map()) :: [map()]
  def evaluate(repo, targets, snapshots) do
    Enum.map(targets, fn
      %{"state" => "cleared"} = target -> target
      target -> Map.put(target, "state", BlockerTarget.state(repo, target, snapshots))
    end)
  end

  @spec publish(module(), watching(), map()) :: [transition()]
  def publish(repo, {requests, packages}, snapshots) do
    reports = for request <- requests, do: {request, evaluate(repo, request.report["parking"]["targets"], snapshots)}

    events =
      for {request_id, id, blocker} <- packages,
          state = BlockerTarget.state(repo, blocker.target, snapshots),
          do: {request_id, id, blocker, Map.put(blocker.target, "state", state)}

    graph = attachment_graph(repo, declaration_edges(reports, events))

    package_changes =
      for {request_id, id, blocker, target} <- events,
          state = attachment_state(graph, {"work_package", id}, target)["state"],
          state != Blockers.observed_state(blocker),
          {:ok, _blocker, :changed} <- [Blockers.observe(repo, id, blocker, state)],
          wake?(blocker.last_known_state, state),
          do: {request_id, blocker.target, state}

    request_changes =
      Enum.flat_map(reports, fn {request, targets} ->
        publish_report(repo, request, Enum.map(targets, &attachment_state(graph, {"work_request", request.id}, &1)))
      end)

    package_changes ++ request_changes
  end

  @spec publish_dependencies(module(), :baseline | :all) :: [transition()]
  def publish_dependencies(repo, mode \\ :all) do
    edges = watched_dependencies(repo, mode == :baseline)
    targets = Map.new(edges, &{&1.id, %{"kind" => "work_package", "id" => prerequisite(&1)}})
    states = targets |> Map.values() |> Enum.uniq() |> Map.new(&{&1, BlockerTarget.state(repo, &1, %{})})

    for edge <- edges,
        target = targets[edge.id],
        state = states[target],
        state != "unknown" and state != edge.blocker_state,
        {1, _rows} <- [store_dependency_state(repo, edge, state)],
        edge.blocker_state != nil and wake?(edge.blocker_state, state),
        do: {edge.work_request_id, target, state}
  end

  defp watched_dependencies(repo, baseline?) do
    repo.all(
      from(edge in DependencyEdge,
        join: package in WorkPackage,
        on: (edge.kind == "depends_on" and edge.source_id == package.id) or (edge.kind == "blocks" and edge.target_id == package.id),
        join: request in WorkRequest,
        on: request.id == edge.work_request_id,
        where: package.status != "ended" and is_nil(request.archived_at) and is_nil(request.operator_completed_at),
        where: is_nil(edge.blocker_state) or (not (^baseline?) and edge.blocker_state != "cleared")
      )
    )
  end

  defp prerequisite(%DependencyEdge{kind: "depends_on", target_id: id}), do: id
  defp prerequisite(%DependencyEdge{kind: "blocks", source_id: id}), do: id

  defp store_dependency_state(repo, edge, state) do
    query = from(current in DependencyEdge, where: current.id == ^edge.id and fragment("? IS ?", current.blocker_state, type(^edge.blocker_state, :string)))
    repo.update_all(query, set: [blocker_state: state])
  end

  # A newly attached PR can reveal a cycle after a declaration. Use the fresh
  # provider state so an open PR in that cycle remains impossible until replanned.
  defp attachment_graph(repo, edges) do
    if Enum.any?(edges, &match?({_subject, %{"kind" => "pr", "state" => "waiting"}}, &1)) do
      with {:ok, graph} <- dependency_graph(repo, edges), do: graph
    end
  end

  defp attachment_state(%{} = graph, subject, %{"kind" => "pr", "state" => "waiting"} = target) do
    if cyclic?(graph, subject, [target]), do: %{target | "state" => "impossible"}, else: target
  end

  defp attachment_state(_graph, _subject, target), do: target

  @spec keep_known_states([map()], map() | nil) :: [map()]
  def keep_known_states(targets, %{"resumed_at" => nil, "targets" => previous}) do
    states = Map.new(previous, &{BlockerTarget.id(&1), known_state(&1)})

    Enum.map(targets, fn
      %{"state" => "unknown"} = target -> Map.put(target, "last_known_state", states[BlockerTarget.id(target)])
      target -> Map.delete(target, "last_known_state")
    end)
  end

  def keep_known_states(targets, _no_prior_targets), do: targets

  defp publish_report(repo, request, targets) do
    parking = request.report["parking"]
    previous = parking["targets"]
    targets = keep_known_states(targets, parking)

    with true <- targets != previous,
         {:ok, %WorkRequest{}} <- repo.transaction(fn -> update_report(repo, request.id, parking, targets) end, mode: :immediate) do
      DashboardPubSub.broadcast_changed()

      for {old, %{"state" => state} = target} <- Enum.zip(previous, targets),
          wake?(known_state(old), state),
          do: {request.id, Map.take(target, ["kind", "id"]), state}
    else
      _unchanged -> []
    end
  end

  defp known_state(target), do: Map.get(target, "last_known_state", target["state"])
  defp wake?(before, state), do: state in ["cleared", "impossible"] and before != state

  defp update_report(repo, id, parking, targets) do
    with %WorkRequest{archived_at: nil} = current <- repo.get(WorkRequest, id),
         ^parking <- current.report["parking"] do
      report = put_in(current.report, ["parking", "targets"], targets)
      repo.update!(Ecto.Changeset.change(current, report: report))
    else
      _changed -> nil
    end
  end
end
