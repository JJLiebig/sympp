defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.TrackDashboardArchiveInputs do
  use Ecto.Migration

  @request_tables ~w(work_packages product_tree_dependency_edges product_tree_revisions)
  @package_tables ~w(progress_events plan_nodes artifacts agent_runs work_package_deliveries)
  @tables ["work_requests" | @request_tables ++ @package_tables]
  @events [insert: ["NEW"], update: ["OLD", "NEW"], delete: ["OLD"]]

  def up do
    # Reader pools come and go during dashboard builds. The token identifies
    # the input snapshot, including after opening or editing a copied ledger.
    execute("CREATE TABLE sympp_dashboard_archive_revision (revision BLOB NOT NULL)")
    execute("INSERT INTO sympp_dashboard_archive_revision VALUES (randomblob(16))")

    for table <- @tables, {event, rows} <- @events do
      affected = Enum.map_join(rows, " OR ", &affects_archive(table, &1))

      execute("""
      CREATE TRIGGER sympp_dashboard_archive_#{table}_#{event} AFTER #{event} ON sympp_#{table}
      WHEN #{affected}
      BEGIN
        UPDATE sympp_dashboard_archive_revision SET revision = randomblob(16);
      END
      """)
    end
  end

  def down do
    for table <- @tables, {event, _rows} <- @events do
      execute("DROP TRIGGER sympp_dashboard_archive_#{table}_#{event}")
    end

    execute("DROP TABLE sympp_dashboard_archive_revision")
  end

  defp affects_archive("work_requests", row), do: "#{row}.archived_at IS NOT NULL"

  defp affects_archive(table, row) when table in @request_tables,
    do: archived_request("#{row}.work_request_id")

  defp affects_archive(table, row) when table in @package_tables,
    do: archived_request("(SELECT work_request_id FROM sympp_work_packages WHERE id = #{row}.work_package_id)")

  defp archived_request(request_id),
    do: "EXISTS (SELECT 1 FROM sympp_work_requests WHERE id = #{request_id} AND archived_at IS NOT NULL)"
end
