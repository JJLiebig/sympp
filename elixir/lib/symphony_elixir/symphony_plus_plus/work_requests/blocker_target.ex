defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.BlockerTarget do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.Snapshot
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DeliveryResolution, Phase, Repository, WorkRequest}

  @type target :: %{required(String.t()) => String.t()}
  @type state :: String.t()

  @spec normalize(term()) :: {:ok, target()} | {:error, :invalid_blocker_target}
  def normalize(%{"kind" => "pr", "id" => value}) when is_binary(value) and byte_size(value) <= 240 do
    with [repo, number] <- String.split(String.trim(value), "#", parts: 2),
         {:ok, {owner, name}} <- RepoIdentity.github_repository(repo),
         {number, ""} when number in 1..2_147_483_647 <- Integer.parse(number) do
      {:ok, %{"kind" => "pr", "id" => String.downcase("#{owner}/#{name}") <> "##{number}"}}
    else
      _invalid -> {:error, :invalid_blocker_target}
    end
  end

  def normalize(%{"kind" => kind, "id" => id}) when kind in ["work_request", "work_package", "ask"] and is_binary(id) and byte_size(id) <= 240 do
    id = String.trim(id)
    if Regex.match?(~r/\A[\w.-]+\z/, id), do: {:ok, %{"kind" => kind, "id" => id}}, else: {:error, :invalid_blocker_target}
  end

  def normalize(_target), do: {:error, :invalid_blocker_target}

  @spec id(target()) :: String.t()
  def id(%{"kind" => kind, "id" => target}), do: kind <> ":" <> target

  @spec pr_entry(target()) :: Snapshot.entry() | nil
  def pr_entry(%{"kind" => "pr", "id" => id}) do
    [owner, repo, number] = String.split(id, ["/", "#"])
    {:pr, owner, repo, String.to_integer(number)}
  end

  def pr_entry(_target), do: nil

  @spec attached_pr_id(term()) :: String.t() | nil
  def attached_pr_id({:ok, %{ref: %{repository: repository, number: number}}}) do
    "#{String.downcase(repository)}##{number}"
  end

  def attached_pr_id(_attachment), do: nil

  @spec initial_snapshot([target()]) :: map()
  def initial_snapshot(targets), do: targets |> Enum.flat_map(&List.wrap(pr_entry(&1))) |> Snapshot.fetch()

  @spec state(module(), target(), map()) :: state()
  def state(repo, target, snapshots) do
    case target do
      %{"kind" => "pr"} -> pr_state(snapshots[pr_entry(target)])
      %{"kind" => "ask", "id" => id} -> ask_state(repo.get(Ask, id))
      %{"kind" => "work_request", "id" => id} -> request_state(repo, repo.get(WorkRequest, id))
      %{"kind" => "work_package", "id" => id} -> package_state(repo, id)
    end
  rescue
    _error in Exqlite.Error -> "unknown"
  end

  defp pr_state({:ok, %{"merged" => true}}), do: "cleared"
  defp pr_state({:ok, %{"state" => "closed", "merged" => false}}), do: "impossible"
  defp pr_state({:ok, %{"state" => "open"}}), do: "waiting"
  defp pr_state(_unavailable), do: "unknown"

  defp ask_state(%Ask{state: "answered"}), do: "cleared"
  defp ask_state(%Ask{state: "withdrawn"}), do: "impossible"
  defp ask_state(%Ask{state: "open"}), do: "waiting"
  defp ask_state(nil), do: "unknown"

  defp request_state(_repo, nil), do: "unknown"

  defp request_state(repo, request) do
    case Phase.load_one(repo, request) do
      {:ok, %{completed_at: %DateTime{}}} -> "cleared"
      {:ok, %{phase: phase}} when phase in ["archived", "unresolved"] -> "impossible"
      {:ok, _phase} -> "waiting"
      {:error, _reason} -> "unknown"
    end
  end

  defp package_state(repo, id) do
    case package_waits(repo, id) do
      {:ok, waiting} -> dependency_state(waiting)
      {:error, _reason} -> "unknown"
    end
  end

  @spec package_waits(module(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def package_waits(repo, id) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{status: "ended"} = package -> ended_package_waits(repo, package)
      %WorkPackage{} -> {:ok, [%{work_package_id: id, ended_as: nil}]}
      nil -> {:error, :not_found}
    end
  end

  defp ended_package_waits(repo, package) do
    with {:ok, packages} <- Repository.list_work_packages(repo, package.work_request_id),
         {:ok, successors} <- ExecutionGraph.successors(repo, packages) do
      deliveries = Phase.delivery_records(repo, Enum.map(packages, & &1.id))
      waiting = DeliveryResolution.waiting_for(package.id, Map.new(packages, &{&1.id, &1}), deliveries, successors)
      {:ok, waiting}
    end
  end

  @spec dependency_state([map()]) :: state()
  def dependency_state([]), do: "cleared"
  def dependency_state(waits), do: if(Enum.any?(waits, & &1.ended_as), do: "impossible", else: "waiting")

  @spec present(target() | nil, state(), String.t() | nil) :: map()
  def present(target, state, summary) do
    %{
      target: target,
      summary: summary,
      state: if(state == "unknown", do: "waiting", else: state),
      unknown: state == "unknown",
      next_action: next_action(state)
    }
  end

  defp next_action("cleared"), do: "dispatch"
  defp next_action("impossible"), do: "replan"
  defp next_action(_state), do: "wait"
end
