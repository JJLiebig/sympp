defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.BlockerObservations do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Blockers, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerTarget, WorkRequest}

  @type watching :: {[WorkRequest.t()], [{String.t(), map()}]}
  @type subject :: {String.t(), String.t()}

  @spec watch(module()) :: watching()
  def watch(repo) do
    requests = repo.all(from(request in WorkRequest, where: is_nil(request.archived_at) and fragment("json_type(?, '$.parking.targets') = 'array'", request.report)))

    events =
      repo.all(
        from(event in ProgressEvent,
          join: package in WorkPackage,
          on: package.id == event.work_package_id,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status != "ended" and is_nil(request.archived_at) and fragment("json_extract(?, '$.type') = 'blocker'", event.payload)
        )
      )

    packages =
      for {package_id, group} <- Enum.group_by(events, & &1.work_package_id),
          %{active: true, target: %{}} = blocker <- BlockerProjection.blockers(group),
          do: {package_id, blocker}

    {Enum.filter(requests, &request_waiting?/1), packages}
  end

  @spec pr_entries(watching()) :: list()
  def pr_entries(watching), do: for({_subject, target} <- targets(watching), entry = BlockerTarget.pr_entry(target), do: entry)

  @spec require_acyclic(module(), subject(), [BlockerTarget.target()]) :: :ok | {:error, term()}
  def require_acyclic(repo, {kind, id} = subject, targets) do
    cond do
      Enum.any?(targets, &match?(%{"kind" => ^kind, "id" => ^id}, &1)) ->
        {:error, :blocker_cycle}

      Enum.any?(targets, &pending_dependency?/1) ->
        check_dependencies(repo, subject, targets)

      true ->
        :ok
    end
  end

  defp pending_dependency?(target), do: target["kind"] != "ask" and target["state"] not in ["cleared", "impossible"]

  defp check_dependencies(repo, subject, targets) do
    with {:ok, graph} <- dependency_graph(repo, targets(watch(repo))) do
      if cyclic?(graph, subject, targets), do: {:error, :blocker_cycle}, else: :ok
    end
  end

  defp dependency_graph(repo, targets) do
    parents =
      repo.all(
        from(package in WorkPackage,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status != "ended" and is_nil(request.archived_at),
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

  defp cyclic?(graph, subject, targets) do
    pending = Enum.flat_map(targets, &vertices(&1, graph))
    reaches?(pending, subject, graph, %{})
  end

  defp reaches?([], _goal, _graph, _seen), do: false
  defp reaches?([goal | _rest], goal, _graph, _seen), do: true

  defp reaches?([vertex | rest], goal, graph, seen) do
    next = if Map.has_key?(seen, vertex), do: rest, else: prerequisites(vertex, graph) ++ rest
    reaches?(next, goal, graph, Map.put(seen, vertex, true))
  end

  defp prerequisites({"work_request", id} = vertex, graph) do
    target = %{"kind" => "work_request", "id" => id}

    if BlockerTarget.state(graph.repo, target, %{}) in ["waiting", "unknown"] do
      declared(vertex, graph) ++ package_vertices(Map.get(graph.packages, id, []))
    else
      []
    end
  end

  defp prerequisites({"work_package", id} = vertex, graph) do
    declared(vertex, graph) ++ plan_prerequisites(graph, id)
  end

  defp plan_prerequisites(graph, id) do
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

  defp declared(vertex, graph), do: Enum.flat_map(Map.get(graph.declared, vertex, []), &vertices(&1, graph))

  defp vertices(%{"state" => state}, _graph) when state in ["cleared", "impossible"], do: []
  defp vertices(%{"kind" => "pr", "id" => id}, graph), do: package_vertices(Map.get(graph.prs, id, []))
  defp vertices(%{"kind" => "work_request", "id" => id}, _graph), do: [{"work_request", id}]

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
    events = for {id, blocker} <- packages, do: {id, blocker, Map.put(blocker.target, "state", blocker.state)}
    declaration_edges(reports, events)
  end

  defp declaration_edges(reports, events) do
    request_edges = for {request, targets} <- reports, target <- targets, target["state"] != "cleared", do: {{"work_request", request.id}, target}
    request_edges ++ Enum.map(events, fn {id, _blocker, target} -> {{"work_package", id}, target} end)
  end

  @spec evaluate(module(), [BlockerTarget.target()], map()) :: [map()]
  def evaluate(repo, targets, snapshots) do
    Enum.map(targets, fn
      %{"state" => "cleared"} = target -> target
      target -> Map.put(target, "state", BlockerTarget.state(repo, target, snapshots))
    end)
  end

  @spec publish(module(), watching(), map()) :: :ok
  def publish(repo, {requests, packages}, snapshots) do
    reports = for request <- requests, do: {request, evaluate(repo, request.report["parking"]["targets"], snapshots)}

    events =
      for {id, blocker} <- packages,
          state = BlockerTarget.state(repo, blocker.target, snapshots),
          do: {id, blocker, Map.put(blocker.target, "state", state)}

    graph = attachment_graph(repo, declaration_edges(reports, events))

    for {id, blocker, target} <- events,
        state = attachment_state(graph, {"work_package", id}, target)["state"],
        state != Blockers.observed_state(blocker),
        do: Blockers.observe(repo, id, blocker, state)

    Enum.each(reports, fn {request, targets} ->
      publish_report(repo, request, Enum.map(targets, &attachment_state(graph, {"work_request", request.id}, &1)))
    end)
  end

  # A newly attached PR can reveal a cycle after a declaration. Use the fresh
  # provider state so an open PR in that cycle remains impossible until replanned.
  defp attachment_graph(repo, edges) do
    if Enum.any?(edges, fn {_subject, target} -> target["kind"] == "pr" and pending_dependency?(target) end) do
      with {:ok, graph} <- dependency_graph(repo, edges), do: graph
    end
  end

  defp attachment_state(%{} = graph, subject, %{"kind" => "pr", "state" => state} = target) when state in ["waiting", "unknown"] do
    if cyclic?(graph, subject, [target]), do: %{target | "state" => "impossible"}, else: target
  end

  defp attachment_state(_graph, _subject, target), do: target

  defp publish_report(repo, request, targets) do
    parking = request.report["parking"]

    if targets != parking["targets"] do
      result = repo.transaction(fn -> update_report(repo, request.id, parking, targets) end, mode: :immediate)
      if match?({:ok, %WorkRequest{}}, result), do: DashboardPubSub.broadcast_changed()
    end
  end

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
