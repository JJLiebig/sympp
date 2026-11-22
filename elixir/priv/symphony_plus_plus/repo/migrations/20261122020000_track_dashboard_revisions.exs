defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.TrackDashboardRevisions do
  use Ecto.Migration

  # Requests and packages share a repository identity catalog across boards.
  # Deliveries also feed the phase summary used by both request lists.
  @shared ~w(work_requests work_packages work_package_deliveries)
  @package_details ~w(agent_runs artifacts plan_nodes work_package_observations)
  @request_details ~w(product_tree_dependency_edges product_tree_revisions work_request_decision_logs)
  @tables @shared ++ @package_details ++ @request_details ++ ~w(asks cards operator_settings progress_events worked_on)
  @events [insert: ["NEW"], update: ["OLD", "NEW"], delete: ["OLD"]]

  def up do
    execute("""
    CREATE TABLE sympp_dashboard_revisions (
      priority INTEGER NOT NULL, archived INTEGER NOT NULL, live INTEGER NOT NULL, native INTEGER NOT NULL
    )
    """)

    execute("INSERT INTO sympp_dashboard_revisions VALUES (0, 0, 0, 0)")

    install_triggers()
  end

  def down do
    drop_triggers()
    execute("DROP TABLE sympp_dashboard_revisions")
  end

  def install_triggers do
    for table <- @tables, {event, rows} <- @events do
      updates =
        Enum.map_join(~w(priority archived live native), ", ", fn surface ->
          affects = Enum.map_join(rows, " OR ", &"(#{affects(table, surface, &1)})")
          "#{surface} = #{surface} + (#{affects})"
        end)

      execute("""
      CREATE TRIGGER sympp_dashboard_#{table}_#{event} AFTER #{event} ON sympp_#{table}
      BEGIN
        UPDATE sympp_dashboard_revisions SET #{updates};
      END
      """)
    end
  end

  def drop_triggers do
    for table <- @tables, {event, _rows} <- @events do
      execute("DROP TRIGGER sympp_dashboard_#{table}_#{event}")
    end
  end

  defp affects(_table, "native", _row), do: "1"
  defp affects(table, _surface, _row) when table in @shared, do: "1"
  defp affects("operator_settings", surface, _row), do: if(surface == "archived", do: "0", else: "1")
  defp affects("cards", surface, _row), do: if(surface == "live", do: "1", else: "0")

  # Lineage relationships may link packages across requests and affect phases.
  defp affects("progress_events", "priority", row), do: lineage?(row)

  defp affects("progress_events", surface, row),
    do: "#{lineage?(row)} OR #{package_scope(surface, "#{row}.work_package_id")}"

  defp affects("asks", "priority", row),
    do: "#{row}.state IS 'open' AND #{row}.work_request_id IS NOT NULL AND #{request_scope("live", "#{row}.work_request_id")}"

  defp affects(_table, "priority", _row), do: "0"

  defp affects(table, surface, row) when table in @package_details,
    do: package_scope(surface, "#{row}.work_package_id")

  defp affects(table, surface, row) when table in @request_details or table == "asks",
    do: request_scope(surface, "#{row}.work_request_id")

  defp affects("worked_on", surface, row) do
    """
    (#{row}.subject_kind IS 'work_package' AND #{package_scope(surface, "#{row}.subject_id")}) OR
    (#{row}.subject_kind IS 'work_request' AND #{request_scope(surface, "#{row}.subject_id")}) OR
    (#{row}.subject_kind IS 'card' AND #{if(surface == "live", do: 1, else: 0)})
    """
  end

  defp lineage?(row), do: "#{row}.status IS 'operational_lineage_recorded'"

  defp package_scope(surface, package_id) do
    request_scope(surface, "(SELECT work_request_id FROM sympp_work_packages WHERE id = #{package_id})")
  end

  defp request_scope(surface, request_id) do
    archived = "EXISTS (SELECT 1 FROM sympp_work_requests WHERE id = #{request_id} AND archived_at IS NOT NULL)"
    if surface == "archived", do: archived, else: "NOT #{archived}"
  end
end
