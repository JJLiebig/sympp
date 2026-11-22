defmodule SymphonyElixir.SymphonyPlusPlus.DeploymentObservation do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Inputs
  alias SymphonyElixir.SymphonyPlusPlus.{DashboardCache, OperatorConfig}
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.DefaultClient
  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity

  @cache_table __MODULE__
  @refreshes {__MODULE__, :refreshes}
  @ttl_ms 60_000
  @timeout_ms 5_000
  @request_limit 30

  @spec enrich(map(), map(), keyword()) :: map()
  def enrich(payload, config, opts \\ []) do
    cond do
      OfflineSandbox.enabled?() -> payload
      Keyword.get(opts, :async, false) -> refresh_after(fn -> enrich_online(payload, config, opts) end)
      true -> enrich_online(payload, config, opts)
    end
  end

  @doc false
  @spec refresh_after((-> result)) :: result when result: var
  def refresh_after(fun) do
    Process.put(@refreshes, %{})

    try do
      result = fun.()
      start_refreshes(Process.get(@refreshes))
      result
    after
      Process.delete(@refreshes)
    end
  end

  defp enrich_online(payload, config, opts) do
    table = ensure_table(Keyword.get(opts, :cache_table, @cache_table))
    :ets.select_delete(table, [{{:"$1", :"$2", :"$3", :"$4"}, [{:<, :"$2", now_ms() - @ttl_ms * 10}], [true]}])

    state = %{
      table: table,
      async?: Keyword.get(opts, :async, false),
      fetch: Keyword.get(opts, :fetch, &DefaultClient.get_json/2),
      deadline: now_ms() + Keyword.get(opts, :timeout_ms, @timeout_ms),
      remaining: Keyword.get(opts, :request_limit, @request_limit),
      memo: %{},
      exhausted?: false,
      signals: %{}
    }

    {details, state} =
      Enum.map_reduce(payload.work_request_details, state, fn detail, state ->
        enrich_detail(detail, config, state)
      end)

    track_signals(state.signals)
    observations = Map.new(details, &{&1.work_request.id, Map.take(&1.work_request, [:deployments, :default_branch])})

    payload
    |> Map.put(:work_request_details, details)
    |> put_card_observations(observations)
  end

  defp put_card_observations(%{work_requests: %{work_requests: _cards}} = payload, observations) do
    update_in(payload, [:work_requests, :work_requests], fn cards ->
      Enum.map(cards, &Map.merge(&1, Map.get(observations, &1.id, %{})))
    end)
  end

  defp put_card_observations(payload, _observations), do: payload

  defp enrich_detail(detail, config, state) do
    request = detail.work_request
    packages = Enum.reject(detail.work_packages, &(outcome(&1) in ["superseded", "abandoned", "skipped"]))
    by_repo = Enum.group_by(packages, &package_repo/1)
    repos = [repository(request) | Map.keys(by_repo)] |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    {observations, state} =
      Enum.map_reduce(repos, state, fn repo, state ->
        workflows = workflows(config, repo)
        repo_packages = Map.get(by_repo, repo, [])

        {environments, state} =
          Enum.map_reduce(workflows, state, fn {environment, workflow}, state ->
            {observation, state} = observe(request, repo_packages, repo, workflow, state)
            {{environment, observation}, state}
          end)

        {{repo, Map.new(environments)}, state}
      end)

    deployments =
      observations
      |> Map.new(fn {repo, envs} -> {repo, Map.reject(envs, fn {_env, observation} -> is_nil(observation) end)} end)
      |> Map.reject(fn {_repo, envs} -> map_size(envs) == 0 end)

    request = if map_size(deployments) == 0, do: request, else: Map.put(request, :deployments, deployments)
    {request, state} = put_default_branch(request, config, state)
    {%{detail | work_request: request}, state}
  end

  defp observe(request, packages, repo, workflow, state) do
    revisions = packages |> Enum.filter(&(outcome(&1) == "pr_merged")) |> Enum.map(&value(value(&1, :delivery), :merge_commit_sha))

    cond do
      packages != [] and Enum.all?(packages, &(outcome(&1) == "completed_no_pr")) ->
        {nil, state}

      is_nil(request.completed_at) ->
        {pending(workflow, "unfinished"), state}

      revisions == [] or Enum.any?(revisions, &(not sha?(&1))) or
          Enum.any?(packages, &(outcome(&1) not in ["pr_merged", "completed_no_pr"])) ->
        {pending(workflow, "missing_merge_evidence"), state}

      true ->
        revisions = revisions |> Enum.uniq() |> Enum.sort()

        read_signal(
          {:deployment, repo, workflow, revisions},
          pending(workflow, "unavailable"),
          state,
          &deployment(repo, workflow, revisions, &1)
        )
    end
  end

  defp deployment(repo, workflow, revisions, state) do
    {runs, observed_at, complete?, state} = workflow_runs(repo, workflow, 1, [], nil, nil, state)

    if complete? do
      select_observation(runs, repo, revisions, workflow, observed_at, state)
    else
      {pending(workflow, "unavailable", observed_at), state}
    end
  end

  defp read_signal(key, empty, %{async?: true} = state, read) do
    slot = {:signal, key}
    %{table: table, fetch: fetch} = state
    lookup = fn -> cached_signal(table, slot, empty, fetch, read) end
    {value, _fresh?} = Inputs.memo(slot, lookup)
    {value, put_in(state.signals[slot], {signal_value(value), lookup})}
  end

  defp read_signal(_key, _empty, state, read), do: read.(state)

  defp track_signals(signals) when map_size(signals) == 0, do: :ok

  defp track_signals(signals) do
    Inputs.record({:deployments, make_ref()}, true, fn ->
      {unchanged?, fresh?} =
        Enum.reduce(signals, {true, true}, fn {slot, {previous, read}}, {unchanged?, fresh?} ->
          {value, fresh_signal?} = Inputs.memo(slot, read)
          {unchanged? and signal_value(value) == previous, fresh? and fresh_signal?}
        end)

      # A native read may also need archived badges after the web reader's
      # refresh. Wait for its complete set before exposing a provider change.
      unchanged? or not fresh?
    end)
  end

  defp signal_value(value) when is_map(value), do: Map.delete(value, :observed_at)
  defp signal_value(value), do: value

  @doc false
  @spec change_identity(map()) :: map()
  def change_identity(payload) do
    payload
    |> rewrite_if_present(:work_request_details, fn details ->
      Enum.map(details, &Map.update!(&1, :work_request, fn request -> without_observation_times(request) end))
    end)
    |> rewrite_if_present(:work_requests, fn section ->
      Map.update!(section, :work_requests, &Enum.map(&1, fn request -> without_observation_times(request) end))
    end)
  end

  defp without_observation_times(request) do
    rewrite_if_present(request, :deployments, fn deployments ->
      Map.new(deployments, fn {repo, envs} -> {repo, Map.new(envs, fn {env, badge} -> {env, signal_value(badge)} end)} end)
    end)
  end

  defp rewrite_if_present(map, key, rewrite) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, rewrite.(value))
      :error -> map
    end
  end

  defp workflow_runs(repo, workflow, page, runs, observed_at, expected_total, state) do
    path = "repos/#{repo}/actions/workflows/#{URI.encode(workflow, &URI.char_unreserved?/1)}/runs?per_page=100&page=#{page}"
    {result, fetched_at, state} = fetch(path, state)
    observed_at = oldest_timestamp(observed_at, fetched_at)

    case result do
      {:ok, %{"workflow_runs" => batch, "total_count" => total}} when is_list(batch) and is_integer(total) ->
        collected = runs ++ batch
        run_ids = Enum.map(collected, &value(&1, :id))

        cond do
          not consistent_page?(run_ids, total, expected_total) -> {collected, observed_at, false, state}
          length(collected) == total -> {collected, observed_at, true, state}
          batch == [] -> {collected, observed_at, false, state}
          true -> workflow_runs(repo, workflow, page + 1, collected, observed_at, total, state)
        end

      _unavailable ->
        {runs, observed_at, false, state}
    end
  end

  defp consistent_page?(run_ids, total, expected_total) do
    (is_nil(expected_total) or expected_total == total) and
      length(Enum.uniq(run_ids)) == length(run_ids) and length(run_ids) <= total
  end

  defp select_observation(runs, repo, revisions, workflow, observed_at, state) do
    runs = runs |> Enum.filter(&valid_run?(&1, repo)) |> Enum.sort_by(&run_order/1, :desc)
    successful = Enum.find(runs, &(&1["status"] == "completed" and &1["conclusion"] == "success"))
    {contains?, state} = contains_all(successful, repo, revisions, state)

    case contains? do
      true ->
        {observation("ok", successful, workflow, observed_at), state}

      :unknown ->
        {pending(workflow, "unavailable", observed_at), state}

      false ->
        attempts = if successful, do: Enum.take_while(runs, &(run_order(&1) > run_order(successful))), else: runs
        select_attempt(attempts, repo, revisions, workflow, observed_at, state)
    end
  end

  defp select_attempt([], _repo, _revisions, workflow, observed_at, state),
    do: {pending(workflow, "not_deployed", observed_at), state}

  defp select_attempt([run | rest], repo, revisions, workflow, observed_at, state) do
    case contains_all(run, repo, revisions, state) do
      {true, state} ->
        status = if run["status"] == "completed" and run["conclusion"] in ["failure", "timed_out", "action_required"], do: "failed", else: "pending"
        {observation(status, run, workflow, observed_at), state}

      {:unknown, state} ->
        {pending(workflow, "unavailable", observed_at), state}

      {false, state} ->
        select_attempt(rest, repo, revisions, workflow, observed_at, state)
    end
  end

  defp contains_all(nil, _repo, _revisions, state), do: {false, state}

  defp contains_all(run, repo, revisions, state) do
    Enum.reduce_while(revisions, {true, state}, fn revision, {_contains, state} ->
      case contains_revision(run["head_sha"], repo, revision, state) do
        {true, state} -> {:cont, {true, state}}
        result -> {:halt, result}
      end
    end)
  end

  defp contains_revision(revision, _repo, revision, state), do: {true, state}

  defp contains_revision(head, repo, revision, state) do
    {result, _observed_at, state} = fetch("repos/#{repo}/compare/#{revision}...#{head}?per_page=1", state)

    case result do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] -> {true, state}
      {:ok, %{"status" => status}} when status in ["behind", "diverged"] -> {false, state}
      _unavailable -> {:unknown, state}
    end
  end

  defp valid_run?(run, repo) when is_map(run) do
    canonical(value(run["repository"], :full_name)) == repo and
      canonical(value(run["head_repository"], :full_name)) == repo and
      run["event"] not in ["pull_request", "pull_request_target"] and
      is_binary(run["event"]) and sha?(run["head_sha"]) and
      is_integer(run["id"]) and not is_nil(timestamp(run["updated_at"]))
  end

  defp valid_run?(_run, _repo), do: false

  defp run_order(run), do: {timestamp_number(run["updated_at"]), run["run_attempt"] || 1, run["id"]}

  defp observation(status, run, workflow, observed_at) do
    %{
      status: status,
      at: timestamp(if(run["status"] == "completed", do: run["updated_at"], else: run["run_started_at"] || run["created_at"])),
      revision: run["head_sha"],
      workflow: workflow,
      run_id: run["id"],
      url: "https://github.com/#{canonical(value(run["repository"], :full_name))}/actions/runs/#{run["id"]}",
      observed_at: observed_at
    }
  end

  defp pending(workflow, reason, observed_at \\ nil) do
    %{
      status: "pending",
      at: nil,
      revision: nil,
      workflow: workflow,
      run_id: nil,
      url: nil,
      observed_at: observed_at,
      reason: reason
    }
  end

  defp put_default_branch(request, config, state) do
    repo = repository(request)

    if workflows(config, repo) == [] do
      {request, state}
    else
      {branch, state} = read_signal({:default_branch, repo}, nil, state, &default_branch(repo, &1))
      request = if branch, do: Map.put(request, :default_branch, branch), else: request
      {request, state}
    end
  end

  defp default_branch(repo, state) do
    {result, _observed_at, state} = fetch("repos/#{repo}", state)

    case result do
      {:ok, %{"default_branch" => branch}} when is_binary(branch) and branch != "" -> {branch, state}
      _unavailable -> {nil, state}
    end
  end

  defp workflows(_config, nil), do: []

  defp workflows(config, repo) do
    Inputs.record({:deploy_workflows, repo}, configured_workflows(config, repo), fn ->
      configured_workflows(OperatorConfig.load(), repo)
    end)
  end

  defp configured_workflows(config, repo) do
    repository_config = Map.get(Map.get(config, "repos", %{}), repo)

    case value(repository_config, :deploy_workflows) do
      workflows when is_map(workflows) ->
        workflows
        |> Map.take(["dev", "prod"])
        |> Enum.filter(fn {_env, name} -> is_binary(name) and String.trim(name) != "" end)
        |> Enum.sort()

      _absent ->
        []
    end
  end

  defp package_repo(package), do: canonical(value(value(package, :delivery), :pr_repository)) || repository(package)
  defp outcome(package), do: value(value(package, :delivery), :outcome)

  defp repository(payload) do
    remote = value(payload, :repo_remote) || value(payload, :repo)
    canonical(RepoIdentity.fields(RepoIdentity.catalog([remote]), remote).repo_remote)
  end

  defp canonical(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/, value), do: String.downcase(value)
  end

  defp canonical(_value), do: nil
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/^[a-fA-F0-9]{40}$/, value)
  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp fetch(path, state) do
    case Map.fetch(state.memo, path) do
      {:ok, {result, observed_at}} -> {result, observed_at, state}
      :error -> fetch_cached(path, state)
    end
  end

  defp fetch_cached(path, state) do
    case fresh(state.table, path) do
      {:ok, result, observed_at} -> remember(state, path, result, observed_at)
      :stale -> fetch_missing(path, state)
    end
  end

  defp fetch_missing(path, %{budget: _budget} = state) do
    # Several badges may need the same page or comparison. Even in parallel
    # the refresh batch fetches that path just once.
    :global.trans({{__MODULE__, state.table, path}, self()}, fn ->
      case fresh(state.table, path) do
        {:ok, result, observed_at} -> remember(state, path, result, observed_at)
        :stale -> fetch_remote(path, state)
      end
    end)
  end

  defp fetch_missing(path, state), do: fetch_remote(path, state)

  defp remember(state, path, result, observed_at) do
    {result, observed_at, %{state | memo: Map.put(state.memo, path, {result, observed_at})}}
  end

  defp fresh(table, key) do
    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, recorded_at, value, timestamp}] when now - recorded_at < @ttl_ms -> {:ok, value, timestamp}
      _missing_or_expired -> :stale
    end
  end

  defp cached_signal(table, key, fallback, fetch, read) do
    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, recorded_at, value, _}] when now - recorded_at < @ttl_ms ->
        {value, true}

      rows ->
        refreshes = Process.get(@refreshes)
        Process.put(@refreshes, Map.update(refreshes, table, %{key => {fetch, read}}, &Map.put(&1, key, {fetch, read})))

        case rows do
          [{^key, _at, value, _}] -> {value, false}
          [] -> {fallback, false}
        end
    end
  end

  defp start_refreshes(refreshes) do
    for {table, signals} <- refreshes, :ets.insert_new(table, {:refreshing, nil}) do
      job = fn -> refresh_batch(table, signals) end

      case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, job) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> :ets.delete(table, :refreshing)
      end
    end
  end

  defp refresh_batch(table, signals) do
    :ets.update_element(table, :refreshing, {2, self()})
    budget = :atomics.new(1, signed: true)
    :atomics.put(budget, 1, @request_limit)
    state = %{table: table, budget: budget, deadline: now_ms() + @timeout_ms, memo: %{}, exhausted?: false}

    # Refresh complete badge observations before publishing them. An outage
    # or a new run can change which comparison or pagination calls are needed.
    # Publishing each provider response would expose partial badge updates.
    observations =
      signals
      |> Task.async_stream(&refresh_signal(&1, state), max_concurrency: @request_limit, timeout: :infinity)
      |> Enum.flat_map(fn
        {:ok, {key, value}} -> [{key, value}]
        {:ok, :skip} -> []
      end)

    at = now_ms()

    changed? =
      Enum.any?(observations, fn {key, value} ->
        signal_value(:ets.lookup_element(table, key, 3, nil)) != signal_value(value)
      end)

    :ets.insert(table, Enum.map(observations, fn {key, value} -> {key, at, value, nil} end))
    if changed?, do: DashboardCache.inputs_changed()
  after
    :ets.delete(table, :refreshing)
  end

  defp refresh_signal({key, {fetch, read}}, state) do
    case fresh(state.table, key) do
      {:ok, _, _} ->
        :skip

      :stale ->
        {value, state} = read.(Map.put(state, :fetch, fetch))
        if state.exhausted?, do: :skip, else: {key, value}
    end
  end

  defp fetch_remote(path, state) do
    timeout = state.deadline - now_ms()

    with true <- timeout > 0,
         {:ok, state} <- reserve_request(state) do
      {_path, _at, result, observed_at} = row = remote_row(path, state.fetch, timeout)
      :ets.insert(state.table, row)
      remember(state, path, result, observed_at)
    else
      _exhausted -> {{:error, :budget}, nil, %{state | exhausted?: true}}
    end
  end

  defp reserve_request(%{budget: budget} = state), do: if(:atomics.sub_get(budget, 1, 1) >= 0, do: {:ok, state}, else: :exhausted)
  defp reserve_request(%{remaining: remaining} = state) when remaining > 0, do: {:ok, %{state | remaining: remaining - 1}}
  defp reserve_request(_state), do: :exhausted

  defp remote_row(path, fetch, timeout) do
    task = Task.async(fn -> fetch.(path, timeout: timeout, receive_timeout: timeout) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _unavailable -> {:error, :timeout}
      end

    {path, now_ms(), result, DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  defp ensure_table(table) when is_reference(table), do: table

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        options = [:named_table, :public, read_concurrency: true]
        owner = Process.whereis(SymphonyElixir.Supervisor) || Process.whereis(SymphonyElixir.TaskSupervisor)
        options = if owner, do: [{:heir, owner, :deployment_observation} | options], else: options

        try do
          :ets.new(table, options)
        rescue
          _race in ArgumentError -> table
        end

      _exists ->
        table
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp oldest_timestamp(nil, right), do: right
  defp oldest_timestamp(left, nil), do: left
  defp oldest_timestamp(left, right), do: if(timestamp_number(left) <= timestamp_number(right), do: left, else: right)

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp timestamp_number(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(datetime, :microsecond)
  end
end
