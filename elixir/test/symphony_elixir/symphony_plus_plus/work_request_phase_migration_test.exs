defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestPhaseMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations

  @migration_version 20_261_108_140_000
  @previous_version 20_261_108_130_000

  test "keeps only operator completion, the archive and the last restore, and drops stored status and completion" do
    database_path =
      Path.join(System.tmp_dir!(), "sympp-wr-phase-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")

    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)

      Repo.insert_all("sympp_work_requests", [
        request("WR-OPERATOR", "sliced", completed_at: "2026-11-02T00:00:00.000000Z", completion_source: "operator"),
        request("WR-DERIVED", "sliced", completed_at: "2026-11-03T00:00:00.000000Z", archived_at: "2026-11-06T00:00:00.000000Z", archive_reason: "age"),
        request("WR-RESTORED", "human_info_needed", never_started_restored_at: "2026-11-04T00:00:00.000000Z"),
        request("WR-OPEN", "draft")
      ])

      assert @migration_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)

      columns = Enum.map(Repo.query!("PRAGMA table_info(sympp_work_requests)").rows, &Enum.at(&1, 1))
      assert "operator_completed_at" in columns
      assert "restored_at" in columns
      for removed <- ["status", "completed_at", "completion_source", "never_started_restored_at"], do: refute(removed in columns)

      assert Repo.query!("SELECT id, operator_completed_at, archived_at, archive_reason, restored_at FROM sympp_work_requests ORDER BY id").rows == [
               ["WR-DERIVED", nil, "2026-11-06T00:00:00.000000Z", "age", nil],
               ["WR-OPEN", nil, nil, nil, nil],
               ["WR-OPERATOR", "2026-11-02T00:00:00.000000Z", nil, nil, nil],
               ["WR-RESTORED", nil, nil, nil, "2026-11-04T00:00:00.000000Z"]
             ]

      assert [] = Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  defp request(id, status, overrides \\ []) do
    now = "2026-11-01T00:00:00.000000Z"

    Map.merge(
      %{
        id: id,
        title: id,
        repo: "nextide/example",
        base_branch: "main",
        work_type: "feature",
        human_description: "Migration fixture.",
        constraints: "{}",
        desired_dispatch_shape: "single_package",
        status: status,
        completed_at: nil,
        completion_source: nil,
        archived_at: nil,
        archive_reason: nil,
        never_started_restored_at: nil,
        inserted_at: now,
        updated_at: now
      },
      Map.new(overrides)
    )
  end
end
