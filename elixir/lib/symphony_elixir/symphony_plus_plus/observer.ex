defmodule SymphonyElixir.SymphonyPlusPlus.Observer do
  @moduledoc """
  The factory's one watcher of derived progress signals.

  Every 15 s it reads the factory host's herdr-core (`hc ls --all`, one call
  for every machine the core reaches):
    * a worker terminal (labels `sympp.role=worker`, `sympp.work_package_id`)
      starts working on its package, which moves derived progress from
      `launching` to `implementing`, and to `worker_exited` once it finishes;
    * a terminal the core reports finished ends its worked-on rows, which feeds
      ownership liveness. An unreachable core changes nothing: unknown never
      counts as finished.

  Every 60 s it sweeps the dispatched and ready packages:
    * one batched GraphQL snapshot covers every watched PR, plus branch
      discovery for packages without a PR (`GitHub.Snapshot`);
    * the Review Suite cycle is read by `review_id` on the worker's machine
      (`ReviewStatus`);
    * a PR found on the package's branch is attached; a changed PR snapshot is
      recorded; a merge is recorded as `pr_merged` through the delivery
      evidence path; otherwise the package qualifies or unqualifies through
      `Qualification`;
    * where two or more watched PRs are open in one repository, their commit
      lists are read (one batched GraphQL read, again only when a PR's head or
      base moves), and a PR stacked on another package's unmerged work
      (`Stacking`) doesn't qualify;
    * the same snapshot reads the PRs of cards (`Cards`), the work of the
      terminals the operator talks to.

  An input that can't be read (GitHub, the review host, or another PR the
  stacking check needs) flags the package `stale` and changes nothing else.
  The last snapshot per package is stored (`Observation`), so a restart
  doesn't replay transitions. Merged and closed PRs are no longer watched.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, Cards, DashboardPubSub, HerdrCore, Ownership}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, DryClient, MergeReconciler, PullRequest, PullRequestProgress}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{RateGovernor, Snapshot}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope
  alias SymphonyElixir.SymphonyPlusPlus.Observer.Observation
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.{RepoIdentity, ReviewStatus}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, Qualification, Stacking, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @terminal_interval_ms 15_000
  @sweep_interval_ms 60_000
  @review_concurrency 4
  @review_timeout_ms 8_000

  # The PR fields whose change is recorded as a new snapshot.
  @snapshot_fields ~w(state draft merged merged_at merge_commit_sha head_sha branch base_branch ci github_review)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    RateGovernor.create_table()
    Api.create_table()
    Process.send_after(self(), :terminals, 1_000)
    Process.send_after(self(), :sweep, 5_000)
    {:ok, %{repo: Keyword.fetch!(opts, :repo)}}
  end

  @impl true
  def handle_info(:terminals, state) do
    safely(fn -> observe_terminals(state.repo) end)
    Process.send_after(self(), :terminals, @terminal_interval_ms)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    safely(fn -> sweep(state.repo) end)
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  # A failed pass is retried on the next tick; the Observer keeps running.
  defp safely(fun) do
    fun.()
  rescue
    error -> Logger.warning("sympp observer pass failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("sympp observer pass failed: #{inspect(reason)}")
  end

  @doc "Stored observations of these packages, by package id."
  @spec observations(module(), [String.t()]) :: %{String.t() => Observation.t()}
  def observations(_repo, []), do: %{}

  def observations(repo, work_package_ids) do
    work_package_ids
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(&repo.all(from(observation in Observation, where: observation.work_package_id in ^&1)))
    |> Map.new(&{&1.work_package_id, &1})
  end

  @doc """
  One terminal pass: reads the factory's core (or uses `snapshot`) and applies
  what it reports to worked-on rows. An unreachable core changes nothing.
  """
  @spec observe_terminals(module(), {:ok, map()} | :unavailable | nil) :: :ok
  def observe_terminals(repo, snapshot \\ nil) do
    # Only rows that started before the snapshot was read can be judged by it.
    read_at = DateTime.utc_now(:microsecond)

    case snapshot || HerdrCore.refresh() do
      {:ok, %{core_id: core_id, terminals: terminals} = core} ->
        Ownership.observe_core(repo, core_id, Map.get(core, :core_name), terminals, in_flight_ids(repo), read_at)

      _unavailable ->
        :ok
    end
  end

  defp in_flight_ids(repo) do
    repo.all(from(package in WorkPackage, where: package.status in ^Lifecycle.in_flight_statuses(), select: package.id))
  end

  @doc """
  One sweep of every dispatched and ready package, and of cards. Options
  (tests): `:snapshot` replaces `GitHub.Snapshot.fetch/2`, `:failing_checks`
  replaces `GitHub.Snapshot.failing_checks/3`, `:commits` replaces
  `GitHub.Snapshot.commits/2`, `:review` replaces `ReviewStatus.read/2`;
  `Cards.watch/2` takes its own.
  """
  @spec sweep(module(), keyword()) :: :ok
  def sweep(repo, opts \\ []) do
    watched = watched_packages(repo)
    observations = observations(repo, Enum.map(watched, & &1.package.id))
    watched = Enum.map(watched, &Map.put(&1, :observation, Map.get(observations, &1.package.id)))
    cards = guarded(fn -> Cards.watch(repo, opts) end, [])

    watched = Enum.map(watched, &Map.put(&1, :entry, github_entry(&1)))
    {github, results} = github_results(watched, Enum.map(cards, & &1.entry), opts)
    github = with_commits(watched, github, opts)
    reviews = review_results(Enum.map(watched, & &1.package), opts)

    watched =
      Enum.map(watched, fn item ->
        result = Map.get(github, item.package.id, {:error, :not_watched})
        fresh? = match?({:ok, %{}}, result) and usable?(item.package, item.attached, elem(result, 1))
        Map.merge(item, %{github: result, fresh?: fresh?, pr: current_pr(item, result, item.observation && item.observation.pr, opts)})
      end)

    views = Enum.flat_map(watched, &view/1)
    Enum.each(watched, &observe_package(repo, &1, Map.get(reviews, &1.package.id, :none), views))

    guarded(fn -> Cards.apply(repo, cards, results, opts) end, :ok)
  end

  # Cards never stop the package sweep.
  defp guarded(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.warning("sympp observer card pass failed: #{Exception.message(error)}")
      fallback
  end

  defp watched_packages(repo) do
    repo.all(
      from(package in WorkPackage,
        join: request in WorkRequest,
        on: request.id == package.work_request_id,
        where: package.status in ^Lifecycle.in_flight_statuses() and is_nil(request.archived_at),
        order_by: [asc: package.id]
      )
    )
    |> Enum.map(fn package -> %{package: package, attached: attached_pr(repo, package)} end)
  end

  defp attached_pr(repo, %WorkPackage{} = package) do
    with {:ok, state} <- PlanningRepository.get_state(repo, package.id),
         {:ok, current} <- PullRequestProgress.current_pr_state(state.progress_events) do
      # The attaching event's sequence tells a newer `sync_pr` of the same PR
      # apart; who wrote it tells whether the architect has synced it since.
      by_observer? = Enum.any?(state.progress_events, &(&1.sequence == current.sequence and &1.actor_id == Actor.observer().id))
      current.ref |> Map.put(:sequence, current.sequence) |> Map.put(:by_observer?, by_observer?)
    else
      _missing -> nil
    end
  end

  # What GitHub entry each package needs: its attached PR, or its branch.
  defp github_entry(%{attached: %{owner: owner, repo: repo, number: number} = ref, observation: observation}) do
    if closed?(observation, ref), do: :skip, else: {:pr, owner, repo, number}
  end

  defp github_entry(%{package: package}) do
    with {:ok, {owner, repo}} <- repository(package),
         {:ok, branch} <- branch(package),
         base when is_binary(base) <- BaseBranch.canonicalize(package.base_branch) do
      {:branch, owner, repo, branch, base}
    else
      _unknown -> :skip
    end
  end

  # A closed PR is no longer watched, until the architect syncs it again (it
  # may have been reopened) or `sync_pr` attaches another one.
  defp closed?(%Observation{pr: %{"state" => "closed", "number" => number, "repository" => repository}}, %{by_observer?: true} = ref),
    do: number == ref.number and String.downcase(repository) == String.downcase(ref.repository)

  defp closed?(_observation, _ref), do: false

  # Package and card entries share one batched snapshot. Returns each
  # package's result and the results by entry.
  defp github_results(watched, card_entries, opts) do
    entries = Map.new(watched, &{&1.package.id, &1.entry})
    wanted = (Map.values(entries) ++ card_entries) |> Enum.reject(&(&1 == :skip)) |> Enum.uniq()

    results =
      cond do
        wanted == [] -> %{}
        opts[:snapshot] -> opts[:snapshot].(wanted)
        true -> fetch_snapshot(wanted)
      end

    packages =
      Map.new(entries, fn
        {id, :skip} -> {id, :skip}
        {id, entry} -> {id, Map.get(results, entry, {:error, :request_failed})}
      end)

    {packages, results}
  end

  defp fetch_snapshot(entries) do
    case Api.credential() do
      {:ok, _token} -> Snapshot.fetch(entries)
      {:error, reason} -> Map.new(entries, &{&1, {:error, reason}})
    end
  end

  # Each package's review read, by id: `:none` for packages that review in mode
  # `none`; a read that times out is `:unknown`.
  defp review_results(packages, opts) do
    read = Keyword.get(opts, :review, &ReviewStatus.read/2)
    {reviewed, unreviewed} = Enum.split_with(packages, &reviewed?/1)

    results =
      reviewed
      |> Task.async_stream(fn package -> {package.id, read.(package.review_id, package.launch_machine)} end,
        max_concurrency: @review_concurrency,
        ordered: false,
        timeout: @review_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _reason} -> []
      end)
      |> Map.new()

    Map.new(reviewed, &{&1.id, Map.get(results, &1.id, :unknown)})
    |> Map.merge(Map.new(unreviewed, &{&1.id, :none}))
  end

  defp reviewed?(%WorkPackage{review_mode: mode, review_id: id}), do: mode in ["fast", "normal", "deep"] and is_binary(id)

  defp observe_package(repo, %{package: package, observation: observation, github: github, pr: pr} = item, review, views) do
    previous_pr = observation && observation.pr
    changed? = match?({:ok, %{}}, github) and pr != previous_pr and snapshot_changed?(previous_pr, pr)
    stacked_on = stacking(item, views)
    stale = stale(github, review, stacked_on)

    # A stale GitHub read changes nothing; a stale review host or stacking
    # input only blocks qualifying.
    outcome = if "github" in stale, do: :ok, else: act(repo, item, pr, changed?, review, stacked_on)
    stored_pr = if outcome == :retry, do: previous_pr, else: pr
    stored_stacking = if is_list(stacked_on), do: stacked_on, else: (observation && observation.stacked_on) || []

    store(repo, package.id, observation, %{pr: stored_pr, review: review_payload(review, observation), stale: stale, stacked_on: stored_stacking})
  end

  # What this sweep read of each watched package's current PR. A PR that
  # couldn't be read is unknown; a closed PR no longer watched, or none, is left out.
  defp view(%{package: package, fresh?: true, pr: pr}),
    do: [%{work_package_id: package.id, repository: pr["repository"], number: pr["number"], state: pr["state"], commits: pr["commits"], fresh?: true}]

  defp view(%{package: package, github: {:error, _reason}, attached: %{} = attached}),
    do: [%{work_package_id: package.id, repository: attached.repository, number: attached.number, state: nil, commits: nil, fresh?: true}]

  # A branch whose PR lookup failed may hide an open PR.
  defp view(%{package: package, github: {:error, _reason}, entry: {:branch, owner, repo, _branch, _base}}),
    do: [%{work_package_id: package.id, repository: "#{owner}/#{repo}", number: nil, state: nil, commits: nil, fresh?: true}]

  defp view(_item), do: []

  # The packages an open PR read in this sweep is stacked on, or `:unknown`;
  # every view is this sweep's read.
  defp stacking(%{package: package, fresh?: true, pr: %{"state" => "open"} = pr}, views) do
    case Stacking.check(%{work_package_id: package.id, repository: pr["repository"], number: pr["number"], commits: pr["commits"]}, views) do
      {:ok, ids} -> ids
      :unknown -> :unknown
    end
  end

  defp stacking(_item, _views), do: []

  # Commit lists are read only where the stacking check needs them (a
  # repository with two or more open watched PRs) and only when a PR's head or
  # base moved; otherwise the last list is kept.
  defp with_commits(watched, github, opts) do
    open = for item <- watched, {:ok, %{"state" => "open"} = pr} <- [Map.get(github, item.package.id)], do: {item, pr}
    shared = open |> Enum.frequencies_by(fn {_item, pr} -> String.downcase(pr["repository"] || "") end) |> Enum.filter(&(elem(&1, 1) > 1)) |> Map.new()
    {kept, wanted} = open |> Enum.map(fn {item, pr} -> {item.package.id, carry_commits(pr, item.observation)} end) |> Enum.split_with(fn {_id, pr} -> is_list(pr["commits"]) end)
    wanted = Enum.filter(wanted, fn {_id, pr} -> Map.has_key?(shared, String.downcase(pr["repository"] || "")) end)
    read = Keyword.get(opts, :commits, &Snapshot.commits/1)
    lists = if wanted == [], do: %{}, else: read.(Enum.map(wanted, fn {_id, pr} -> commits_entry(pr) end))

    read_prs =
      Map.new(wanted, fn {id, pr} ->
        head = pr["head_sha"]

        case Map.get(lists, commits_entry(pr)) do
          {:ok, %{"head_sha" => ^head, "base_sha" => base, "commits" => commits}} -> {id, {:ok, Map.merge(pr, %{"base_sha" => base, "commits" => commits})}}
          _unreadable_or_moved -> {id, {:ok, pr}}
        end
      end)

    github |> Map.merge(Map.new(kept, fn {id, pr} -> {id, {:ok, pr}} end)) |> Map.merge(read_prs)
  end

  defp carry_commits(pr, %Observation{pr: %{"commits" => commits} = previous}) when is_list(commits) do
    same? = Enum.all?(~w(repository number head_sha base_sha), &(previous[&1] == pr[&1]))
    if same?, do: Map.put(pr, "commits", commits), else: pr
  end

  defp carry_commits(pr, _observation), do: pr

  defp commits_entry(pr) do
    [owner, name] = String.split(pr["repository"], "/", parts: 2)
    {owner, name, pr["number"]}
  end

  defp current_pr(%{package: package, attached: attached}, {:ok, %{} = pr}, previous_pr, opts) do
    if usable?(package, attached, pr), do: with_failing_checks(pr, previous_pr, opts), else: previous_pr
  end

  defp current_pr(_item, _unknown_or_missing, previous_pr, _opts), do: previous_pr

  # Unknown inputs only flag the package; a stale GitHub read changes nothing.
  defp stale(github, review, stacked_on) do
    github_stale = match?({:error, _reason}, github)
    review_stale = review == :unknown
    stacking_stale = stacked_on == :unknown

    Enum.flat_map([{github_stale, "github"}, {review_stale, "review"}, {stacking_stale, "stacking"}], fn
      {true, source} -> [source]
      {false, _source} -> []
    end)
  end

  # A discovered PR is used only if it targets the package's repository and base.
  defp usable?(_package, %{} = _attached, _pr), do: true

  defp usable?(%WorkPackage{} = package, nil, pr) do
    RepoIdentity.scope_match?(package.repo, pr["repository"], local_path_remotes?: true) and
      BaseBranch.canonicalize(package.base_branch) == BaseBranch.canonicalize(pr["base_branch"])
  end

  # Failing check names are a detail read, made only when a head turns failing.
  defp with_failing_checks(%{"ci" => %{"status" => "failing"}} = pr, previous, opts) do
    if get_in(previous || %{}, ["ci", "status"]) == "failing" and previous["head_sha"] == pr["head_sha"] do
      put_in(pr, ["ci", "failing"], get_in(previous, ["ci", "failing"]))
    else
      read = Keyword.get(opts, :failing_checks, &Snapshot.failing_checks/2)

      case read.(pr["repository"], pr["head_sha"]) do
        {:ok, names} -> put_in(pr, ["ci", "failing"], names)
        {:error, _reason} -> pr
      end
    end
  end

  defp with_failing_checks(pr, _previous, _opts), do: pr

  defp snapshot_changed?(nil, %{}), do: true
  defp snapshot_changed?(previous, pr), do: Map.take(previous, @snapshot_fields) != Map.take(pr, @snapshot_fields) or previous["number"] != pr["number"]

  # Returns `:ok` once the snapshot's effects are applied, or `:retry` when they
  # weren't: the previous snapshot is then kept, so the next sweep sees the
  # change again and retries it.
  defp act(_repo, _item, nil, _changed?, _review, _stacked_on), do: :ok

  defp act(repo, %{package: %WorkPackage{} = package, attached: attached}, %{} = pr, changed?, review, stacked_on) do
    with :ok <- same_attachment(attached_pr(repo, package), attached),
         {:ok, payload} <- payload(pr) do
      work = fn -> record_and_qualify(repo, package, attached, payload, changed?, pr, review, stacked_on) end
      # A PR merged into another base doesn't deliver this package: it unqualifies instead.
      merged? = pr["merged"] == true and base_matches?(package, pr)
      if merged?, do: merge(repo, package, attached, payload, changed?), else: in_transaction(repo, package, work)
    else
      {:error, reason} -> retry(package, reason)
    end
  end

  # The merge itself goes through the delivery evidence path; a failed merge
  # record is retried on every sweep while the PR stays watched.
  defp merge(repo, package, attached, payload, true = _changed?) do
    case in_transaction(repo, package, fn -> record(repo, package, attached, payload) end) do
      :ok -> record_merge(repo, package, payload)
      :retry -> :retry
    end
  end

  defp merge(repo, package, _attached, payload, false = _changed?), do: record_merge(repo, package, payload)

  # Recording a new head and the qualification it causes commit together.
  defp record_and_qualify(repo, package, attached, payload, changed?, pr, review, stacked_on) do
    with {:ok, current} <- fetch(repo, package),
         :ok <- if(changed?, do: record(repo, current, attached, payload), else: :ok),
         {:ok, decision} <- Qualification.decide(repo, current, facts(current, pr, review, stacked_on)),
         {:ok, _updated} <- Qualification.apply_decision(repo, Actor.observer(), current, decision, pr["head_sha"]) do
      :ok
    end
  end

  # The PR is recorded only if the package's PR record is still the one the
  # sweep read: an architect may have synced that PR or attached another one.
  defp record(repo, package, attached, payload) do
    with :ok <- same_attachment(attached_pr(repo, package), attached),
         do: Qualification.record_pr(repo, Actor.observer(), package, payload)
  end

  # `work` runs inside the transaction; an `{:error, _}` result rolls it back.
  defp in_transaction(repo, package, work) do
    case repo.transaction(fn -> rollback_on_error(repo, work.()) end) do
      {:ok, :ok} ->
        DashboardPubSub.broadcast_changed()
        :ok

      {:error, reason} ->
        retry(package, reason)
    end
  end

  defp rollback_on_error(repo, {:error, reason}), do: repo.rollback(reason)
  defp rollback_on_error(_repo, result), do: result

  defp same_attachment(nil, nil), do: :ok

  defp same_attachment(%{repository: repository, number: number, sequence: sequence}, %{repository: repository, number: number, sequence: sequence}),
    do: :ok

  defp same_attachment(_current, _read), do: {:error, :pr_replaced}

  defp record_merge(repo, %WorkPackage{} = package, payload) do
    case MergeReconciler.reconcile_work_package(repo, package.id, client: DryClient, metadata: payload) do
      {:ok, %{status: status}} when status in ["merged", "already_merged"] -> :ok
      {:ok, result} -> log_failure(package, Map.get(result, :delivery_error) || Map.get(result, :reason))
      {:error, reason} -> log_failure(package, reason)
    end
  end

  defp facts(%WorkPackage{} = package, pr, review, stacked_on) do
    %{
      pr_state: pr["state"],
      pr_draft?: pr["draft"] == true,
      ci_status: get_in(pr, ["ci", "status"]),
      review: if(review == :unknown, do: :unknown, else: review_state(review, pr["head_sha"])),
      head_sha: pr["head_sha"],
      base_matches?: base_matches?(package, pr),
      stacked_on: stacked_on
    }
  end

  # A PR retargeted to another base no longer delivers this package.
  defp base_matches?(_package, %{"base_branch" => nil}), do: true
  defp base_matches?(package, %{"base_branch" => base}), do: BaseBranch.canonicalize(package.base_branch) == BaseBranch.canonicalize(base)
  defp base_matches?(_package, _pr), do: true

  defp review_state(:none, _head), do: :none
  defp review_state(review, head), do: ReviewStatus.state(review, head)

  defp fetch(repo, %WorkPackage{id: id}) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{} = package -> if Lifecycle.in_flight?(package), do: {:ok, package}, else: {:error, :not_in_flight}
      nil -> {:error, :not_found}
    end
  end

  # The PR snapshot in the payload shape `sync_pr` records.
  defp payload(pr) do
    with {:ok, ref} <- PullRequest.parse(%{"url" => pr["url"]}, nil) do
      ci = pr["ci"] || %{}

      metadata =
        %{
          "html_url" => pr["url"],
          "number" => pr["number"],
          "repository" => pr["repository"],
          "head" => %{"sha" => pr["head_sha"], "ref" => pr["branch"]},
          "base" => %{"ref" => pr["base_branch"]},
          "state" => pr["state"],
          "draft" => pr["draft"],
          "merged" => pr["merged"],
          "merged_at" => pr["merged_at"],
          "merge_commit_sha" => pr["merge_commit_sha"],
          "check_summary" =>
            Map.take(%{"status" => ci["status"], "current" => ci["completed"], "total" => ci["total"]}, ["status", "current", "total"]) |> Map.reject(fn {_key, value} -> is_nil(value) end),
          "observed_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        }

      PullRequest.metadata(metadata, ref, nil)
    end
  end

  defp review_payload({:ok, review}, _observation), do: review
  defp review_payload(:not_started, _observation), do: %{"status" => "not_started"}
  defp review_payload(:none, _observation), do: nil
  # An unreachable host keeps the last review it reported.
  defp review_payload(:unknown, observation), do: observation && observation.review

  defp store(repo, work_package_id, observation, attrs) do
    attrs = Map.put(attrs, :observed_at, DateTime.utc_now(:microsecond))
    fields = [:pr, :review, :stale, :stacked_on]
    changed? = is_nil(observation) or Map.take(observation, fields) != Map.take(attrs, fields)

    (observation || %Observation{work_package_id: work_package_id})
    |> Ecto.Changeset.change(attrs)
    |> repo.insert_or_update()
    |> case do
      {:ok, _stored} -> if changed?, do: DashboardPubSub.broadcast_changed()
      {:error, reason} -> log_failure(%WorkPackage{id: work_package_id}, reason)
    end

    :ok
  end

  defp repository(%WorkPackage{repo: repo} = package) do
    [repo, RepoIdentity.local_git_origin_remote(repo), RepoIdentity.local_git_origin_remote(package.worktree_path)]
    |> Enum.find_value({:error, :unknown_repository}, &RepoIdentity.github_repository/1)
  end

  defp branch(%WorkPackage{worktree_path: path} = package) do
    case WorktreeScope.live_branch(path) do
      {:ok, branch} -> {:ok, branch}
      {:error, _missing} -> WorktreeScope.prepare_branch(package)
    end
  end

  defp log_failure(%WorkPackage{id: id}, reason) do
    Logger.warning("sympp observer could not apply #{id}: #{inspect(reason)}")
    :ok
  end

  defp retry(%WorkPackage{id: id}, reason) do
    Logger.warning("sympp observer will retry #{id}: #{inspect(reason)}")
    :retry
  end
end
