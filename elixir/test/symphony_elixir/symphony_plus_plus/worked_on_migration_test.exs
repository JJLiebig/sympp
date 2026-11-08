defmodule SymphonyElixir.SymphonyPlusPlus.WorkedOnMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations

  @migration_version 20_261_108_140_000
  @previous_version 20_261_108_130_000

  # Setup runs in the test process, so the dynamic repo stays selected for the test.
  setup do
    database_path = Path.join(System.tmp_dir!(), "sympp-worked-on-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    # The repo is linked to the test process and stops with it.
    on_exit(fn -> File.rm(database_path) end)

    assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)
    seed!()
    assert @migration_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)

    _ = original_repo
    :ok
  end

  test "the operator report is folded onto the WorkRequest before the anchors are deleted" do
    assert [[report_json]] = rows!("SELECT report FROM sympp_work_requests WHERE id = 'wr_reported'")
    report = Jason.decode!(report_json)

    assert report["brief"] == %{"text" => "Second brief", "written_at" => "2026-11-02T10:00:00Z"}
    refute Map.has_key?(report, "eta")
    assert report["parking"] == %{"reason" => "Waiting on CI", "parked_at" => "2026-11-01T11:00:00Z", "resumed_at" => "2026-11-02T10:00:00Z"}
    assert report["pending_ask"] == %{"question" => "Ship to prod?", "raised_at" => "2026-11-02T10:00:00Z"}
    assert report["updated_at"] == "2026-11-02T10:00:00Z"

    assert [[nil]] = rows!("SELECT report FROM sympp_work_requests WHERE id = 'wr_quiet'")
  end

  test "deleting the anchors leaves nothing pointing at them and keeps real packages" do
    assert [[0]] = rows!("SELECT COUNT(*) FROM sympp_work_packages WHERE kind = 'delegation'")
    assert [[0]] = rows!("SELECT COUNT(*) FROM sympp_phases WHERE id LIKE 'phase-wr-architect-%'")
    assert [[0]] = rows!("SELECT COUNT(*) FROM sympp_progress_events WHERE work_package_id LIKE 'SYMPP-WR-ARCH-%'")
    assert [["WP-REAL"]] = rows!("SELECT id FROM sympp_work_packages")
    assert [["progress-real"]] = rows!("SELECT id FROM sympp_progress_events")
    assert [] = rows!("PRAGMA foreign_key_check")
  end

  test "a WorkRequest can have only one live owner" do
    insert_owner = fn id, terminal ->
      Repo.query(
        "INSERT INTO sympp_worked_on (id, subject_kind, subject_id, terminal_key, display_address, role, state, started_at, inserted_at, updated_at) VALUES (?1, 'work_request', 'wr_reported', ?2, ?2, 'architect', 'live', '2026-11-08T00:00:00Z', '2026-11-08T00:00:00Z', '2026-11-08T00:00:00Z')",
        [id, terminal]
      )
    end

    assert {:ok, _} = insert_owner.("wo_one", "core/t1")
    assert {:error, %Exqlite.Error{}} = insert_owner.("wo_two", "core/t2")
  end

  defp seed! do
    for {id, title} <- [{"wr_reported", "Reported"}, {"wr_quiet", "Quiet"}] do
      Repo.query!(
        "INSERT INTO sympp_work_requests (id, title, repo, base_branch, work_type, human_description, constraints, desired_dispatch_shape, status, inserted_at, updated_at) VALUES (?1, ?2, 'nextide/demo', 'main', 'feature', 'x', '{}', 'single_package', 'sliced', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')",
        [id, title]
      )

      phase = "phase-wr-architect-" <> suffix(id)
      anchor = "SYMPP-WR-ARCH-" <> suffix(id)
      Repo.query!("INSERT INTO sympp_phases (id, title, status, inserted_at, updated_at) VALUES (?1, 'Architect', 'active', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')", [phase])
      insert_package!(anchor, nil, "delegation", "planning", phase)
    end

    insert_package!("WP-REAL", "wr_reported", "standard_pr", "planned", nil)
    anchor = "SYMPP-WR-ARCH-" <> suffix("wr_reported")

    [
      {1, "2026-11-01T10:00:00Z", "grant-a", %{"brief" => "First brief", "eta" => "Friday"}},
      {2, "2026-11-01T11:00:00Z", "grant-a", %{"parking" => %{"reason" => "Waiting on CI"}}},
      # Ignored: written without an architect grant.
      {3, "2026-11-01T12:00:00Z", nil, %{"brief" => "Unattributed"}},
      # Ignored: not a valid patch.
      {4, "2026-11-01T13:00:00Z", "grant-a", %{"brief" => "   "}},
      {5, "2026-11-02T10:00:00Z", "grant-a", %{"brief" => "Second brief", "eta" => nil, "parking" => nil, "human_escalation" => %{"question" => "Ship to prod?"}}}
    ]
    |> Enum.each(fn {sequence, created_at, grant, patch} ->
      payload = Map.merge(patch, %{"type" => "architect_operator_report", "source_tool" => "architect_operator_report"})

      Repo.query!(
        "INSERT INTO sympp_progress_events (id, work_package_id, summary, status, sequence, created_at, inserted_at, updated_at, actor_type, access_grant_id, payload) VALUES (?1, ?2, 'report', 'recorded', ?3, ?4, ?4, ?4, 'architect', ?5, ?6)",
        ["report-#{sequence}", anchor, sequence, created_at, grant, Jason.encode!(payload)]
      )
    end)

    Repo.query!(
      "INSERT INTO sympp_progress_events (id, work_package_id, summary, status, sequence, created_at, inserted_at, updated_at, access_grant_id, payload) VALUES ('progress-real', 'WP-REAL', 'note', 'recorded', 1, '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', 'grant-w', '{}')"
    )
  end

  defp insert_package!(id, work_request_id, kind, status, phase_id) do
    Repo.query!(
      "INSERT INTO sympp_work_packages (id, work_request_id, kind, title, goal, repo, base_branch, branch_pattern, engineering_scope, acceptance_criteria, status, phase_id, inserted_at, updated_at) VALUES (?1, ?2, ?3, 'Package', 'Goal', 'nextide/demo', 'main', 'agent/x', 'Scope', '[\"done\"]', ?4, ?5, '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')",
      [id, work_request_id, kind, status, phase_id]
    )
  end

  defp suffix(work_request_id), do: :sha256 |> :crypto.hash([work_request_id]) |> Base.url_encode64(padding: false) |> binary_part(0, 16)

  defp rows!(sql), do: Repo.query!(sql).rows
end
