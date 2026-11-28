defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Wakes do
  @moduledoc false

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, Ownership}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerObservations, Phase, WorkRequest}

  @type vacancy :: {String.t(), String.t(), String.t()}
  @type batch :: {:blockers, [BlockerObservations.transition()]} | {:vacancies, [vacancy()]}

  @spec vacancies(module(), HerdrCore.snapshot(), DateTime.t()) :: [vacancy()]
  def vacancies(repo, %{core_id: core_id, terminals: terminals}, read_at) do
    {:ok, requests} = repo.transaction(fn -> mark_vacancies(repo, core_id, terminals, read_at) end, mode: :immediate)
    if requests != [], do: DashboardPubSub.broadcast_changed()

    chiefs =
      for {address, %{"state" => "live", "labels" => %{"sympp.role" => "chief"} = labels}} <- terminals,
          do: {Terminal.key(core_id, address), labels["sympp.domain"]}

    for request <- requests, {key, _domain} <- [chief(request, chiefs)], do: {request.id, request.vacated_owner_id, key}
  end

  # A detach can end authority without proving the terminal is gone. Confirm
  # the latest owner against its own fresh roster before marking a vacancy.
  defp mark_vacancies(repo, core_id, terminals, read_at) do
    vacancies =
      for {request, owner_id, key} <- ended_owners(repo, read_at),
          {^core_id, address} <- [Terminal.split_key(key)],
          terminals[address] == nil or match?(%{"state" => "finished"}, terminals[address]),
          do: {request, owner_id}

    {:ok, phases} = Phase.load(repo, Enum.map(vacancies, &elem(&1, 0)))
    for {request, owner_id} <- vacancies, phases[request.id].phase != "done", do: repo.update!(Ecto.Changeset.change(request, vacated_owner_id: owner_id))
  end

  defp ended_owners(repo, read_at) do
    newer =
      from(row in WorkedOn,
        where: row.subject_kind == "work_request" and row.subject_id == parent_as(:owner).subject_id,
        where:
          row.started_at > parent_as(:owner).started_at or row.state == "live" or
            (row.started_at == parent_as(:owner).started_at and row.id > parent_as(:owner).id),
        select: 1
      )

    repo.all(
      from(owner in WorkedOn,
        as: :owner,
        join: request in WorkRequest,
        on: request.id == owner.subject_id and is_nil(request.vacated_owner_id),
        where: [subject_kind: "work_request", role: "architect", state: "finished", finish_reason: "terminal_finished"],
        where: owner.started_at < ^read_at and not exists(subquery(newer)),
        where: is_nil(request.archived_at) and is_nil(request.operator_completed_at),
        select: {request, owner.id, owner.terminal_key}
      )
    )
  end

  defp chief(request, chiefs) do
    domain = request.dispatched_by["domain"]
    rank = fn {key, candidate} -> {is_nil(domain) or domain != candidate, key != request.creator_terminal, key} end
    Enum.min_by(chiefs, rank, fn -> nil end)
  end

  @spec deliver(module(), batch()) :: :ok
  def deliver(_repo, {_kind, []}), do: :ok

  def deliver(repo, batch) do
    if match?({:ok, _fresh}, HerdrCore.refresh()), do: send_batch(repo, batch)
    :ok
  end

  defp send_batch(repo, {:blockers, changes}) do
    owners = changes |> Enum.group_by(&elem(&1, 0)) |> Enum.group_by(fn {id, _changes} -> owner_key(repo, id) end)

    for {key, requests} <- owners,
        key != nil,
        lines = Enum.flat_map(requests, &owner_lines(repo, key, &1)),
        lines != [],
        do: HerdrCore.deliver(key, lines |> Enum.uniq() |> Enum.sort() |> Enum.join(" | ") |> envelope())
  end

  defp send_batch(repo, {:vacancies, vacancies}) do
    for {id, owner_id, key} <- vacancies,
        %WorkRequest{vacated_owner_id: ^owner_id} = request <- [repo.get(WorkRequest, id)],
        open?(repo, request),
        do: HerdrCore.deliver(key, envelope("#{id} No owner. Assign an architect."))
  end

  defp owner_lines(repo, key, {id, changes}) do
    if open?(repo, repo.get(WorkRequest, id)) and owner_key(repo, id) == key do
      for {^id, target, state} <- changes, do: "#{id} #{target["id"]} #{state}. #{action(state)}"
    else
      []
    end
  end

  defp owner_key(repo, id) do
    with %WorkedOn{terminal_key: key} <- Ownership.owner(repo, id), do: key
  end

  defp open?(repo, %WorkRequest{archived_at: nil, operator_completed_at: nil} = request) do
    match?({:ok, %{phase: phase}} when phase != "done", Phase.load_one(repo, request))
  end

  defp open?(_repo, _request), do: false

  defp action("cleared"), do: "Dispatch."
  defp action("impossible"), do: "Replan."

  defp envelope(line), do: "<sympp> #{line}</sympp>"
end
