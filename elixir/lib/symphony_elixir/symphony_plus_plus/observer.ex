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
      (`ReviewStatus`). A branch confirmed to have no PR only needs a
      review read when a consumer is using its progress;
    * a PR found on the package's branch is attached; a changed PR snapshot is
      recorded; a merge is recorded as `pr_merged` through the delivery
      evidence path; otherwise the package qualifies or unqualifies through
      `Qualification`;
    * where two or more watched PRs are open in one repository, their complete
      commit lists are read and reused until the head or base moves. Pairs with
      incomplete lists use cached ancestry comparisons (`Stacking`);
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

  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, Cards, DashboardPubSub, HerdrCore, OfflineSandbox, Ownership}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Api, DryClient, MergeReconciler, PullRequest}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{RateGovernor, Snapshot}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope
  alias SymphonyElixir.SymphonyPlusPlus.Observer.{Observation, ReviewRefresh}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.{Repo, RepoIdentity, ReviewStatus}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{Lifecycle, Qualification, Stacking, WorkPackage}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @terminal_interval_ms 15_000
  @sweep_interval_ms 60_000
  @review_concurrency 4
  @review_timeout_ms ReviewStatus.timeout_ms() + 1_000
  @type review_scope :: :all | {:request, String.t()} | {:package, String.t(), String.t()}
  @type review_candidate :: {WorkPackage.t(), Observation.t()}
  @type display_review :: {{String.t(), String.t() | nil}, [Observation.t()]}

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
    ReviewRefresh.advance()
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  @doc "Selects the packages in scope whose branches have no PR."
  @spec pre_pr_review_candidates(module(), review_scope()) :: [review_candidate()]
  def pre_pr_review_candidates(repo, scope) do
    safely(fn -> review_candidates_in_scope(repo, scope) end, [])
  end

  @doc "Refreshes review progress for the selected pre-PR packages."
  @spec refresh_review_progress(module(), [review_candidate()]) :: :ok
  def refresh_review_progress(repo, candidates) do
    unless OfflineSandbox.enabled?(), do: safely(fn -> read_pre_pr_reviews(repo, candidates) end)
    :ok
  end

  @doc false
  @spec display_reviews(module(), [review_candidate()]) :: [display_review()]
  def display_reviews(_repo, []), do: []

  def display_reviews(repo, candidates) do
    safely(fn -> display_review_jobs(repo, candidates) end, [])
  end

  defp display_review_jobs(repo, candidates) do
    observations = Map.new(candidates, fn {package, observation} -> {package.id, observation} end)
    packages = Enum.map(candidates, &elem(&1, 0))

    for {cycle, ids} <- review_groups(repo, packages, []) do
      {cycle, Enum.map(ids, &Map.fetch!(observations, &1))}
    end
  end

  @doc false
  @spec record_display_review(module(), [Observation.t()], ReviewStatus.result()) :: :ok
  def record_display_review(repo, observations, result) do
    safely(fn -> publish_review_progress(repo, observations, result) end)
    :ok
  end

  # A failed pass is retried on the next tick; the Observer keeps running.
  defp safely(fun, fallback \\ :ok) do
    fun.()
  rescue
    error ->
      Logger.warning("sympp observer pass failed: #{Exception.message(error)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("sympp observer pass failed: #{inspect(reason)}")
      fallback
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
  `GitHub.Snapshot.commits/2`, `:review` replaces `ReviewStatus.read/2`.
  `:core` replaces `HerdrCore.current/0` for reviews and cards.
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

    watched =
      Enum.map(watched, fn item ->
        result = Map.get(github, item.package.id, {:error, :not_watched})
        fresh? = match?({:ok, %{}}, result) and usable?(item.package, item.attached, elem(result, 1))
        Map.merge(item, %{github: result, fresh?: fresh?, pr: current_pr(item, result, item.observation && item.observation.pr, opts)})
      end)

    to_read = for %{package: package} = item <- watched, reviewed?(package) and not pre_pr?(item), do: package
    reviews = review_results(repo, to_read, opts)
    views = Enum.flat_map(watched, &view/1)

    {result, _changed?} =
      DashboardPubSub.coalesce_changed(fn ->
        Enum.each(watched, &observe_package(repo, &1, package_review(&1.package, reviews), views))
        guarded(fn -> Cards.apply(repo, cards, results, opts) end, :ok)
      end)

    result
  end

  # Only successful branch discovery can establish absence. A missing result
  # for an attached PR or a provider failure keeps its usual review read.
  defp pre_pr?(%{entry: {:branch, _, _, _, _}, github: {:ok, nil}, pr: nil, package: package}), do: reviewed?(package)
  defp pre_pr?(_item), do: false

  defp package_review(package, reviews) do
    default = if reviewed?(package), do: :deferred, else: :none
    Map.get(reviews, package.id, default)
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
    packages =
      repo.all(
        from(package in WorkPackage,
          join: request in WorkRequest,
          on: request.id == package.work_request_id,
          where: package.status in ^Lifecycle.in_flight_statuses() and is_nil(request.archived_at),
          order_by: [asc: package.id]
        )
      )

    {:ok, attachments} = PlanningRepository.pr_attachments(repo, Enum.map(packages, & &1.id))
    Enum.map(packages, fn package -> %{package: package, attached: attached_pr(attachments[package.id])} end)
  end

  defp attached_pr({:ok, attachment}) do
    # The sequence distinguishes another sync of the same PR, and the actor
    # distinguishes an architect's sync from the observer's last snapshot.
    Map.merge(attachment.ref, %{sequence: attachment.sequence, by_observer?: attachment.actor_id == Actor.observer().id})
  end

  defp attached_pr(_missing_or_invalid), do: nil

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

  defp review_results(_repo, [], _opts), do: %{}

  defp review_results(Repo, packages, []) do
    if Process.whereis(ReviewRefresh) do
      Repo |> review_groups(packages, []) |> ReviewRefresh.sweep() |> reviews_by_package()
    else
      Repo |> review_reads(packages, []) |> reviews_by_package()
    end
  end

  defp review_results(repo, packages, opts), do: repo |> review_reads(packages, opts) |> reviews_by_package()

  defp reviews_by_package(reads) do
    reads
    |> Enum.flat_map(fn {ids, result} -> Enum.map(ids, &{&1, result}) end)
    |> Map.new()
  end

  # Share a cycle read among packages on the same route. A timeout is unknown.
  defp review_reads(_repo, [], _opts), do: []

  defp review_reads(repo, packages, opts) do
    read = Keyword.get(opts, :review, &ReviewStatus.read/2)

    repo
    |> review_groups(packages, opts)
    |> Task.async_stream(fn {{review_id, route}, ids} -> {ids, read.(review_id, route)} end,
      max_concurrency: @review_concurrency,
      ordered: false,
      timeout: @review_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.map(fn
      {:ok, result} -> result
      {:exit, {{_cycle, ids}, _reason}} -> {ids, :unknown}
    end)
  end

  defp review_groups(repo, packages, opts) do
    workers = Ownership.workers(repo, Enum.map(packages, & &1.id))
    core = Keyword.get_lazy(opts, :core, &HerdrCore.current/0)

    Enum.group_by(
      packages,
      fn package ->
        route = Qualification.review_route(package.launch_machine, workers[package.id], core)
        {package.review_id, route}
      end,
      & &1.id
    )
  end

  defp reviewed?(%WorkPackage{review_mode: mode, review_id: id}), do: mode in ["fast", "normal", "deep"] and is_binary(id)

  defp review_candidates_in_scope(repo, scope) do
    candidates = repo.all(pre_pr_review_query(scope))
    package_ids = for {package, _observation} <- candidates, do: package.id
    {:ok, attachments} = PlanningRepository.pr_attachments(repo, package_ids)

    Enum.filter(candidates, fn {package, _observation} ->
      reviewed?(package) and is_nil(attached_pr(attachments[package.id]))
    end)
  end

  defp read_pre_pr_reviews(repo, candidates) do
    observations = Map.new(candidates, fn {package, observation} -> {package.id, observation} end)
    packages = Enum.map(candidates, &elem(&1, 0))

    # An unrelated slow worker must not hold up progress for this reader.
    Enum.each(review_reads(repo, packages, []), fn {ids, review} ->
      publish_review_progress(repo, Enum.map(ids, &Map.fetch!(observations, &1)), review)
    end)
  end

  defp publish_review_progress(repo, observations, review) do
    DashboardPubSub.coalesce_changed(fn ->
      Enum.each(observations, &store_review_progress(repo, &1, review))
    end)
  end

  defp pre_pr_review_query(scope) do
    from(package in WorkPackage,
      join: request in WorkRequest,
      on: request.id == package.work_request_id,
      join: observation in Observation,
      on: observation.work_package_id == package.id,
      where: package.status in ^Lifecycle.in_flight_statuses() and is_nil(request.archived_at) and observation.pr_absent,
      select: {package, observation}
    )
    |> scope_review_query(scope)
  end

  defp scope_review_query(query, :all), do: query
  defp scope_review_query(query, {:request, id}), do: from(package in query, where: package.work_request_id == ^id)

  defp scope_review_query(query, {:package, request_id, id}),
    do: from(package in query, where: package.id == ^id and package.work_request_id == ^request_id)

  defp store_review_progress(repo, observation, review) do
    attrs = Observation.review_attributes(observation, review)

    if Ecto.Changeset.change(observation, attrs).changes != %{} do
      # A one-shot reader can run in another VM. A newer sweep owns its PR
      # and review evidence, so only update the observation that was read.
      query =
        from(current in Observation,
          where: current.work_package_id == ^observation.work_package_id,
          where: current.updated_at == ^observation.updated_at and current.pr_absent
        )

      now = DateTime.utc_now(:microsecond)
      {count, _} = repo.update_all(query, set: Map.to_list(Map.put(attrs, :updated_at, now)))
      if count > 0, do: DashboardPubSub.broadcast_changed()
    end
  end

  defp observe_package(repo, %{package: package, observation: observation, github: github, pr: pr} = item, review, views) do
    previous_pr = observation && observation.pr
    changed? = match?({:ok, %{}}, github) and pr != previous_pr and snapshot_changed?(previous_pr, pr)
    stacked_on = stacking(item, views)
    stale = stale(github, review, stacked_on, observation)

    # A stale GitHub read changes nothing; a stale review host or stacking
    # input only blocks qualifying.
    outcome = if "github" in stale, do: :ok, else: act(repo, item, pr, changed?, review, stacked_on)
    stored_pr = if outcome == :retry, do: previous_pr, else: pr
    stored_stacking = if is_list(stacked_on), do: stacked_on, else: (observation && observation.stacked_on) || []

    attrs = %{
      pr: stored_pr,
      pr_absent: pre_pr?(item),
      review: Observation.review_payload(review, observation),
      stale: stale,
      stacked_on: stored_stacking
    }

    store(repo, package.id, observation, attrs, review)
  end

  # What this sweep read of each watched package's current PR. A PR that
  # couldn't be read is unknown; a closed PR no longer watched, or none, is left out.
  defp view(%{package: package, fresh?: true, pr: pr}), do: [stack_view(package, pr)]

  defp view(%{package: package, github: {:error, _reason}, attached: %{} = attached}),
    do: [%{work_package_id: package.id, repository: attached.repository, number: attached.number, state: nil, commits: nil, fresh?: true}]

  # A branch whose PR lookup failed may hide an open PR.
  defp view(%{package: package, github: {:error, _reason}, entry: {:branch, owner, repo, _branch, _base}}),
    do: [%{work_package_id: package.id, repository: "#{owner}/#{repo}", number: nil, state: nil, commits: nil, fresh?: true}]

  defp view(_item), do: []

  defp stack_view(package, pr) do
    %{
      work_package_id: package.id,
      repository: pr["repository"],
      number: pr["number"],
      state: pr["state"],
      head_sha: pr["head_sha"],
      base_tip_sha: pr["base_tip_sha"],
      commits: pr["commits"],
      fresh?: true
    }
  end

  # The packages an open PR read in this sweep is stacked on, or `:unknown`;
  # every view is this sweep's read.
  defp stacking(%{package: package, fresh?: true, pr: %{"state" => "open"} = pr}, views) do
    case Stacking.check(stack_view(package, pr), views) do
      {:ok, ids} -> ids
      :unknown -> :unknown
    end
  end

  defp stacking(_item, _views), do: []

  # Commit lists are read only where the stacking check needs them (a
  # repository with two or more open watched PRs), when GitHub can return a full
  # list and the head or base moved. Otherwise reuse the last complete list.
  defp with_commits(watched, github, opts) do
    open = for item <- watched, {:ok, %{"state" => "open"} = pr} <- [Map.get(github, item.package.id)], do: {item, pr}
    shared = open |> Enum.frequencies_by(fn {_item, pr} -> String.downcase(pr["repository"] || "") end) |> Enum.filter(&(elem(&1, 1) > 1)) |> Map.new()
    {kept, wanted} = open |> Enum.map(fn {item, pr} -> {item.package.id, carry_commits(pr, item.observation)} end) |> Enum.split_with(fn {_id, pr} -> is_list(pr["commits"]) end)
    wanted = Enum.filter(wanted, fn {_id, pr} -> Snapshot.commit_list_available?(pr) and Map.has_key?(shared, String.downcase(pr["repository"] || "")) end)
    read = Keyword.get(opts, :commits, &Snapshot.commits/1)
    lists = if wanted == [], do: %{}, else: read.(Enum.map(wanted, fn {_id, pr} -> commits_entry(pr) end))

    read_prs =
      Map.new(wanted, fn {id, pr} ->
        head = pr["head_sha"]
        base = pr["base_sha"]
        base_tip = pr["base_tip_sha"]

        case Map.get(lists, commits_entry(pr)) do
          {:ok, %{"head_sha" => ^head, "base_sha" => ^base, "base_tip_sha" => ^base_tip, "commits" => commits}} -> {id, {:ok, Map.put(pr, "commits", commits)}}
          _unreadable_or_moved -> {id, {:ok, pr}}
        end
      end)

    github |> Map.merge(Map.new(kept, fn {id, pr} -> {id, {:ok, pr}} end)) |> Map.merge(read_prs)
  end

  defp carry_commits(pr, %Observation{pr: %{"commits" => commits} = previous}) when is_list(commits) do
    same? = Enum.all?(~w(repository number head_sha base_sha base_tip_sha), &(previous[&1] == pr[&1]))
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
  defp stale(github, review, stacked_on, observation) do
    github_stale = match?({:error, _reason}, github)
    review_stale = review == :unknown or (review == :deferred and "review" in ((observation && observation.stale) || []))
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
    # Only a PR merged into the package's base delivers it.
    merged? = pr["merged"] == true and base_matches?(package, pr)

    with {:ok, payload} <- payload(pr),
         :ok <- if(merged?, do: check_attachment(repo, package.id, attached), else: :ok) do
      work = fn -> record_and_qualify(repo, package, attached, payload, changed?, pr, review, stacked_on) end
      if merged?, do: merge(repo, package, attached, payload, changed?), else: in_transaction(repo, package, work)
    else
      {:error, reason} -> retry(package, reason)
    end
  end

  # The merge itself goes through the delivery evidence path; a failed merge
  # record is retried on every sweep while the PR stays watched.
  defp merge(repo, package, attached, payload, true = _changed?) do
    work = fn ->
      with {:ok, current} <- fetch(repo, package),
           :ok <- record(repo, current, attached, payload),
           do: {:ok, true}
    end

    case in_transaction(repo, package, work) do
      :ok -> record_merge(repo, package, payload)
      :retry -> :retry
    end
  end

  defp merge(repo, package, _attached, payload, false = _changed?), do: record_merge(repo, package, payload)

  # Recording a new head and the qualification it causes commit together: the
  # candidate head is read before the new snapshot is recorded.
  defp record_and_qualify(repo, package, attached, payload, changed?, pr, review, stacked_on) do
    with :ok <- check_attachment(repo, package.id, attached),
         {:ok, current} <- fetch(repo, package),
         {:ok, candidate_head} <- Qualification.candidate_head(repo, current),
         :ok <- if(changed?, do: Qualification.record_pr(repo, Actor.observer(), current, payload), else: :ok),
         {:ok, decision} <- Qualification.decide(repo, current, facts(current, pr, review, stacked_on), candidate_head),
         {:ok, updated} <- Qualification.apply_decision(repo, Actor.observer(), current, decision, pr["head_sha"]) do
      {:ok, changed? or updated.status != current.status}
    end
  end

  # The PR is recorded only if the package's PR record is still the one the
  # sweep read: an architect may have synced that PR or attached another one.
  defp record(repo, package, attached, payload) do
    with :ok <- check_attachment(repo, package.id, attached),
         do: Qualification.record_pr(repo, Actor.observer(), package, payload)
  end

  defp check_attachment(repo, package_id, attached) do
    with {:ok, attachments} <- PlanningRepository.pr_attachments(repo, [package_id]) do
      same_attachment(attached_pr(attachments[package_id]), attached)
    end
  end

  # `work` runs inside the transaction; an `{:error, _}` result rolls it back.
  defp in_transaction(repo, package, work) do
    case repo.transaction(fn -> rollback_on_error(repo, work.()) end) do
      {:ok, {:ok, changed?}} ->
        if changed?, do: DashboardPubSub.broadcast_changed()
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

  defp fetch(repo, %WorkPackage{id: id, repo: repository, base_branch: base}) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{repo: ^repository, base_branch: ^base} = package ->
        if Lifecycle.in_flight?(package), do: {:ok, package}, else: {:error, :not_in_flight}

      %WorkPackage{} ->
        {:error, :delivery_scope_changed}

      nil ->
        {:error, :not_found}
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

  defp store(repo, work_package_id, observation, attrs, review) do
    changeset = Ecto.Changeset.change(observation || %Observation{work_package_id: work_package_id}, attrs)
    changeset = finish_pre_pr_review(changeset, observation, attrs, review)

    if is_nil(observation) or changeset.changes != %{} do
      now = DateTime.utc_now(:microsecond)
      attrs = Map.merge(changeset.changes, %{observed_at: now, updated_at: now})
      {count, _} = write_observation(repo, work_package_id, observation, attrs)
      if count > 0, do: DashboardPubSub.broadcast_changed()
    end

    :ok
  end

  defp write_observation(repo, id, nil, attrs) do
    attrs = Map.merge(attrs, %{work_package_id: id, inserted_at: attrs.observed_at})
    repo.insert_all(Observation, [attrs], on_conflict: :nothing, conflict_target: [:work_package_id])
  end

  # A manual sync can publish authoritative evidence while a sweep is still
  # waiting for other providers. Display reads change only updated_at.
  defp write_observation(repo, id, %Observation{observed_at: observed_at}, attrs) do
    query = from(current in Observation, where: current.work_package_id == ^id and current.observed_at == ^observed_at)
    repo.update_all(query, set: Map.to_list(attrs))
  end

  # A display refresh may have changed review fields since the sweep read the
  # row. Closing its pre-PR window publishes the sweep's current review facts.
  defp finish_pre_pr_review(changeset, %Observation{pr_absent: true}, %{pr_absent: false} = attrs, review) do
    changeset = Ecto.Changeset.force_change(changeset, :stale, attrs.stale)
    if review == :unknown, do: changeset, else: Ecto.Changeset.force_change(changeset, :review, attrs.review)
  end

  defp finish_pre_pr_review(changeset, _observation, _attrs, _review), do: changeset

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
