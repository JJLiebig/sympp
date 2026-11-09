defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Stacking do
  @moduledoc """
  Whether a package's PR is built on another package's unmerged work.

  A PR is stacked on another active package's open PR in the same repository
  when it carries commits of that PR. Commit lists come from GitHub's PR
  commits, which leave out commits reachable from the PR's base, so work
  imported by merging the base never counts. When two PRs share commits, the
  one that holds all of the other's commits and more is the stacked one;
  otherwise the PR opened later (higher number) is.

  Only active packages count: ended packages are left out even when their PR
  is still open, and each package is compared by its current PR alone, so a
  package's own earlier PRs never count.

  A view is what is known about one package's current PR:

    * `work_package_id`, `repository`, `number`;
    * `state` (`open`, `merged`, `closed`) and `commits` (oids), when read;
    * `fresh?` - read in this pass rather than taken from a stored snapshot.

  A merged or closed PR never counts. A view without a state or commit list
  is unknown; so is a stored view that would block. Those are refreshed
  first (`refresh`), and anything still unknown defers qualification.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DefaultClient, PullRequest, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type view :: %{
          required(:work_package_id) => String.t(),
          required(:repository) => String.t(),
          required(:number) => integer() | nil,
          optional(:state) => String.t() | nil,
          optional(:commits) => [String.t()] | nil,
          optional(:fresh?) => boolean()
        }
  @type result :: {:ok, [String.t()]} | :unknown

  @doc """
  The packages `own`'s PR is stacked on, or `:unknown`. `refresh` re-reads
  the views it is given and returns them fresh (unreadable ones stay unknown).
  """
  @spec check(view(), [view()], ([view()] -> [view()])) :: result()
  def check(own, others, refresh \\ & &1) do
    candidates = Enum.filter(others, &(&1.work_package_id != own.work_package_id and same_repository?(&1, own) and not ended_pr?(&1)))

    cond do
      candidates == [] -> {:ok, []}
      not is_list(Map.get(own, :commits)) -> :unknown
      true -> candidates |> refreshed(own, refresh) |> verdict(own)
    end
  end

  # A view that is unknown, or stored and would block, is read again first.
  defp refreshed(candidates, own, refresh) do
    {stale, settled} = Enum.split_with(candidates, &(unknown?(&1) or (not Map.get(&1, :fresh?, false) and stacked_on?(own, &1))))
    if stale == [], do: settled, else: settled ++ refresh.(stale)
  end

  defp verdict(candidates, own) do
    known = Enum.reject(candidates, &(ended_pr?(&1) or unknown?(&1)))
    stacked = for view <- known, stacked_on?(own, view), do: view.work_package_id
    unknown? = Enum.any?(candidates, &(not ended_pr?(&1) and unknown?(&1)))

    cond do
      stacked != [] -> {:ok, Enum.sort(Enum.uniq(stacked))}
      unknown? -> :unknown
      true -> {:ok, []}
    end
  end

  defp unknown?(view), do: Map.get(view, :state) != "open" or not is_list(Map.get(view, :commits))
  defp ended_pr?(view), do: Map.get(view, :state) in ["merged", "closed"]

  defp stacked_on?(own, other) do
    mine = MapSet.new(own.commits)
    theirs = MapSet.new(other.commits)

    not MapSet.disjoint?(mine, theirs) and not proper_subset?(mine, theirs) and
      (proper_subset?(theirs, mine) or opened_before?(other, own))
  end

  defp proper_subset?(left, right), do: MapSet.subset?(left, right) and MapSet.size(left) < MapSet.size(right)

  # PR numbers grow with creation in one repository.
  defp opened_before?(%{number: theirs}, %{number: mine}) when is_integer(theirs) and is_integer(mine), do: theirs < mine
  defp opened_before?(_other, _own), do: false

  defp same_repository?(%{repository: left}, %{repository: right}) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_repository?(_left, _right), do: false

  @doc "The next action for a package stacked on `work_package_ids`."
  @spec next_action([String.t()]) :: String.t()
  def next_action(work_package_ids) do
    others = Enum.join(work_package_ids, ", ")
    "remove #{others}'s unmerged commits, or wait for its PR to merge"
  end

  @doc """
  The stored views of every other active package's current PR: in-flight
  packages of WorkRequests that aren't archived, with the PR they have
  attached and the Observer's last snapshot of it when it is still that PR's
  current head.
  """
  @spec stored_views(module(), String.t()) :: [view()]
  def stored_views(repo, work_package_id) do
    packages =
      repo.all(
        from(package in WorkPackage,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status in ^Lifecycle.in_flight_statuses() and is_nil(request.archived_at) and package.id != ^work_package_id,
          select: package.id
        )
      )

    observations = observations(repo, packages)

    case PlanningRepository.list_progress_events(repo, packages) do
      {:ok, events} ->
        events
        |> Enum.group_by(& &1.work_package_id)
        |> Enum.flat_map(fn {id, events} -> stored_view(id, events, Map.get(observations, id)) end)

      {:error, _reason} ->
        []
    end
  end

  defp observations(_repo, []), do: %{}

  defp observations(repo, ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(&repo.all(from(observation in Observation, where: observation.work_package_id in ^&1)))
    |> Map.new(&{&1.work_package_id, &1})
  end

  defp stored_view(id, events, observation) do
    case PullRequestProgress.current_pr_state(events) do
      {:ok, current} ->
        view = %{work_package_id: id, repository: current.ref.repository, number: current.ref.number, head_sha: current.payload["head_sha"]}
        [Map.merge(view, observed(observation, view))]

      _no_pr ->
        []
    end
  end

  # The Observer's snapshot counts only for the same PR at the same head.
  defp observed(%Observation{pr: %{} = pr}, view) do
    same_pr? = pr["number"] == view.number and is_binary(pr["repository"]) and String.downcase(pr["repository"]) == String.downcase(view.repository)

    if same_pr? and (pr["state"] in ["merged", "closed"] or pr["head_sha"] == view.head_sha),
      do: %{state: pr["state"], commits: pr["commits"]},
      else: %{}
  end

  defp observed(_observation, _view), do: %{}

  @doc """
  Re-reads views through the architect's GitHub client (`gh pr view`), as
  `sync_pr` reads its own PR. A PR that can't be read stays unknown.
  """
  @spec refresh_with_client([view()]) :: [view()]
  def refresh_with_client(views) do
    client = Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient)

    Enum.map(views, fn view ->
      with {:ok, ref} <- PullRequest.parse_number(view.number, view.repository),
           {:ok, metadata} <- Client.fetch_pull_request(client, ref, provider_snapshot: true) do
        Map.merge(view, %{state: pr_state(metadata), commits: metadata["commits"], fresh?: true})
      else
        _unreadable -> Map.merge(view, %{state: nil, commits: nil, fresh?: true})
      end
    end)
  end

  defp pr_state(%{"merged" => true}), do: "merged"
  defp pr_state(%{"state" => state}) when is_binary(state), do: String.downcase(state)
  defp pr_state(_metadata), do: nil
end
