defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  import Ecto.Query, only: [from: 2]

  @terminal_package_statuses ["ended"]
  @stale_heartbeat_after_seconds 300

  @spec blocker_event_payload?(map()) :: boolean()
  def blocker_event_payload?(payload) when is_map(payload) do
    map_value(payload, :type) == "blocker" and map_value(payload, :source_tool) == "set_blocker"
  end

  @spec contexts(module(), [String.t()]) :: %{optional(String.t()) => map()}
  def contexts(repo, work_package_ids), do: contexts(repo, work_package_ids, %{})

  @spec contexts(module(), [String.t()], %{optional(String.t()) => [ProgressEvent.t()]}) ::
          %{optional(String.t()) => map()}
  def contexts(_repo, [], _progress_events_by_id), do: %{}

  def contexts(repo, work_package_ids, progress_events_by_id)
      when is_atom(repo) and is_list(work_package_ids) and is_map(progress_events_by_id) do
    work_package_ids =
      work_package_ids
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    progress_events_by_id =
      repo
      |> grouped_progress_events(Enum.reject(work_package_ids, &Map.has_key?(progress_events_by_id, &1)))
      |> Map.merge(Map.take(progress_events_by_id, work_package_ids))

    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)
    work_packages_by_id = grouped_work_packages(repo, work_package_ids)

    Map.new(work_package_ids, fn work_package_id ->
      progress_events = Map.get(progress_events_by_id, work_package_id, [])
      work_package = Map.get(work_packages_by_id, work_package_id)
      agent_runs = Map.get(agent_runs_by_id, work_package_id, [])

      {work_package_id, project_context(agent_runs, progress_events, work_package)}
    end)
  end

  @spec context(module(), String.t()) :: map()
  def context(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo
    |> contexts([work_package_id])
    |> Map.get(work_package_id, empty_context())
  end

  @spec empty_context() :: map()
  def empty_context do
    %{
      blocker_state: %{active?: false, active_ids: [], latest_gate_at: nil, reason_codes: []},
      runtime_state: %{
        active?: false,
        stale?: false,
        terminal?: false,
        active_agent_run_ids: [],
        stale_agent_run_ids: [],
        lifecycle_state: "idle",
        latest_gate_at: nil,
        reason_codes: []
      },
      worker_signal: nil,
      current_worker_session: nil
    }
  end

  @spec project_context([AgentRun.t()], [ProgressEvent.t()], WorkPackage.t() | nil) :: map()
  def project_context(agent_runs, progress_events, work_package) when is_list(agent_runs) and is_list(progress_events) do
    now = DateTime.utc_now(:microsecond)
    evidence = runtime_evidence(agent_runs, now)

    %{
      blocker_state: blocker_state(progress_events),
      runtime_state: runtime_state(evidence, agent_runs, work_package),
      worker_signal: worker_signal(agent_runs, evidence),
      current_worker_session: current_worker_session(evidence, work_package)
    }
  end

  defp current_worker_session(evidence, work_package) do
    unless terminal_package?(work_package) do
      evidence.active_agent_runs
      |> Enum.max_by(&{timestamp_sort_value(&1.last_seen_at), &1.id}, fn -> nil end)
      |> case do
        %AgentRun{worker_host: host, session_id: session_id} -> %{worker_host: host, session_id: session_id}
        nil -> nil
      end
    end
  end

  defp worker_signal([], _evidence), do: nil

  defp worker_signal(agent_runs, evidence) do
    %{
      status: worker_signal_status(evidence),
      active_since: worker_active_since(agent_runs, evidence),
      last_activity: agent_runs |> Enum.flat_map(&worker_activity_at/1) |> latest_timestamp(),
      run_label: worker_run_label(agent_runs)
    }
    |> reject_nil_values()
  end

  defp current_actor(evidence) do
    case evidence.active_agent_runs do
      [] ->
        nil

      runs ->
        run = Enum.max_by(runs, &timestamp_sort_value(&1.last_seen_at))

        if Enum.any?([run.actor_id, run.worker_task_handle, run.session_id], &filled_string?/1) do
          Redactor.redact(%{id: run.actor_id, name: run.worker_task_handle, role: "worker", session_id: run.session_id, source: "run"})
        end
    end
  end

  defp grouped_progress_events(_repo, []), do: %{}

  defp grouped_progress_events(repo, work_package_ids) do
    repo.all(
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id in ^work_package_ids,
        order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.created_at]
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp grouped_agent_runs(repo, work_package_ids) do
    repo.all(
      from(agent_run in AgentRun,
        where: agent_run.work_package_id in ^work_package_ids
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp grouped_work_packages(repo, work_package_ids) do
    repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_ids))
    |> Map.new(&{&1.id, &1})
  end

  defp blocker_state(progress_events) do
    blocker_events =
      progress_events
      |> Enum.filter(&blocker_event?/1)
      |> Enum.sort_by(&progress_event_order/1)

    active_by_id =
      Enum.reduce(blocker_events, %{}, fn %ProgressEvent{} = event, active_by_id ->
        Map.put(active_by_id, blocker_id(event), map_value(event.payload || %{}, :active) == true)
      end)

    active_ids =
      active_by_id
      |> Enum.filter(fn {_id, active?} -> active? end)
      |> Enum.map(fn {id, _active?} -> id end)
      |> Enum.sort()

    %{
      active?: active_ids != [],
      active_ids: active_ids,
      latest_gate_at: latest_timestamp(Enum.map(blocker_events, & &1.created_at)),
      reason_codes: blocker_reason_codes(active_ids, blocker_events)
    }
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload), do: blocker_event_payload?(payload)
  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    payload = payload || %{}

    map_value(payload, :blocker_id)
    |> Kernel.||(idempotency_key)
    |> Kernel.||(id)
    |> normalize_blocker_id()
  end

  defp progress_event_order(%ProgressEvent{} = event) do
    {event.sequence || 0, timestamp_sort_value(event.created_at), event.id || ""}
  end

  defp runtime_evidence(agent_runs, %DateTime{} = now) do
    %{
      now: now,
      active_agent_runs: Enum.filter(agent_runs, &active_agent_run?(&1, now)),
      stale_agent_runs: Enum.filter(agent_runs, &stale_agent_run?(&1, now))
    }
  end

  defp runtime_state(evidence, agent_runs, work_package) do
    terminal? = terminal_package?(work_package)
    active? = evidence.active_agent_runs != []
    stale? = evidence.stale_agent_runs != []

    reason_codes =
      [
        if(stale?, do: "agent_run_stale"),
        if(active?, do: "agent_run_active"),
        if(terminal?, do: "package_terminal")
      ]
      |> Enum.reject(&is_nil/1)

    %{
      active?: active?,
      stale?: stale?,
      terminal?: terminal?,
      active_agent_run_ids: runtime_ids(evidence.active_agent_runs),
      stale_agent_run_ids: runtime_ids(evidence.stale_agent_runs),
      lifecycle_state: runtime_lifecycle_state(active?, stale?, terminal?),
      current_actor: current_actor(evidence),
      latest_gate_at: latest_runtime_gate_at(agent_runs, work_package, evidence.now),
      reason_codes: reason_codes
    }
  end

  defp active_agent_run?(%AgentRun{status: status} = run, %DateTime{} = now) do
    status in AgentRun.active_statuses() and not stale_agent_run?(run, now)
  end

  defp stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}, %DateTime{} = now)
       when status in ["starting", "running", "retrying"] do
    DateTime.diff(now, last_seen_at, :second) >= @stale_heartbeat_after_seconds
  end

  defp stale_agent_run?(%AgentRun{}, %DateTime{}), do: false

  defp terminal_package?(%WorkPackage{status: status}), do: status in @terminal_package_statuses
  defp terminal_package?(_work_package), do: false

  defp latest_runtime_gate_at(agent_runs, work_package, %DateTime{} = now) do
    active_runtime_gate =
      agent_runs
      |> Enum.reject(&active_agent_run?(&1, now))
      |> Enum.map(&agent_run_gate_at/1)
      |> latest_timestamp()

    if terminal_package?(work_package),
      do: latest_timestamp([active_runtime_gate, work_package.updated_at]),
      else: active_runtime_gate
  end

  defp agent_run_gate_at(%AgentRun{finished_at: %DateTime{} = finished_at}), do: finished_at

  defp agent_run_gate_at(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}) when status in ["starting", "running", "retrying"] do
    DateTime.add(last_seen_at, @stale_heartbeat_after_seconds, :second)
  end

  defp agent_run_gate_at(%AgentRun{} = run), do: run.updated_at

  defp blocker_reason_codes([], []), do: []
  defp blocker_reason_codes([], _blocker_events), do: ["blocker_resolved"]
  defp blocker_reason_codes(_active_ids, _blocker_events), do: ["active_blocker"]

  defp runtime_lifecycle_state(_active?, true = _stale?, _terminal?), do: "stale"
  defp runtime_lifecycle_state(true = _active?, _stale?, _terminal?), do: "active"
  defp runtime_lifecycle_state(_active?, _stale?, true = _terminal?), do: "terminal"
  defp runtime_lifecycle_state(_active?, _stale?, _terminal?), do: "idle"

  defp worker_signal_status(%{stale_agent_runs: [_ | _]}), do: "stale"
  defp worker_signal_status(%{active_agent_runs: [_ | _]}), do: "active"
  defp worker_signal_status(_evidence), do: "idle"

  defp worker_active_since(agent_runs, evidence) do
    current_runs = evidence.active_agent_runs ++ evidence.stale_agent_runs
    runs = if current_runs != [], do: current_runs, else: agent_runs
    runs |> Enum.map(&(&1.started_at || &1.inserted_at)) |> earliest_timestamp()
  end

  defp worker_activity_at(%AgentRun{} = run) do
    [run.finished_at, run.last_seen_at, run.updated_at, run.started_at, run.inserted_at]
  end

  defp worker_run_label(agent_runs) do
    agent_runs
    |> Enum.map(&{&1 |> worker_activity_at() |> latest_timestamp(), &1.worker_task_handle || &1.actor_id})
    |> Enum.filter(fn {timestamp, label} -> match?(%DateTime{}, timestamp) and filled_string?(label) end)
    |> Enum.max_by(fn {%DateTime{} = timestamp, _label} -> DateTime.to_unix(timestamp, :microsecond) end, fn -> nil end)
    |> case do
      {_timestamp, label} -> label |> Redactor.redact_text() |> String.slice(0, 80)
      nil -> nil
    end
  end

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp runtime_ids(runtimes) do
    runtimes
    |> Enum.map(&map_value(&1, :id))
    |> Enum.filter(&filled_string?/1)
  end

  defp latest_timestamp(timestamps) do
    timestamps
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp earliest_timestamp(timestamps) do
    timestamps
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(_timestamp), do: -1

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""
end
