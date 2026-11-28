defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Wakes do
  @moduledoc false

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias SymphonyElixir.SymphonyPlusPlus.{DashboardPubSub, HerdrCore, Ownership}
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.{Terminal, WorkedOn}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{BlockerObservations, Phase, WorkRequest}

  @type message :: {String.t(), String.t()}

  @spec blockers(module(), [BlockerObservations.transition()]) :: [message()]
  def blockers(repo, changes) do
    changes
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {id, transitions} -> owner_lines(repo, id, transitions) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {key, lines} -> {key, lines |> Enum.uniq() |> Enum.sort() |> Enum.join(" | ") |> envelope()} end)
  end

  defp owner_lines(repo, id, changes) do
    with %WorkRequest{archived_at: nil, operator_completed_at: nil} <- repo.get(WorkRequest, id),
         %WorkedOn{terminal_key: key} <- Ownership.owner(repo, id) do
      for {^id, target, state} <- changes, do: {key, "#{id} #{target["id"]} #{state}. #{action(state)}"}
    else
      _unowned_or_ended -> []
    end
  end

  defp action("cleared"), do: "Dispatch."
  defp action("impossible"), do: "Replan."

  @spec vacancies(module(), HerdrCore.snapshot(), DateTime.t()) :: [message()]
  def vacancies(repo, %{core_id: core_id, terminals: terminals}, read_at) do
    case repo.transaction(fn -> mark_vacancies(repo, core_id, terminals, read_at) end, mode: :immediate) do
      {:ok, [_ | _] = requests} ->
        DashboardPubSub.broadcast_changed()

        chiefs =
          for {address, %{"state" => "live", "labels" => %{"sympp.role" => "chief"} = labels}} <- terminals,
              do: {Terminal.key(core_id, address), labels["sympp.domain"]}

        for request <- requests, {key, _domain} <- [chief(request, chiefs)], do: {key, envelope("#{request.id} No owner. Assign an architect.")}

      _none ->
        []
    end
  end

  # A detach can end authority without proving the terminal is gone. Confirm
  # the latest owner against its own fresh roster before marking a vacancy.
  defp mark_vacancies(repo, core_id, terminals, read_at) do
    requests =
      for {request, key} <- ended_owners(repo, read_at),
          {^core_id, address} <- [Terminal.split_key(key)],
          terminals[address] == nil or match?(%{"state" => "finished"}, terminals[address]),
          do: request

    case Phase.load(repo, requests) do
      {:ok, phases} ->
        for request <- requests, phases[request.id].phase != "done", do: repo.update!(Ecto.Changeset.change(request, owner_missing: true))

      {:error, reason} ->
        repo.rollback(reason)
    end
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
        on: request.id == owner.subject_id,
        where: [subject_kind: "work_request", role: "architect", state: "finished", finish_reason: "terminal_finished"],
        where: owner.started_at < ^read_at and not exists(subquery(newer)),
        where: not request.owner_missing and is_nil(request.archived_at) and is_nil(request.operator_completed_at),
        select: {request, owner.terminal_key}
      )
    )
  end

  defp chief(request, chiefs) do
    domain = request.dispatched_by["domain"]

    Enum.min_by(
      chiefs,
      fn {key, chief_domain} ->
        {is_nil(domain) or domain != chief_domain, key != request.creator_terminal, key}
      end,
      fn -> nil end
    )
  end

  @spec deliver([message()]) :: :ok
  def deliver([]), do: :ok

  def deliver(messages) do
    with {:ok, %{core_id: core_id, terminals: terminals}} <- HerdrCore.refresh() do
      for {key, line} <- messages,
          {^core_id, address} <- [Terminal.split_key(key)],
          match?(%{"state" => "live"}, terminals[address]),
          do: HerdrCore.deliver(key, line)
    end

    :ok
  end

  defp envelope(line), do: "<sympp> #{line}</sympp>"
end
