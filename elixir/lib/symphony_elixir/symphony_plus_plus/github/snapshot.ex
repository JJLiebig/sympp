defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.Snapshot do
  @moduledoc """
  One batched GraphQL read of the PRs the Observer watches.

  Each document aliases up to 25 entries. An entry is a known PR
  (`{:pr, owner, repo, number}`), a package branch whose PR isn't known yet
  (`{:branch, owner, repo, branch, base}`), or a card's branch, whose PR may
  target any base (`{:head, owner, repo, branch}`); every kind shares a
  document. A branch matches only a PR whose head lives in the same repository
  owner, so a fork branch with the same name is never taken; a package branch
  also needs the PR to target `base`.

  Per PR it reads state, merge evidence, head and base commits, draft flag,
  the head commit's check rollup and the last reviews (for the Codex receipt).
  A PR's commit list is a separate read (`commits/2`), made only when needed.
  """

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.Api

  @batch_size 25
  @max_concurrency 4
  @codex_login "chatgpt-codex-connector"
  @failing_conclusions ~w(failure cancelled timed_out startup_failure action_required stale)

  @fragment """
  fragment pr on PullRequest {
    number url state isDraft merged mergedAt mergeable headRefOid headRefName baseRefName baseRefOid
    mergeCommit { oid }
    headRepositoryOwner { login }
    commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 1) {
      checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } }
    reviews(last: 20) { nodes { author { login } state commit { oid } submittedAt } }
  }
  """

  @type entry ::
          {:pr, String.t(), String.t(), pos_integer()}
          | {:branch, String.t(), String.t(), String.t(), String.t()}
          | {:head, String.t(), String.t(), String.t()}
  @type result :: {:ok, map() | nil} | {:error, Api.error()}

  @doc """
  Reads every entry; returns each entry's result. A missing PR or branch
  without a PR is `{:ok, nil}`; a failed document gives its entries the error.
  """
  @spec fetch([entry()], keyword()) :: %{entry() => result()}
  def fetch(entries, opts \\ []) when is_list(entries) do
    graphql = Keyword.get(opts, :graphql, &Api.graphql/3)
    priority = Keyword.get(opts, :priority, :background)

    entries
    |> Enum.uniq()
    |> Enum.chunk_every(@batch_size)
    |> Task.async_stream(&fetch_batch(&1, graphql, priority),
      max_concurrency: @max_concurrency,
      ordered: false,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, results}, acc -> Map.merge(acc, results)
      {:exit, _reason}, acc -> acc
    end)
    |> then(fn results -> Map.new(entries, &{&1, Map.get(results, &1, {:error, :request_failed})}) end)
  end

  defp fetch_batch(entries, graphql, priority) do
    indexed = Enum.with_index(entries)
    {query, variables} = document(indexed)

    case graphql.(query, variables, priority) do
      {:ok, data} -> Map.new(indexed, fn {entry, index} -> {entry, decode_entry(entry, Map.get(data, "e#{index}"))} end)
      {:error, reason} -> Map.new(entries, &{&1, {:error, reason}})
    end
  end

  @doc false
  @spec document([{entry(), non_neg_integer()}]) :: {String.t(), map()}
  def document(indexed) do
    {declarations, selections, variables} =
      Enum.reduce(indexed, {[], [], %{}}, fn {entry, index}, {declarations, selections, variables} ->
        {entry_declarations, selection, entry_variables} = entry_document(entry, index)
        {declarations ++ entry_declarations, selections ++ [selection], Map.merge(variables, entry_variables)}
      end)

    query = "query(#{Enum.join(declarations, ", ")}) {\n#{Enum.join(selections, "\n")}\n}\n" <> @fragment
    {query, variables}
  end

  defp entry_document({:pr, owner, repo, number}, index) do
    {["$o#{index}: String!", "$r#{index}: String!", "$n#{index}: Int!"], "e#{index}: repository(owner: $o#{index}, name: $r#{index}) { pullRequest(number: $n#{index}) { ...pr } }",
     %{"o#{index}" => owner, "r#{index}" => repo, "n#{index}" => number}}
  end

  defp entry_document({:branch, owner, repo, branch, base}, index) do
    selection =
      "e#{index}: repository(owner: $o#{index}, name: $r#{index}) { pullRequests(headRefName: $b#{index}, " <>
        "baseRefName: $t#{index}, first: 5, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } } }"

    {["$o#{index}: String!", "$r#{index}: String!", "$b#{index}: String!", "$t#{index}: String!"], selection, %{"o#{index}" => owner, "r#{index}" => repo, "b#{index}" => branch, "t#{index}" => base}}
  end

  defp entry_document({:head, owner, repo, branch}, index) do
    selection =
      "e#{index}: repository(owner: $o#{index}, name: $r#{index}) { pullRequests(headRefName: $b#{index}, " <>
        "first: 5, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } } }"

    {["$o#{index}: String!", "$r#{index}: String!", "$b#{index}: String!"], selection, %{"o#{index}" => owner, "r#{index}" => repo, "b#{index}" => branch}}
  end

  @doc """
  The commit lists of open PRs, as GitHub lists a PR's commits (commits
  reachable from its base are left out; the first 100). One batched document
  per 25 PRs. Each result carries the head and base it was read at.
  """
  @spec commits([{String.t(), String.t(), pos_integer()}], keyword()) :: %{{String.t(), String.t(), pos_integer()} => {:ok, map()} | {:error, Api.error()}}
  def commits(prs, opts \\ []) when is_list(prs) do
    graphql = Keyword.get(opts, :graphql, &Api.graphql/3)
    priority = Keyword.get(opts, :priority, :background)

    prs
    |> Enum.uniq()
    |> Enum.chunk_every(@batch_size)
    |> Enum.flat_map(&fetch_commits_batch(&1, graphql, priority))
    |> Map.new()
  end

  defp fetch_commits_batch(batch, graphql, priority) do
    indexed = Enum.with_index(batch)
    declarations = Enum.flat_map(indexed, fn {_pr, index} -> ["$o#{index}: String!", "$r#{index}: String!", "$n#{index}: Int!"] end)
    variables = indexed |> Enum.flat_map(fn {{owner, repo, number}, index} -> [{"o#{index}", owner}, {"r#{index}", repo}, {"n#{index}", number}] end) |> Map.new()

    selections =
      Enum.map(indexed, fn {_pr, index} ->
        "e#{index}: repository(owner: $o#{index}, name: $r#{index}) { pullRequest(number: $n#{index}) " <>
          "{ headRefOid baseRefOid commits(first: 100) { nodes { commit { oid } } } } }"
      end)

    query = "query(#{Enum.join(declarations, ", ")}) {\n#{Enum.join(selections, "\n")}\n}\n"

    case graphql.(query, variables, priority) do
      {:ok, data} -> Enum.map(indexed, fn {pr, index} -> {pr, decode_commits(get_in(data, ["e#{index}", "pullRequest"]))} end)
      {:error, reason} -> Enum.map(batch, &{&1, {:error, reason}})
    end
  end

  defp decode_commits(%{"headRefOid" => head, "commits" => %{"nodes" => nodes}} = node) when is_binary(head) and is_list(nodes) do
    oids = for %{"commit" => %{"oid" => oid}} when is_binary(oid) <- nodes, do: oid
    {:ok, %{"head_sha" => head, "base_sha" => node["baseRefOid"], "commits" => oids}}
  end

  defp decode_commits(_unusable), do: {:error, :request_failed}

  @doc """
  The names of the failing checks on a head: a detail read (ETag-cached REST),
  made only when a head's rollup turns failing.
  """
  @spec failing_checks(String.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, Api.error()}
  def failing_checks(repository, head_sha, opts \\ []) when is_binary(repository) and is_binary(head_sha) do
    rest_get = Keyword.get(opts, :rest_get, &Api.rest_get/2)
    prefix = "repos/#{repository}/commits/#{URI.encode_www_form(head_sha)}"

    with {:ok, %{"check_runs" => runs}} when is_list(runs) <- rest_get.(prefix <> "/check-runs?per_page=100", :background),
         {:ok, %{"statuses" => statuses}} when is_list(statuses) <- rest_get.(prefix <> "/status?per_page=100", :background) do
      failing_runs = for %{"conclusion" => conclusion, "name" => name} <- runs, conclusion in @failing_conclusions, do: name
      failing_statuses = for %{"state" => state, "context" => name} <- statuses, state in ["failure", "error"], do: name
      {:ok, Enum.uniq(failing_runs ++ failing_statuses)}
    else
      {:error, reason} -> {:error, reason}
      _unusable -> {:error, :request_failed}
    end
  end

  defp decode_entry({:pr, owner, repo, _number}, %{"pullRequest" => %{} = node}), do: {:ok, decode_pr(node, owner, repo)}
  defp decode_entry({:pr, _owner, _repo, _number}, %{"pullRequest" => nil}), do: {:ok, nil}

  defp decode_entry({:branch, owner, repo, _branch, _base}, %{"pullRequests" => %{"nodes" => nodes}}) when is_list(nodes), do: branch_pr(nodes, owner, repo)
  defp decode_entry({:head, owner, repo, _branch}, %{"pullRequests" => %{"nodes" => nodes}}) when is_list(nodes), do: branch_pr(nodes, owner, repo)

  # The repository itself is missing or not visible to this credential.
  defp decode_entry(_entry, nil), do: {:error, :not_found}
  defp decode_entry(_entry, _unusable), do: {:error, :request_failed}

  # The branch's open PR if it has one, else its newest.
  defp branch_pr(nodes, owner, repo) do
    nodes
    |> Enum.filter(&(is_map(&1) and same_owner?(get_in(&1, ["headRepositoryOwner", "login"]), owner)))
    |> Enum.map(&decode_pr(&1, owner, repo))
    |> Enum.sort_by(&if(&1["state"] == "open", do: 0, else: 1))
    |> List.first()
    |> then(&{:ok, &1})
  end

  defp decode_pr(node, owner, repo) do
    merged? = node["merged"] == true
    commit = get_in(node, ["commits", "nodes"]) |> List.wrap() |> List.last() |> then(&(&1 && &1["commit"]))

    %{
      "repository" => "#{owner}/#{repo}",
      "number" => node["number"],
      "url" => node["url"],
      "state" => if(merged?, do: "merged", else: String.downcase(node["state"] || "")),
      "draft" => node["isDraft"] == true,
      "merged" => merged?,
      "merged_at" => node["mergedAt"],
      "merge_commit_sha" => get_in(node, ["mergeCommit", "oid"]),
      "head_sha" => node["headRefOid"],
      "base_sha" => node["baseRefOid"],
      "branch" => node["headRefName"],
      "base_branch" => node["baseRefName"],
      "mergeable" => node["mergeable"] && String.downcase(node["mergeable"]),
      "ci" => ci(commit && commit["statusCheckRollup"]),
      "github_review" => codex_review(get_in(node, ["reviews", "nodes"]))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ci(%{} = rollup) do
    counts =
      [get_in(rollup, ["contexts", "checkRunCountsByState"]), get_in(rollup, ["contexts", "statusContextCountsByState"])]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&is_map/1)

    total = counts |> Enum.map(&(&1["count"] || 0)) |> Enum.sum()
    pending = counts |> Enum.filter(&(&1["state"] in ~w(IN_PROGRESS PENDING QUEUED WAITING REQUESTED EXPECTED))) |> Enum.map(&(&1["count"] || 0)) |> Enum.sum()

    %{"status" => rollup_status(rollup["state"]), "completed" => total - pending, "total" => total}
  end

  # A head with no checks at all has no CI state.
  defp ci(_rollup), do: %{"status" => "unknown"}

  defp rollup_status("SUCCESS"), do: "passing"
  defp rollup_status(state) when state in ["FAILURE", "ERROR"], do: "failing"
  defp rollup_status(state) when state in ["PENDING", "EXPECTED"], do: "pending"
  defp rollup_status(_state), do: "unknown"

  defp codex_review(nodes) when is_list(nodes) do
    nodes
    |> Enum.filter(&(is_map(&1) and get_in(&1, ["author", "login"]) == @codex_login))
    |> List.last()
    |> case do
      nil -> nil
      review -> %{"state" => review["state"] && String.downcase(review["state"]), "commit" => get_in(review, ["commit", "oid"]), "submitted_at" => review["submittedAt"]}
    end
  end

  defp codex_review(_nodes), do: nil

  defp same_owner?(login, owner) when is_binary(login) and is_binary(owner), do: String.downcase(login) == String.downcase(owner)
  defp same_owner?(_login, _owner), do: false
end
