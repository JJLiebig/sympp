defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackageStatusMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations

  @migration_version 20_261_108_130_000
  @previous_version 20_261_108_120_200

  test "collapses statuses to four and gives every ended package exactly one ending row" do
    database_path =
      Path.join(System.tmp_dir!(), "sympp-wp-status-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")

    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)

      seed!()
      recorded_before = rows!("SELECT * FROM sympp_work_package_deliveries WHERE id = 'D-MERGED'")

      assert @migration_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)

      assert Map.new(rows!("SELECT id, status FROM sympp_work_packages"), &List.to_tuple/1) == %{
               "WP-PLANNED" => "planned",
               "WP-CREATED" => "dispatched",
               "WP-QUEUED" => "dispatched",
               "WP-BLOCKED" => "dispatched",
               "WP-REVIEWING" => "dispatched",
               "WP-READY" => "ready",
               "WP-MERGED-ROW" => "ended",
               "WP-MERGED" => "ended",
               "WP-CLOSED" => "ended",
               "WP-ABANDONED" => "ended",
               "WP-SKIPPED" => "ended",
               "ANCHOR" => "planning"
             }

      assert rows!("""
             SELECT work_package_id, outcome, legacy_status, idempotency_key, recorded_by
             FROM sympp_work_package_deliveries ORDER BY work_package_id
             """) == [
               ["WP-ABANDONED", "legacy", "abandoned", "lifecycle_migration:WP-ABANDONED", "lifecycle_migration"],
               ["WP-CLOSED", "legacy", "closed", "lifecycle_migration:WP-CLOSED", "lifecycle_migration"],
               ["WP-MERGED", "legacy", "merged", "lifecycle_migration:WP-MERGED", "lifecycle_migration"],
               ["WP-MERGED-ROW", "pr_merged", nil, "recorded-merge", "architect"],
               ["WP-SKIPPED", "skipped", nil, "skip_work_package:WP-SKIPPED", nil]
             ]

      assert rows!("SELECT * FROM sympp_work_package_deliveries WHERE id = 'D-MERGED'") == Enum.map(recorded_before, &(&1 ++ [nil]))
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  defp seed! do
    now = "2026-11-01T00:00:00.000000Z"

    Repo.insert_all("sympp_work_requests", [
      %{
        id: "WR",
        title: "Migration",
        repo: "nextide/example",
        base_branch: "main",
        work_type: "feature",
        human_description: "Status migration.",
        constraints: "{}",
        desired_dispatch_shape: "single_package",
        status: "sliced",
        inserted_at: now,
        updated_at: now
      }
    ])

    packages =
      [
        {"WP-PLANNED", "planned"},
        {"WP-CREATED", "created"},
        {"WP-QUEUED", "ready_for_worker"},
        {"WP-BLOCKED", "blocked"},
        {"WP-REVIEWING", "reviewing"},
        {"WP-READY", "ready_for_merge"},
        {"WP-MERGED-ROW", "merged"},
        {"WP-MERGED", "merged"},
        {"WP-CLOSED", "closed"},
        {"WP-ABANDONED", "abandoned"},
        {"WP-SKIPPED", "skipped"}
      ]
      |> Enum.map(fn {id, status} -> package_row(id, "standard_pr", "WR", status, now) end)

    Repo.insert_all("sympp_work_packages", [package_row("ANCHOR", "delegation", nil, "planning", now) | packages])

    Repo.insert_all("sympp_work_package_deliveries", [
      %{
        id: "D-MERGED",
        work_request_id: "WR",
        work_package_id: "WP-MERGED-ROW",
        outcome: "pr_merged",
        idempotency_key: "recorded-merge",
        recorded_by: "architect",
        recorded_at: now,
        pr_url: "https://github.com/nextide/example/pull/1",
        pr_merged_at: now,
        merge_commit_sha: String.duplicate("a", 40),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp package_row(id, kind, work_request_id, status, now) do
    %{
      id: id,
      work_request_id: work_request_id,
      kind: kind,
      title: id,
      repo: "nextide/example",
      base_branch: "main",
      acceptance_criteria: "[\"Migrated.\"]",
      allowed_file_globs: "[]",
      forbidden_file_globs: "[]",
      validation_steps: "[]",
      stop_conditions: "[]",
      contract_revision: 1,
      status: status,
      inserted_at: now,
      updated_at: now
    }
  end

  defp rows!(sql), do: Repo.query!(sql).rows
end
