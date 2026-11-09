defmodule SymphonyElixir.SymphonyPlusPlus.AsksMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations

  @migration_version 20_261_109_140_000
  @previous_version 20_261_109_130_000

  # Setup runs in the test process, so the dynamic repo stays selected for the test.
  setup do
    database_path = Path.join(System.tmp_dir!(), "sympp-asks-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    _original_repo = Repo.put_dynamic_repo(pid)
    on_exit(fn -> File.rm(database_path) end)

    assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)
    seed!()
    assert @migration_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @migration_version, log: false)
    :ok
  end

  test "clarification questions become asks under their own ids" do
    assert [
             ["wrq_answered", "wr_one", "Which region?\n\nWhy: Pricing differs.", "answered", "Europe", "operator-1", "2026-11-02T00:00:00Z"],
             ["wrq_closed", "wr_one", "Ship it?", "withdrawn", nil, nil, "2026-11-03T00:00:00Z"],
             ["wrq_open", "wr_one", "Name the flag?", "open", nil, nil, nil]
           ] = rows!("SELECT id, work_request_id, question, state, answer, answered_by, resolved_at FROM sympp_asks WHERE id LIKE 'wrq_%' ORDER BY id")

    assert [[prompt]] = rows!("SELECT decision_prompt FROM sympp_asks WHERE id = 'wrq_open'")
    assert %{"tl_dr" => "Pick one"} = Jason.decode!(prompt)
    assert [[0]] = rows!("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('sympp_work_request_clarification_questions', 'sympp_findings')")
  end

  test "a pending escalation in the report becomes an open ask and leaves the report" do
    assert [[ask_id, "Ship to prod?", "open", nil, asked_at]] =
             rows!("SELECT id, question, state, asked_by_terminal, inserted_at FROM sympp_asks WHERE work_request_id = 'wr_two'")

    assert "ask_" <> _ = ask_id
    assert String.starts_with?(asked_at, "2026-11-04T10:00:00")

    assert [[report]] = rows!("SELECT report FROM sympp_work_requests WHERE id = 'wr_two'")
    assert Jason.decode!(report) == %{"brief" => %{"text" => "Brief", "written_at" => "2026-11-04T10:00:00Z"}, "updated_at" => "2026-11-04T10:00:00Z"}
  end

  test "an open ask on an archived WorkRequest is withdrawn" do
    assert [["withdrawn", "subject_ended"]] = rows!("SELECT state, answered_by FROM sympp_asks WHERE work_request_id = 'wr_archived'")
  end

  test "older blocker events are relabelled to set_blocker and other events are untouched" do
    assert [
             ["evt_note", nil],
             ["evt_raise", "set_blocker"],
             ["evt_resolve", "set_blocker"]
           ] = rows!("SELECT id, json_extract(payload, '$.source_tool') FROM sympp_progress_events ORDER BY id")
  end

  defp seed! do
    for id <- ["wr_one", "wr_two", "wr_archived"] do
      Repo.query!(
        "INSERT INTO sympp_work_requests (id, title, repo, base_branch, work_type, human_description, constraints, desired_dispatch_shape, inserted_at, updated_at) VALUES (?1, 'Title', 'nextide/demo', 'main', 'feature', 'x', '{}', 'single_package', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')",
        [id]
      )
    end

    report = %{
      "brief" => %{"text" => "Brief", "written_at" => "2026-11-04T10:00:00Z"},
      "pending_ask" => %{"question" => " Ship to prod? ", "raised_at" => "2026-11-04T10:00:00Z"},
      "updated_at" => "2026-11-04T10:00:00Z"
    }

    Repo.query!("UPDATE sympp_work_requests SET report = ?1 WHERE id = 'wr_two'", [Jason.encode!(report)])
    Repo.query!("UPDATE sympp_work_requests SET report = ?1, archived_at = '2026-11-05T00:00:00Z' WHERE id = 'wr_archived'", [Jason.encode!(report)])

    [
      {"wrq_open", 1, "Name the flag?", "", "open", nil, nil, nil, "2026-11-01T00:00:00Z", Jason.encode!(%{"tl_dr" => "Pick one"})},
      {"wrq_answered", 2, "Which region?", "Pricing differs.", "answered", "Europe", "operator-1", "2026-11-02T00:00:00Z", "2026-11-02T00:00:00Z", nil},
      {"wrq_closed", 3, "Ship it?", " ", "closed", nil, nil, nil, "2026-11-03T00:00:00Z", nil}
    ]
    |> Enum.each(fn {id, sequence, question, why, status, answer, answered_by, answered_at, updated_at, prompt} ->
      Repo.query!(
        "INSERT INTO sympp_work_request_clarification_questions (id, work_request_id, sequence, category, question, why_needed, status, answer, answered_by, answered_at, decision_prompt, inserted_at, updated_at) VALUES (?1, 'wr_one', ?2, 'scope', ?3, ?4, ?5, ?6, ?7, ?8, ?9, '2026-11-01T00:00:00Z', ?10)",
        [id, sequence, question, why, status, answer, answered_by, answered_at, prompt, updated_at]
      )
    end)

    Repo.query!(
      "INSERT INTO sympp_work_packages (id, work_request_id, kind, title, goal, repo, base_branch, branch_pattern, engineering_scope, acceptance_criteria, status, inserted_at, updated_at) VALUES ('WP-ONE', 'wr_one', 'standard_pr', 'Package', 'Goal', 'nextide/demo', 'main', 'agent/x', 'Scope', '[\"done\"]', 'dispatched', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')"
    )

    [
      {"evt_raise", 1, %{"type" => "blocker", "source_tool" => "report_blocker", "blocker_id" => "b1", "active" => true}},
      {"evt_resolve", 2, %{"type" => "blocker", "source_tool" => "resolve_blocker", "blocker_id" => "b1", "active" => false}},
      {"evt_note", 3, %{}}
    ]
    |> Enum.each(fn {id, sequence, payload} ->
      Repo.query!(
        "INSERT INTO sympp_progress_events (id, work_package_id, summary, status, sequence, created_at, inserted_at, updated_at, payload) VALUES (?1, 'WP-ONE', 'event', 'recorded', ?2, '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', ?3)",
        [id, sequence, Jason.encode!(payload)]
      )
    end)
  end

  defp rows!(sql), do: Repo.query!(sql).rows
end
