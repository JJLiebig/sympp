defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.BlockerObservations do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Blockers, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerTarget, WorkRequest}

  @type watching :: {[WorkRequest.t()], [{String.t(), String.t(), map()}]}

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
          where: package.status != "ended" and is_nil(request.archived_at) and fragment("json_extract(?, '$.type') = 'blocker'", event.payload),
          select: {request.id, event}
        )
      )

    by_package = Enum.group_by(events, fn {id, event} -> {id, event.work_package_id} end, &elem(&1, 1))

    packages =
      for {{request_id, package_id}, group} <- by_package,
          %{active: true, target: %{}} = blocker <- BlockerProjection.blockers(group),
          do: {request_id, package_id, blocker}

    {Enum.filter(requests, &request_waiting?/1), packages}
  end

  @spec pr_entries(watching()) :: list()
  def pr_entries(watching) do
    for {_request, target} <- targets(watching), entry = BlockerTarget.pr_entry(target), do: entry
  end

  @spec require_acyclic(module(), String.t(), [BlockerTarget.target()]) :: :ok | {:error, :blocker_cycle}
  def require_acyclic(repo, request_id, targets) do
    case request_ids(targets) do
      [] ->
        :ok

      ids ->
        edges = repo |> watch() |> targets() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        if reaches?(repo, ids, request_id, edges, %{}), do: {:error, :blocker_cycle}, else: :ok
    end
  end

  defp reaches?(_repo, [], _goal, _edges, _seen), do: false
  defp reaches?(_repo, [goal | _rest], goal, _edges, _seen), do: true

  defp reaches?(repo, [id | rest], goal, edges, seen) do
    waits = request_ids(Map.get(edges, id, []))
    unseen? = not Map.has_key?(seen, id)
    next = if unseen? and waits != [] and unresolved_request?(repo, id), do: waits ++ rest, else: rest
    reaches?(repo, next, goal, edges, Map.put(seen, id, true))
  end

  defp unresolved_request?(repo, id), do: BlockerTarget.state(repo, %{"kind" => "work_request", "id" => id}, %{}) in ["waiting", "unknown"]

  defp request_ids(targets), do: for(%{"kind" => "work_request", "id" => id} <- targets, do: id)
  defp request_waiting?(request), do: is_nil(request.report["parking"]["resumed_at"]) and Enum.any?(request.report["parking"]["targets"], &(&1["state"] != "cleared"))

  defp targets({requests, packages}) do
    for_request = for request <- requests, target <- request.report["parking"]["targets"], target["state"] != "cleared", do: {request.id, target}
    for_request ++ Enum.map(packages, fn {request_id, _package_id, blocker} -> {request_id, blocker.target} end)
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
    for {_request_id, package_id, blocker} <- packages,
        state = BlockerTarget.state(repo, blocker.target, snapshots),
        state != Blockers.observed_state(blocker),
        do: Blockers.observe(repo, package_id, blocker, state)

    Enum.each(requests, &publish_report(repo, &1, snapshots))
  end

  defp publish_report(repo, request, snapshots) do
    parking = request.report["parking"]
    targets = evaluate(repo, parking["targets"], snapshots)

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
