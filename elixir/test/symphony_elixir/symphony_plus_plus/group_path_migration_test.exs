defmodule SymphonyElixir.SymphonyPlusPlus.GroupPathMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations

  @migration_version 20_261_109_120_000
  @previous_version 20_261_108_150_000
  @now "2026-11-01T00:00:00.000000Z"
  @sha String.duplicate("a", 40)

  test "groups become paths, group dependencies become package dependencies, and package rows keep their children" do
    database_path =
      Path.join(System.tmp_dir!(), "sympp-group-paths-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")

    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)
      seed!()

      assert @migration_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)

      assert rows!(~s|SELECT id, "group" FROM sympp_work_packages ORDER BY id|) == [
               ["WP-BACKEND", "Backend"],
               ["WP-BILLING", "Backend / Billing"],
               ["WP-CYCLE", "Loop A / Loop B"],
               ["WP-LOOSE", nil],
               ["WP-UI", "UI / UX"]
             ]

      # Backend depended on WP-LOOSE, and UI/UX on Backend and (pinned) on
      # WP-BACKEND: each becomes the package dependencies it stood for. Every
      # old constraint stays its own dependency, so the package dependency
      # Billing already had is kept beside the one from its group.
      assert rows!("SELECT source_id, target_id, candidate_head_sha, selection_updated_at FROM sympp_product_tree_dependency_edges ORDER BY source_id, target_id, candidate_head_sha") == [
               ["WP-BACKEND", "WP-LOOSE", nil, nil],
               ["WP-BILLING", "WP-LOOSE", nil, nil],
               ["WP-BILLING", "WP-LOOSE", nil, nil],
               ["WP-UI", "WP-BACKEND", nil, nil],
               ["WP-UI", "WP-BACKEND", @sha, @now],
               ["WP-UI", "WP-BILLING", nil, nil]
             ]

      # The input WP-UI consumed under the pinned group dependency follows it.
      [[pinned_id]] = rows!("SELECT id FROM sympp_product_tree_dependency_edges WHERE candidate_head_sha IS NOT NULL")
      [[payload]] = rows!("SELECT payload FROM sympp_progress_events WHERE id = 'progress-ui-input'")

      assert %{"dependency_inputs" => [%{"dependency_id" => ^pinned_id, "prerequisite_work_package_id" => "WP-BACKEND"}]} =
               Jason.decode!(payload)

      assert [[0]] = rows!("SELECT count(*) FROM sympp_product_tree_dependency_edges WHERE source_kind <> 'work_package' OR target_kind <> 'work_package'")
      assert [] = rows!("SELECT name FROM sqlite_master WHERE name = 'sympp_product_tree_nodes'")
      refute "product_tree_node_id" in Enum.map(rows!("PRAGMA table_info(sympp_work_packages)"), &Enum.at(&1, 1))

      # Rows that reference packages with ON DELETE CASCADE survive the rebuild.
      assert [["plan-billing", "WP-BILLING"]] = rows!("SELECT id, work_package_id FROM sympp_plan_nodes")
      assert [] = rows!("PRAGMA foreign_key_check")

      assert [] = Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  defp seed! do
    Repo.query!(
      "INSERT INTO sympp_work_requests (id, title, repo, base_branch, work_type, human_description, constraints, desired_dispatch_shape, inserted_at, updated_at) VALUES ('WR-GROUPS', 'Groups', 'nextide/demo', 'main', 'feature', 'Fixture.', '{}', 'single_package', ?1, ?1)",
      [@now]
    )

    node!("N-BACKEND", nil, "Backend")
    node!("N-BILLING", "N-BACKEND", " Billing ")
    node!("N-UI", nil, "UI/UX")
    node!("N-LOOP-A", nil, "Loop A")
    node!("N-LOOP-B", "N-LOOP-A", "Loop B")
    Repo.query!("UPDATE sympp_product_tree_nodes SET parent_id = 'N-LOOP-B' WHERE id = 'N-LOOP-A'")

    package!("WP-BACKEND", 1, "N-BACKEND")
    package!("WP-BILLING", 2, "N-BILLING")
    package!("WP-UI", 3, "N-UI")
    package!("WP-LOOSE", 4, nil)
    package!("WP-CYCLE", 5, "N-LOOP-B")

    edge!("E-BACKEND-ON-LOOSE", "product_node", "N-BACKEND", "work_package", "WP-LOOSE")
    edge!("E-UI-ON-BACKEND", "product_node", "N-UI", "product_node", "N-BACKEND")
    edge!("E-EXISTING", "work_package", "WP-BILLING", "work_package", "WP-LOOSE")

    Repo.query!(
      "INSERT INTO sympp_product_tree_dependency_edges (id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, candidate_head_sha, selection_updated_at, created_at, inserted_at, updated_at) VALUES ('E-UI-PINNED', 'WR-GROUPS', 'product_node', 'N-UI', 'work_package', 'WP-BACKEND', 'depends_on', 'Fixture.', ?1, ?2, ?2, ?2, ?2)",
      [@sha, @now]
    )

    inputs =
      Jason.encode!(%{
        "head_sha" => String.duplicate("c", 40),
        "dependency_inputs" => [%{"dependency_id" => "E-UI-PINNED", "prerequisite_work_package_id" => "WP-BACKEND", "candidate_head_sha" => @sha}]
      })

    Repo.query!(
      "INSERT INTO sympp_progress_events (id, work_package_id, summary, status, sequence, payload, created_at, inserted_at, updated_at) VALUES ('progress-ui-input', 'WP-UI', 'Consumed', 'recorded', 1, ?1, ?2, ?2, ?2)",
      [inputs, @now]
    )

    Repo.query!(
      "INSERT INTO sympp_plan_nodes (id, work_package_id, title, status, position, created_at, inserted_at, updated_at) VALUES ('plan-billing', 'WP-BILLING', 'Step', 'pending', 0, ?1, ?1, ?1)",
      [@now]
    )
  end

  defp node!(id, parent_id, title) do
    Repo.query!(
      "INSERT INTO sympp_product_tree_nodes (id, work_request_id, parent_id, title, completion_mark, metadata, position, created_at, inserted_at, updated_at) VALUES (?1, 'WR-GROUPS', ?2, ?3, 'unknown', '{}', 0, ?4, ?4, ?4)",
      [id, parent_id, title, @now]
    )
  end

  defp package!(id, sequence, node_id) do
    Repo.query!(
      "INSERT INTO sympp_work_packages (id, work_request_id, product_tree_node_id, sequence, kind, title, goal, repo, base_branch, acceptance_criteria, status, inserted_at, updated_at) VALUES (?1, 'WR-GROUPS', ?2, ?3, 'standard_pr', ?1, 'Goal', 'nextide/demo', 'main', '[\"done\"]', 'planned', ?4, ?4)",
      [id, node_id, sequence, @now]
    )
  end

  defp edge!(id, source_kind, source_id, target_kind, target_id) do
    Repo.query!(
      "INSERT INTO sympp_product_tree_dependency_edges (id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, created_at, inserted_at, updated_at) VALUES (?1, 'WR-GROUPS', ?2, ?3, ?4, ?5, 'depends_on', 'Fixture.', ?6, ?6, ?6)",
      [id, source_kind, source_id, target_kind, target_id, @now]
    )
  end

  defp rows!(sql), do: Repo.query!(sql).rows
end
