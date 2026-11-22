defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Stacking do
  @moduledoc """
  Whether a package's PR is built on another package's unmerged work.

  A PR is stacked on another active package's open PR in the same repository
  when it carries commits of that PR outside both PRs' bases. Complete lists
  come from GitHub. A pair with a missing or capped list instead uses immutable
  GitHub comparisons of the heads and base tips. When two PRs share commits, the
  one that holds all of the other's commits and more is the stacked one;
  otherwise the PR opened later (higher number) is.

  Only active packages count: ended packages are left out even when their PR
  is still open, and each package is compared by its current PR alone, so a
  package's own earlier PRs never count.

  A view is what is known about one package's current PR:

    * `work_package_id`, `repository`, `number`;
    * `state` (`open`, `merged`, `closed`), `head_sha`, `base_branch`, and
      `commits` (oids), when read;
    * `base_tip_sha` - the current target branch tip, when read by the Observer;
    * `fresh?` - read in this pass; other views name only the attached PR.

  A merged or closed PR never counts. A view that wasn't read in this pass is
  read first (`refresh`); a pair without enough evidence stays unknown and
  defers qualification.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, Client, DefaultClient, PullRequest, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type view :: %{
          required(:work_package_id) => String.t(),
          required(:repository) => String.t(),
          required(:number) => integer() | nil,
          optional(:state) => String.t() | nil,
          optional(:head_sha) => String.t() | nil,
          optional(:base_branch) => String.t() | nil,
          optional(:base_tip_sha) => String.t() | nil,
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

    candidates |> refreshed(refresh) |> verdict(own)
  end

  defp refreshed(candidates, refresh) do
    {unread, read} = Enum.split_with(candidates, &(not Map.get(&1, :fresh?, false)))
    if unread == [], do: read, else: read ++ refresh.(unread)
  end

  defp verdict(candidates, own) do
    base_tips = base_tips(own, candidates)
    results = Enum.map(candidates, &{&1.work_package_id, pair(own, &1, base_tips)})
    stacked = for {id, true} <- results, do: id

    cond do
      stacked != [] -> {:ok, Enum.sort(Enum.uniq(stacked))}
      Enum.any?(results, &(elem(&1, 1) == :unknown)) -> :unknown
      true -> {:ok, []}
    end
  end

  defp ended_pr?(view), do: Map.get(view, :state) in ["merged", "closed"]

  defp pair(_own, %{state: state}, _base_tips) when state in ["merged", "closed"], do: false

  defp pair(%{commits: left} = own, %{state: "open", commits: right} = other, _base_tips) when is_list(left) and is_list(right) do
    mine = MapSet.new(own.commits)
    theirs = MapSet.new(other.commits)

    not MapSet.disjoint?(mine, theirs) and not proper_subset?(mine, theirs) and
      (proper_subset?(theirs, mine) or opened_before?(other, own))
  end

  defp pair(%{head_sha: left} = own, %{state: "open", head_sha: right} = other, base_tips) do
    left_base = base_tip(own, base_tips)
    right_base = base_tip(other, base_tips)

    case Api.compare(own.repository, left, right) do
      {:ok, comparison} ->
        case common_work(own.repository, right, left_base, right_base, comparison) do
          true -> stacked_direction(own, other, left_base, right_base, comparison.merge_base)
          result -> result
        end

      {:error, _reason} ->
        :unknown
    end
  end

  defp pair(_own, _other, _base_tips), do: :unknown

  defp common_work(repository, right, left_base, right_base, %{merge_base: shared, ahead: ahead, behind: behind}) do
    left_merged = reachable?(repository, shared, left_base)
    right_merged = if left_base == right_base, do: left_merged, else: reachable?(repository, shared, right_base)
    merged? = left_merged == true or right_merged == true

    cond do
      left_merged == false and right_merged == false -> true
      merged? and all_common_from?(repository, right, shared, ahead, behind) -> false
      true -> :unknown
    end
  end

  # A single merge base outside both bases proves overlap. To prove disjointness
  # we must also rule out another merge base outside the bases. The shared SHA
  # is already an ancestor of both heads; equal ahead counts show that replacing
  # the left head by that ancestor removes none of the common history.
  defp all_common_from?(_repository, _right, _shared, ahead, behind) when ahead == 0 or behind == 0, do: true

  defp all_common_from?(repository, right, shared, ahead, _behind) do
    match?({:ok, %{merge_base: ^shared, ahead: ^ahead}}, Api.compare(repository, shared, right))
  end

  defp reachable?(_repository, sha, sha), do: true
  defp reachable?(_repository, _sha, nil), do: :unknown

  defp reachable?(repository, sha, tip) do
    case Api.compare(repository, sha, tip) do
      {:ok, %{merge_base: merge_base}} -> merge_base == sha
      {:error, _reason} -> :unknown
    end
  end

  # With a common base, strict inclusion of unmerged commits is exactly head
  # ancestry once we know the lists overlap. With different bases, divergent
  # heads outside both bases rule out inclusion in either direction.
  defp stacked_direction(%{head_sha: head}, %{head_sha: other}, base, base, head) when head != other, do: false
  defp stacked_direction(%{head_sha: head}, %{head_sha: other}, base, base, other) when head != other, do: true
  defp stacked_direction(own, other, base, base, _shared), do: opened_before?(other, own)

  defp stacked_direction(%{head_sha: left} = own, %{head_sha: right} = other, _left_base, _right_base, shared) when shared != left and shared != right,
    do: opened_before?(other, own)

  defp stacked_direction(_own, _other, _left_base, _right_base, _shared), do: :unknown

  # `gh pr view` gives the PR's recorded base OID, which can lag the branch.
  # Resolve each target once during a manual sync that needs ancestry evidence.
  defp base_tips(%{base_tip_sha: _read_by_observer}, _candidates), do: %{}

  defp base_tips(own, candidates) do
    fallback = Enum.filter(candidates, &(Map.get(&1, :state) == "open" and not (is_list(Map.get(own, :commits)) and is_list(Map.get(&1, :commits)))))

    if fallback == [] do
      %{}
    else
      [own | fallback]
      |> Enum.map(&Map.get(&1, :base_branch))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Map.new(&{&1, read_base_tip(own.repository, &1)})
    end
  end

  defp read_base_tip(repository, branch) do
    path = "repos/#{repository}/git/ref/heads/#{URI.encode(branch, &URI.char_unreserved?/1)}"

    case Api.rest_get(path) do
      {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> sha
      _unavailable -> nil
    end
  end

  defp base_tip(%{base_tip_sha: sha}, _base_tips), do: sha
  defp base_tip(view, base_tips), do: Map.get(base_tips, Map.get(view, :base_branch))

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
  The current PR of every other active package: in-flight packages of
  WorkRequests that aren't archived, with the PR they have attached. These
  views are unread; `check/3` reads them through `refresh`.
  """
  @spec attached_views(module(), String.t()) :: [view()]
  def attached_views(repo, work_package_id) do
    packages =
      repo.all(
        from(package in WorkPackage,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status in ^Lifecycle.in_flight_statuses() and is_nil(request.archived_at) and package.id != ^work_package_id,
          select: package.id
        )
      )

    case PlanningRepository.list_progress_events(repo, packages) do
      {:ok, events} ->
        events
        |> Enum.group_by(& &1.work_package_id)
        |> Enum.flat_map(fn {id, events} -> attached_view(id, events) end)

      {:error, _reason} ->
        []
    end
  end

  defp attached_view(id, events) do
    case PullRequestProgress.current_pr_state(events) do
      {:ok, current} -> [%{work_package_id: id, repository: current.ref.repository, number: current.ref.number}]
      _no_pr -> []
    end
  end

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
        Map.merge(view, %{
          state: pr_state(metadata),
          commits: metadata["commits"],
          head_sha: get_in(metadata, ["head", "sha"]),
          base_branch: get_in(metadata, ["base", "ref"]),
          fresh?: true
        })
      else
        _unreadable -> Map.merge(view, %{state: nil, commits: nil, fresh?: true})
      end
    end)
  end

  defp pr_state(%{"merged" => true}), do: "merged"
  defp pr_state(%{"state" => state}) when is_binary(state), do: String.downcase(state)
  defp pr_state(_metadata), do: nil
end
