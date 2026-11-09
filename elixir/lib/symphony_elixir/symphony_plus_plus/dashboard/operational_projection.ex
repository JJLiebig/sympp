defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.OperationalProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    BlockerProjection,
    DeliveryWorkPackageProjection,
    MetadataProjection,
    Sanitizer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @stale_heartbeat_after_seconds 300
  @ready_statuses ["ready"]
  @merge_required_gates ["human_merge", "architect_merge"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks"]
  @prepared_worktree_statuses ["prepared", "already_prepared"]

  @type repo :: module()

  @spec runtime_summary([AgentRun.t()]) :: map()
  def runtime_summary(agent_runs) do
    runs = Enum.map(agent_runs, &agent_run/1)

    %{
      stale_heartbeat_after_seconds: @stale_heartbeat_after_seconds,
      active_count: Enum.count(runs, &(&1.runtime_state == "active")),
      queued_count: Enum.count(runs, &(&1.runtime_state == "queued")),
      stopped_count: Enum.count(runs, &(&1.runtime_state == "stopped")),
      failed_count: Enum.count(runs, &(&1.status == "failed")),
      completed_count: Enum.count(runs, &(&1.status == "completed")),
      terminal_count: Enum.count(runs, &(&1.runtime_state in ["stopped", "terminal"])),
      stale_count: Enum.count(runs, & &1.stale)
    }
  end

  @spec stale_agent_run?(AgentRun.t()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run) do
    stale_agent_run?(run, DateTime.utc_now(:microsecond), @stale_heartbeat_after_seconds)
  end

  @spec stale_agent_run?(AgentRun.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}, %DateTime{} = now, threshold_seconds)
      when status in ["starting", "running", "retrying"] and is_integer(threshold_seconds) and threshold_seconds >= 0 do
    DateTime.diff(now, last_seen_at, :second) >= threshold_seconds
  end

  def stale_agent_run?(%AgentRun{}, %DateTime{}, _threshold_seconds), do: false

  @spec latest_active_agent_run([AgentRun.t()]) :: map() | nil
  def latest_active_agent_run(agent_runs) do
    agent_runs
    |> latest_active_run()
    |> case do
      %AgentRun{} = run -> agent_run(run)
      nil -> nil
    end
  end

  @spec plan_summary([PlanNode.t()]) :: map()
  def plan_summary(plan_nodes) do
    total = length(plan_nodes)
    completed = Enum.count(plan_nodes, &(&1.status in ["done", "completed", "skipped"]))

    %{
      total_count: total,
      completed_count: completed,
      open_count: max(total - completed, 0)
    }
  end

  @spec work_package_operational_state(WorkPackage.t(), map()) :: map()
  def work_package_operational_state(%WorkPackage{} = work_package, context) do
    agent_runs = Map.fetch!(context, :agent_runs)
    progress_events = Map.fetch!(context, :progress_events)
    blockers = Map.fetch!(context, :blockers)
    runtime = Map.fetch!(context, :runtime)
    metadata = Map.fetch!(context, :metadata)
    readiness_context = Map.fetch!(context, :readiness_context)
    lineage = Map.fetch!(context, :lineage)
    missing_readiness = if work_package.status in @ready_statuses, do: missing_readiness_evidence(readiness_context), else: []
    activity = work_package_activity(work_package, progress_events, agent_runs, runtime, metadata, Map.get(context, :worker_signal))

    attention_items =
      work_package_attention_items(work_package, blockers, %{
        metadata: metadata,
        missing_readiness: missing_readiness,
        activity: activity,
        lineage: lineage
      })

    work_package
    |> base_work_package_operational_state(blockers, metadata, missing_readiness, activity)
    |> Map.merge(%{merge_required: merge_required?(work_package), pr_required: pr_required?(work_package)})
    |> Map.merge(operational_activity_fields(activity))
    |> Map.put(:attention_items, attention_items)
  end

  @spec work_package_operational_state(WorkPackage.t(), map() | nil, map() | nil) :: map()
  def work_package_operational_state(%WorkPackage{} = work_package, work_package_context, delivery_work_package) do
    work_package_operational_state(work_package, work_package_context, delivery_work_package, [])
  end

  @spec work_package_operational_state(WorkPackage.t(), map() | nil, map() | nil, keyword()) :: map()
  def work_package_operational_state(%WorkPackage{} = work_package, work_package_context, delivery_work_package, delivery_state_opts) do
    base_state = base_work_package_operational_state(work_package, work_package_context)

    state =
      case DeliveryWorkPackageProjection.primary_operational_state(delivery_work_package, delivery_state_opts) do
        nil -> base_state
        operational_state -> delivery_operational_state_overlay(base_state, operational_state)
      end

    activity = if(Keyword.get(delivery_state_opts, :include_package_fields?, true), do: get_in(delivery_work_package || %{}, [:operational_state, :activity_signal]))

    case activity do
      nil -> state
      activity -> Map.put(state, :activity_signal, activity)
    end
  end

  @spec operational_activity_fields(map()) :: map()
  def operational_activity_fields(activity) do
    Map.take(activity, [:has_started, :has_active_worker, :has_prepared_worktree, :last_activity_at, :is_stale, :activity_signal])
  end

  @spec alert_indicators(repo(), State.t(), map()) :: [map()]
  @spec alert_indicators(map(), [map()], map()) :: [map()]
  def alert_indicators(repo, %State{} = state, runtime) when is_atom(repo) do
    state
    |> readiness_context(repo, length(state.artifacts), length(state.findings))
    |> alert_indicators(blockers(state.progress_events), runtime)
  end

  def alert_indicators(readiness_context, blockers, runtime) do
    [
      blocker_indicator(readiness_context.work_package, blockers),
      stale_heartbeat_indicator(runtime),
      failed_run_indicator(runtime),
      missing_readiness_indicator(readiness_context)
    ]
  end

  @spec readiness_context(State.t(), repo(), non_neg_integer(), non_neg_integer()) :: map()
  def readiness_context(%State{} = state, repo, _artifact_count, _finding_count) do
    readiness_context(
      repo,
      state.work_package,
      state.plan_nodes,
      state.progress_events,
      state.artifacts,
      state.findings
    )
  end

  @spec readiness_context(
          repo(),
          WorkPackage.t(),
          [PlanNode.t()],
          [ProgressEvent.t()],
          [term()],
          [term()]
        ) :: map()
  def readiness_context(repo, %WorkPackage{} = work_package, plan_nodes, progress_events, artifacts, findings) do
    %{
      repo: repo,
      work_package: work_package,
      plan_nodes: plan_nodes,
      progress_events: chronological_progress_events(progress_events),
      artifacts: artifacts,
      findings: findings,
      artifact_count: length(artifacts),
      finding_count: length(findings)
    }
  end

  @spec missing_readiness_evidence(map()) :: [String.t()]
  def missing_readiness_evidence(%{work_package: %WorkPackage{}} = context) do
    context
    |> readiness_failure_reasons()
    |> missing_readiness_gates()
  end

  @spec package_lineage(repo(), String.t()) :: map()
  def package_lineage(repo, work_package_id), do: MetadataProjection.package_lineage(repo, work_package_id)

  @spec package_lineages(repo(), [WorkPackage.t()]) :: map()
  def package_lineages(repo, work_packages), do: MetadataProjection.package_lineages(repo, work_packages)

  @spec empty_lineage(String.t()) :: map()
  def empty_lineage(work_package_id), do: MetadataProjection.empty_lineage(work_package_id)

  @spec blockers([ProgressEvent.t()]) :: [map()]
  def blockers(progress_events), do: BlockerProjection.blockers(progress_events)

  @spec agent_run(AgentRun.t()) :: map()
  def agent_run(%AgentRun{} = run) do
    %{
      id: run.id,
      work_package_id: run.work_package_id,
      actor_id: run.actor_id,
      status: run.status,
      runtime_state: runtime_state(run),
      stale: stale_agent_run?(run),
      stale_after_seconds: @stale_heartbeat_after_seconds,
      attempt: run.attempt,
      worker_host: redacted_text(run.worker_host),
      worker_task_handle: redacted_text(run.worker_task_handle),
      workspace_path: redacted_text(run.workspace_path),
      session_id: redacted_text(run.session_id),
      codex_input_tokens: run.codex_input_tokens,
      codex_output_tokens: run.codex_output_tokens,
      codex_total_tokens: run.codex_total_tokens,
      turn_count: run.turn_count,
      started_at: timestamp(run.started_at),
      last_seen_at: timestamp(run.last_seen_at),
      finished_at: timestamp(run.finished_at),
      reason: redacted_text(run.reason)
    }
  end

  defp runtime_state(%AgentRun{status: "starting"}), do: "queued"
  defp runtime_state(%AgentRun{status: status}) when status in ["running", "retrying"], do: "active"
  defp runtime_state(%AgentRun{status: "stopped"}), do: "stopped"
  defp runtime_state(%AgentRun{status: status}) when status in ["completed", "failed"], do: "terminal"
  defp runtime_state(%AgentRun{}), do: "unknown"

  defp latest_active_run(agent_runs) do
    agent_runs
    |> Enum.filter(&(runtime_state(&1) in ["active", "queued"] and not stale_agent_run?(&1)))
    |> List.last()
  end

  defp base_work_package_operational_state(%WorkPackage{status: status} = work_package, blockers, metadata, missing_readiness, activity) do
    active_blocker_count = blockers |> active_blockers() |> length()

    blocking_or_terminal_operational_state(status, active_blocker_count, metadata) ||
      delivery_operational_state(work_package, metadata, missing_readiness, activity)
  end

  defp blocking_or_terminal_operational_state(status, active_blocker_count, metadata) do
    cond do
      Lifecycle.ended?(status) ->
        operational_state("ended", "Ended", "neutral", "The WorkPackage ended; its ending row records how.", status)

      active_blocker_count > 0 ->
        operational_state("blocked", "Blocked", "critical", blocker_detail(active_blocker_count), status)

      pr_merged?(metadata) ->
        operational_state("merged", "Merged", "success", "PR metadata reports a merged pull request while raw status is #{status}.", status)

      true ->
        nil
    end
  end

  defp delivery_operational_state(%WorkPackage{status: status} = work_package, _metadata, missing_readiness, activity) do
    validation_operational_state(work_package, missing_readiness) ||
      pickup_operational_state(status, activity)
  end

  defp validation_operational_state(%WorkPackage{status: status} = work_package, missing_readiness) do
    if status in @ready_statuses, do: ready_operational_state(work_package, missing_readiness)
  end

  defp ready_operational_state(%WorkPackage{status: status} = work_package, missing_readiness) do
    tone = if missing_readiness == [], do: "success", else: "warning"

    if merge_required?(work_package) do
      reason = if missing_readiness == [], do: "Package is marked ready with required evidence present.", else: "Package is marked ready but evidence is incomplete."
      operational_state("merge_ready", "Ready For Merge", tone, reason, status)
    else
      reason = if missing_readiness == [], do: "Package is ready to finish with closeout evidence.", else: "Package is ready to finish but evidence is incomplete."
      operational_state("ready_to_finish", "Ready To Finish", tone, reason, status)
    end
  end

  defp pickup_operational_state(status, %{has_active_worker: true}) when status != "planned" do
    operational_state("active", "Active", "info", "Runtime evidence indicates work is active now.", status)
  end

  defp pickup_operational_state(status, %{has_started: true}) when status != "planned" do
    operational_state(
      "started_paused",
      "Started / Paused",
      "warning",
      "Runtime, progress, PR, or review evidence exists, but no active worker or runtime is visible now.",
      status
    )
  end

  defp pickup_operational_state("dispatched" = status, %{has_prepared_worktree: true}) do
    operational_state("prepared", "Prepared", "neutral", "Worktree preparation is recorded and the package is awaiting its worker.", status)
  end

  defp pickup_operational_state("dispatched" = status, _activity) do
    operational_state("dispatched", "Dispatched", "neutral", "The package was dispatched; no worker, PR or review activity is recorded yet.", status)
  end

  defp pickup_operational_state(status, _activity) do
    key = status || "unknown"
    operational_state(key, status_label(key), "neutral", "WorkPackage status is #{key}.", status)
  end

  defp delivery_operational_state_overlay(base_state, delivery_state) do
    base_state
    |> Map.merge(delivery_state)
    |> Map.put(:attention_items, merged_attention_items(base_state, delivery_state))
  end

  defp merged_attention_items(base_state, delivery_state) do
    if Map.get(delivery_state, :delivery_outcome) do
      Map.get(delivery_state, :attention_items, [])
    else
      (Map.get(base_state, :attention_items, []) ++ Map.get(delivery_state, :attention_items, []))
      |> Enum.uniq_by(&Map.get(&1, :key))
    end
  end

  defp base_work_package_operational_state(%WorkPackage{} = work_package, nil) do
    work_package
    |> base_work_package_without_context_state()
    |> Map.put(:attention_items, package_delivery_attention_items(work_package, nil))
  end

  defp base_work_package_operational_state(%WorkPackage{} = work_package, %{card: card, work_package: %WorkPackage{}}) do
    package_state = Map.fetch!(card, :operational_state)
    attention_items = package_delivery_attention_items(work_package, package_state)

    if promoted_context_operational_state?(package_state) do
      package_state
      |> operational_activity_fields()
      |> Map.merge(
        operational_state(
          package_state.key,
          package_state.label,
          package_state.tone,
          "WorkPackage #{work_package.id} is #{package_state.label}.",
          work_package.status,
          attention_items
        )
      )
    else
      idle_work_package_operational_state(work_package, attention_items)
    end
  end

  defp base_work_package_without_context_state(%WorkPackage{status: "planned"} = work_package) do
    operational_state("planned", "Planned", "neutral", "WorkPackage is planned and has not been dispatched.", work_package.status)
  end

  defp base_work_package_without_context_state(%WorkPackage{} = work_package) do
    status = work_package.status || "unknown"
    operational_state(status, status_label(status), "neutral", "WorkPackage status is #{status}.", status)
  end

  defp idle_work_package_operational_state(%WorkPackage{status: "planned"} = work_package, attention_items) do
    operational_state(
      "planned",
      "Planned",
      "neutral",
      "WorkPackage is planned and has not been dispatched.",
      work_package.status,
      attention_items
    )
  end

  defp idle_work_package_operational_state(%WorkPackage{} = work_package, attention_items) do
    operational_state(
      work_package.status,
      status_label(work_package.status),
      "neutral",
      "WorkPackage #{work_package.id} has not started.",
      work_package.status,
      attention_items
    )
  end

  defp package_delivery_attention_items(%WorkPackage{}, nil), do: []

  defp package_delivery_attention_items(%WorkPackage{}, package_state), do: Map.get(package_state, :attention_items, [])

  defp promoted_context_operational_state?(%{key: key}) do
    key in [
      "blocked",
      "active",
      "prepared",
      "started_paused",
      "merge_ready",
      "ready_to_finish",
      "merging",
      "merged",
      "ended"
    ]
  end

  defp promoted_context_operational_state?(_state), do: false

  defp work_package_attention_items(%WorkPackage{status: "ended"}, _blockers, _context), do: []

  defp work_package_attention_items(%WorkPackage{} = work_package, blockers, context) do
    missing_readiness = Map.fetch!(context, :missing_readiness)
    lineage = Map.fetch!(context, :lineage)

    single_items =
      [
        active_blocker_attention_item(blockers),
        missing_readiness_attention_item(work_package, missing_readiness)
      ]
      |> Enum.reject(&is_nil/1)

    single_items ++ lineage_cleanup_attention_items(lineage)
  end

  defp lineage_cleanup_attention_items(%{cleanup_attention: items}) when is_list(items), do: items
  defp lineage_cleanup_attention_items(_lineage), do: []

  defp active_blocker_attention_item(blockers) do
    case active_blockers(blockers) do
      [] ->
        nil

      active ->
        %{
          key: "active_blocker",
          label: "Active Blocker",
          tone: "critical",
          reason: blocker_detail(length(active)),
          blocker_ids: Enum.map(active, & &1.id)
        }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{status: status}, missing_readiness) when status in @ready_statuses do
    case missing_readiness do
      [] ->
        nil

      missing ->
        %{
          key: "missing_readiness_evidence",
          label: "Missing Readiness Evidence",
          tone: "warning",
          reason: missing_detail(missing),
          missing: missing
        }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{}, _missing_readiness), do: nil

  defp active_blockers(blockers), do: Enum.filter(blockers, & &1.active)

  defp work_package_activity(
         %WorkPackage{} = work_package,
         progress_events,
         agent_runs,
         runtime,
         metadata,
         worker_signal
       ) do
    has_active_worker = match?(%{status: "active"}, worker_signal)

    {has_prepared_worktree, has_meaningful_progress} = progress_activity(progress_events)

    has_started =
      work_package_started?(
        has_active_worker,
        agent_runs,
        runtime,
        has_meaningful_progress,
        metadata
      )

    has_activity = has_started or has_prepared_worktree

    %{
      has_started: has_started,
      has_active_worker: has_active_worker,
      has_prepared_worktree: has_prepared_worktree,
      last_activity_at: latest_package_activity_at(work_package, progress_events, agent_runs, has_activity),
      is_stale: has_started and not has_active_worker
    }
  end

  defp work_package_started?(has_active_worker, agent_runs, runtime, has_meaningful_progress, metadata) do
    has_active_worker or
      agent_run_activity?(agent_runs) or
      runtime_activity?(runtime) or
      has_meaningful_progress or
      metadata_activity?(metadata)
  end

  defp latest_package_activity_at(_work_package, _progress_events, _agent_runs, false), do: nil

  defp latest_package_activity_at(%WorkPackage{} = work_package, progress_events, agent_runs, true) do
    [
      work_package.updated_at,
      latest_progress_datetime(progress_events),
      latest_agent_run_datetime(agent_runs)
    ]
    |> latest_datetime()
    |> timestamp()
  end

  defp latest_progress_datetime(progress_events) do
    progress_events
    |> Enum.map(& &1.created_at)
    |> latest_datetime()
  end

  defp latest_agent_run_datetime(agent_runs) do
    agent_runs
    |> Enum.flat_map(fn %AgentRun{} = run ->
      [run.last_seen_at, run.finished_at, run.started_at, run.updated_at, run.inserted_at]
    end)
    |> latest_datetime()
  end

  defp latest_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp agent_run_activity?(agent_runs), do: agent_runs != []

  defp progress_activity(progress_events) do
    Enum.reduce(progress_events, {false, false}, fn %ProgressEvent{} = event, {prepared?, meaningful?} ->
      if prepared_worktree_progress_event?(event) do
        {true, meaningful?}
      else
        {prepared?, true}
      end
    end)
  end

  defp prepared_worktree_progress_event?(%ProgressEvent{status: status, payload: payload}) when is_map(payload) do
    payload_status = map_value(payload, "status")

    map_value(payload, "type") == "worktree_lifecycle" and
      status in @prepared_worktree_statuses and
      (is_nil(payload_status) or payload_status in @prepared_worktree_statuses)
  end

  defp prepared_worktree_progress_event?(%ProgressEvent{}), do: false

  defp runtime_activity?(runtime) do
    Enum.any?([:active_count, :queued_count, :stopped_count, :failed_count, :completed_count, :terminal_count], &(safe_map_get(runtime, &1, 0) > 0))
  end

  defp metadata_activity?(metadata) do
    Enum.any?([:branch, :pr], &present_metadata_value?(safe_map_get(metadata, &1)))
  end

  defp present_metadata_value?(nil), do: false
  defp present_metadata_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_metadata_value?(value) when is_list(value), do: value != []
  defp present_metadata_value?(_value), do: true

  defp pr_merged?(metadata) do
    pr = safe_map_get(metadata, :pr) || safe_map_get(metadata, "pr")

    case pr do
      %{"stale" => true} -> false
      pr -> pr_merged_payload?(pr)
    end
  end

  defp safe_map_get(map, key, default \\ nil) do
    Map.get(map, key, default)
  rescue
    BadMapError -> default
  end

  defp pr_merged_payload?(%{} = pr) do
    merged_value?(map_value(pr, "merged")) or
      merged_value?(map_value(pr, "state")) or
      merged_value?(map_value(pr, "status")) or
      merged_value?(map_value(pr, "conclusion")) or
      merge_state_merged?(map_value(pr, "merge_state"))
  end

  defp pr_merged_payload?(_pr), do: false

  defp merge_state_merged?(%{} = merge_state) do
    merged_value?(map_value(merge_state, "merged")) or
      merged_value?(map_value(merge_state, "state")) or
      merged_value?(map_value(merge_state, "status")) or
      merged_value?(map_value(merge_state, "mergeable_state"))
  end

  defp merge_state_merged?(_merge_state), do: false

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp merged_value?(true), do: true

  defp merged_value?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> then(&(&1 in ["merged", "true"]))
  end

  defp merged_value?(_value), do: false

  defp operational_state(key, label, tone, reason, raw_status, attention_items \\ []) do
    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      raw_status: raw_status,
      attention_items: attention_items
    }
  end

  defp blocker_indicator(%WorkPackage{}, blockers) do
    active_count = Enum.count(blockers, & &1.active)
    alert_indicator("blocker", "Blockers", "critical", active_count > 0, blocker_detail(active_count))
  end

  defp blocker_detail(1), do: "1 active blocker"
  defp blocker_detail(count), do: "#{count} active blockers"

  defp stale_heartbeat_indicator(%{stale_count: stale_count, stale_heartbeat_after_seconds: threshold}) do
    alert_indicator(
      "stale_heartbeat",
      "Stale heartbeat",
      "warning",
      stale_count > 0,
      "#{stale_count} run(s) past #{threshold}s"
    )
  end

  defp failed_run_indicator(%{failed_count: failed_count}) do
    alert_indicator("failed_run", "Failed runs", "warning", failed_count > 0, "#{failed_count} failed run(s)")
  end

  defp missing_readiness_indicator(%{work_package: %WorkPackage{status: status}} = context) when status in @ready_statuses do
    reasons = readiness_failure_reasons(context)
    missing = missing_readiness_gates(reasons)

    alert_indicator(
      "missing_readiness_evidence",
      "Missing readiness evidence",
      "warning",
      missing != [],
      missing_detail(missing),
      %{missing: missing, reasons: reasons}
    )
  end

  defp missing_readiness_indicator(_context) do
    alert_indicator("missing_readiness_evidence", "Missing readiness evidence", "info", false, "Package is not in a ready state", %{missing: [], reasons: []})
  end

  defp alert_indicator(type, label, severity, active, detail, extra \\ %{}) do
    Map.merge(%{type: type, label: label, severity: severity, active: active, detail: detail}, extra)
  end

  defp missing_detail([]), do: "No missing evidence detected"
  defp missing_detail(missing), do: Enum.join(missing, ", ")

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  @spec readiness_failure_reasons(map()) :: [map()]
  def readiness_failure_reasons(%{work_package: %WorkPackage{}} = context) do
    [
      {active_blocker?(context.progress_events), "no_active_blockers"},
      {merge_metadata_missing?(context, "branch"), "branch_attached"},
      {merge_metadata_missing?(context, "pr"), "pr_attached"},
      {current_pr_state_missing?(context), "current_pr_state"},
      {investigation_findings_missing?(context), "findings_documented"}
    ]
    |> Enum.flat_map(fn
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved before readiness."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(context, "pr") do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      not metadata_present?(context.progress_events, "pr", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, "branch") do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, "branch", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, type) do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, type, latest_current_head_sha(context.progress_events))
  end

  defp current_pr_state_missing?(context) do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      required_gate?(context.work_package, "current_pr_state") and
      not current_pr_state_present?(context.progress_events, latest_current_head_sha(context.progress_events))
  end

  defp investigation_findings_missing?(context), do: context.work_package.kind == "investigation" and context.findings == []

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, active_by_id ->
      Map.put(active_by_id, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    normalize_blocker_id(Map.get(payload || %{}, "blocker_id") || idempotency_key || id)
  end

  @spec required_gate?(WorkPackage.t(), String.t()) :: boolean()
  def required_gate?(%WorkPackage{} = work_package, gate) do
    case policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp policy_for(%WorkPackage{} = work_package), do: Templates.for_work_package(work_package)

  @spec merge_required?(WorkPackage.t()) :: boolean()
  def merge_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} ->
        required_gates = Map.get(policy, :required_gates, [])
        Enum.any?(@merge_required_gates, &(&1 in required_gates))

      {:error, _reason} ->
        work_package.kind in @runtime_merge_required_kinds
    end
  end

  @spec pr_required?(WorkPackage.t()) :: boolean()
  def pr_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} -> "human_merge" in Map.get(policy, :required_gates, [])
      {:error, _reason} -> work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  defp latest_current_head_sha(progress_events), do: MetadataProjection.latest_current_head_sha(progress_events)
  defp metadata_present?(progress_events, type, head_sha), do: MetadataProjection.metadata_present?(progress_events, type, head_sha)
  defp current_pr_state_present?(progress_events, head_sha), do: MetadataProjection.current_pr_state_present?(progress_events, head_sha)
  defp chronological_progress_events(progress_events), do: MetadataProjection.chronological_progress_events(progress_events)
  defp blocker_event?(event), do: BlockerProjection.blocker_event?(event)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
