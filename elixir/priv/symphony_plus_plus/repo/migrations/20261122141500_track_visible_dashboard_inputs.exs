defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.TrackVisibleDashboardInputs do
  use Ecto.Migration

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.TrackDashboardRevisions

  @surfaces ~w(priority archived live native deferred detail)
  @web_execution ~w(live deferred)
  @execution ~w(archived live native deferred)

  @request_identity ~w(id repo title inserted_at archived_at operator_completed_at base_branch dispatched_by)
  @request_card @request_identity ++ ~w(work_type desired_dispatch_shape creator_kind creator_name created_via updated_at archive_reason)
  @package_phase ~w(id work_request_id status updated_at dispatched_at)
  @package_fields @package_phase ++ ~w(title kind repo base_branch branch_pattern group sequence inserted_at
    owner_id parent_id phase_id review_requirement review_mode review_id dispatched_by ci_override)
  @delivery_phase ~w(work_package_id outcome recorded_at successor_work_package_id legacy_status)
  @delivery_fields @delivery_phase ++ ~w(id work_request_id recorded_by pr_url pr_number pr_repository
    pr_merged_at merge_commit_sha no_pr_evidence superseded_reason abandoned_rationale)
  @ask_fields ~w(id work_request_id work_package_id question decision_prompt state asked_by_address inserted_at)
  @ask_delivery ~w(answer answered_by delivered_at resolved_at undelivered_reason)
  @settings ~w(work_request_archive_after_days work_request_never_started_archive_after_days open_dashboard_on_boot
    hidden_work_package_ids card_retention_days)
  @ownership ~w(id subject_kind subject_id terminal_key display_address role domain state started_at finished_at)

  # Board details, package progress and the graph share these inputs. Their
  # ownership predicate keeps an archived package's edits off the live board.
  @package_details %{
    "agent_runs" => ~w(id work_package_id actor_id status attempt worker_host worker_task_handle workspace_path
      session_id codex_input_tokens codex_output_tokens codex_total_tokens turn_count started_at last_seen_at
      finished_at reason inserted_at updated_at),
    "artifacts" => ~w(id work_package_id path title kind uri sequence created_at inserted_at metadata),
    "plan_nodes" => ~w(id work_package_id title body status position created_at inserted_at),
    "work_package_observations" => ~w(work_package_id pr review stale stacked_on)
  }
  @graphs %{
    "product_tree_dependency_edges" => ~w(id work_request_id source_kind source_id target_kind target_id kind
      reason decision_ref created_by created_at inserted_at),
    "product_tree_revisions" => ~w(id work_request_id revision_number tree_snapshot reason decision_ref created_by created_at inserted_at)
  }

  @tables ~w(work_requests work_packages work_package_deliveries progress_events asks cards
    worked_on operator_settings work_request_decision_logs) ++ Map.keys(@package_details) ++ Map.keys(@graphs)
  @events [:insert, :update, :delete]

  def up do
    TrackDashboardRevisions.drop_triggers()
    execute("ALTER TABLE sympp_dashboard_revisions ADD COLUMN deferred INTEGER NOT NULL DEFAULT 0")
    execute("ALTER TABLE sympp_dashboard_revisions ADD COLUMN detail INTEGER NOT NULL DEFAULT 0")

    for table <- @tables, event <- @events do
      signals = for surface <- @surfaces, do: {surface, signal(table, surface, event)}
      updates = Enum.map_join(signals, ", ", fn {surface, predicate} -> "#{surface} = #{surface} + (#{predicate})" end)

      execute("""
      CREATE TRIGGER sympp_dashboard_#{table}_#{event} AFTER #{event} ON sympp_#{table}
      BEGIN
        UPDATE sympp_dashboard_revisions SET #{updates};
      END
      """)
    end
  end

  def down do
    # Ecto also loads this file on its own when rolling back a single version.
    unless Code.ensure_loaded?(TrackDashboardRevisions) do
      Code.require_file("20261122020000_track_dashboard_revisions.exs", __DIR__)
    end

    TrackDashboardRevisions.drop_triggers()
    execute("ALTER TABLE sympp_dashboard_revisions DROP COLUMN detail")
    execute("ALTER TABLE sympp_dashboard_revisions DROP COLUMN deferred")
    TrackDashboardRevisions.install_triggers()
  end

  # Inspectors still read full details, including decisions and contract fields
  # that the board omits. They watch a revision without constructing a board.
  defp signal(_table, "detail", _event), do: "1"

  defp signal(table, surface, event) do
    case rules(table, surface) do
      [] -> "0"
      rules -> Enum.map_join(rules, " OR ", &"(#{condition(&1, event)})")
    end
  end

  defp condition({fields, matches}, :update), do: "(#{changed(fields)}) AND ((#{matches.("OLD")}) OR (#{matches.("NEW")}))"
  defp condition({_fields, matches}, :insert), do: matches.("NEW")
  defp condition({_fields, matches}, :delete), do: matches.("OLD")

  defp changed(fields), do: Enum.map_join(fields, " OR ", &~s(OLD."#{&1}" IS NOT NEW."#{&1}"))

  defp rules("work_requests", surface) do
    fields =
      case surface do
        "native" -> @request_identity ++ ~w(report)
        web when web in @web_execution -> @request_card ++ ~w(report)
        _listing -> @request_card
      end

    [{fields, &in_scope(surface, &1 <> ".archived_at")}, {["repo"], &"#{&1}.repo IS NOT NULL AND #{&1}.repo != ''"}]
  end

  defp rules("work_packages", surface) do
    fields =
      case surface do
        "priority" -> @package_phase
        web when web in @web_execution -> @package_fields ++ ~w(goal)
        _other -> @package_fields
      end

    [{fields, &request_scope(surface, "#{&1}.work_request_id")}, {~w(repo inserted_at), &"#{&1}.repo IS NOT NULL AND #{&1}.repo != ''"}]
  end

  defp rules("work_package_deliveries", surface) do
    fields = if surface == "priority", do: @delivery_phase, else: @delivery_fields
    [{fields, &package_scope(surface, "#{&1}.work_package_id")}]
  end

  defp rules("progress_events", "priority"), do: [lineage_rule("priority")]

  defp rules("progress_events", surface) do
    [
      lineage_rule(surface),
      {~w(id work_package_id summary body status sequence created_at inserted_at actor_id actor_type agent_run_id payload), &package_scope(surface, "#{&1}.work_package_id")}
    ]
  end

  defp rules("asks", surface) when surface in ~w(priority archived) do
    [{~w(work_request_id state), &"#{&1}.state IS 'open' AND #{request_scope(surface, "#{&1}.work_request_id")}"}]
  end

  defp rules("asks", surface) do
    request =
      if surface == "native" do
        {@ask_fields, &"#{&1}.state IS 'open' AND #{request_scope(surface, "#{&1}.work_request_id")}"}
      else
        {@ask_fields ++ @ask_delivery, &request_scope(surface, "#{&1}.work_request_id")}
      end

    [request, {@ask_fields ++ @ask_delivery ++ ~w(card_id), &"#{&1}.state IS 'open' AND #{card_scope("#{&1}.card_id")}"}]
  end

  defp rules("work_request_decision_logs", "archived") do
    [{~w(work_request_id), &request_scope("archived", "#{&1}.work_request_id")}]
  end

  defp rules("work_request_decision_logs", "priority"), do: []

  defp rules("work_request_decision_logs", surface) do
    [
      {~w(id work_request_id sequence decision rationale scope_impact created_at flagged review_state
         feedback reviewed_at undelivered_reason recorded_by_address), &"#{&1}.flagged AND (#{&1}.review_state IS 'recorded' OR #{&1}.undelivered_reason IS NOT NULL)
         AND #{request_scope(surface, "#{&1}.work_request_id")}"}
    ]
  end

  defp rules("operator_settings", "archived"), do: []
  defp rules("operator_settings", surface) when surface in ~w(native deferred), do: [{~w(card_retention_days), fn _row -> "1" end}]
  defp rules("operator_settings", _surface), do: [{@settings, fn _row -> "1" end}]

  defp rules("cards", surface) when surface in ~w(live native deferred) do
    [{~w(id state title repository base_branch branch pr review stale ended_at inserted_at updated_at), &visible_card/1}]
  end

  defp rules("worked_on", surface) when surface in @execution do
    workers = {@ownership, &"#{&1}.subject_kind IS 'work_package' AND #{&1}.role IS 'worker' AND #{package_scope(surface, "#{&1}.subject_id")}"}

    if surface == "archived" do
      [workers]
    else
      [
        workers,
        {@ownership, &"#{&1}.subject_kind IS 'work_request' AND #{&1}.state IS 'live' AND #{request_scope(surface, "#{&1}.subject_id")}"},
        {@ownership, &"#{&1}.subject_kind IS 'card' AND #{card_scope("#{&1}.subject_id")}"}
      ]
    end
  end

  defp rules(table, surface) when is_map_key(@package_details, table) and surface in @execution do
    [{Map.fetch!(@package_details, table), &package_scope(surface, "#{&1}.work_package_id")}]
  end

  defp rules(table, surface) when is_map_key(@graphs, table) and surface in @execution do
    [{Map.fetch!(@graphs, table), &request_scope(surface, "#{&1}.work_request_id")}]
  end

  defp rules(_table, _surface), do: []

  # A lineage record can link to a displayed package from outside its request.
  defp lineage_rule(surface) do
    {~w(id work_package_id status payload created_at),
     fn row ->
       endpoints = [
         "#{row}.work_package_id",
         "json_extract(#{row}.payload, '$.source_work_package_id')",
         "json_extract(#{row}.payload, '$.target_work_package_id')"
       ]

       scope = Enum.map_join(endpoints, " OR ", &package_scope(surface, &1))
       "#{row}.status IS 'operational_lineage_recorded' AND (#{scope})"
     end}
  end

  defp package_scope(surface, id), do: request_scope(surface, "(SELECT work_request_id FROM sympp_work_packages WHERE id = #{id})")

  defp request_scope(surface, id) do
    "EXISTS (SELECT 1 FROM sympp_work_requests WHERE id = #{id} AND #{in_scope(surface, "archived_at")})"
  end

  defp in_scope("archived", archived_at), do: "#{archived_at} IS NOT NULL"
  defp in_scope("native", _archived_at), do: "1"
  defp in_scope(_live, archived_at), do: "#{archived_at} IS NULL"

  defp card_scope(id), do: "EXISTS (SELECT 1 FROM sympp_cards AS card WHERE card.id = #{id} AND (#{visible_card("card")}))"

  defp visible_card(row) do
    days = "coalesce((SELECT card_retention_days FROM sympp_operator_settings LIMIT 1), #{Settings.default_card_retention_days()})"
    "#{row}.state IN ('working', 'review_ci') OR julianday(#{row}.ended_at) >= julianday('now') - #{days}"
  end
end
