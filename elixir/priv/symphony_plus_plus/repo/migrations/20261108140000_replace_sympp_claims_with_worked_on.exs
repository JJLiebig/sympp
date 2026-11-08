defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.ReplaceSymppClaimsWithWorkedOn do
  use Ecto.Migration

  # Ownership becomes "worked on by <terminal>": one sympp_worked_on row per
  # (subject, terminal), with at most one live row per subject. Claims, leases,
  # grants, session bindings, chief registrations and session locations are
  # dropped; no authority is carried over.
  #
  # The architect operator report moves from progress events on the hidden
  # architect anchor package to sympp_work_requests.report. It is folded first,
  # then the anchors and their phases are deleted.

  @anchor_prefix "SYMPP-WR-ARCH-"
  @phase_prefix "phase-wr-architect-"
  @report_fields ["brief", "eta", "parking", "human_escalation"]

  def up do
    create table(:sympp_worked_on, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:subject_kind, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:terminal_key, :text, null: false)
      add(:display_address, :text, null: false)
      add(:role, :text, null: false)
      add(:domain, :text)
      add(:state, :text, null: false)
      add(:finish_reason, :text)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:sympp_worked_on, [:subject_kind, :subject_id],
        where: "state = 'live'",
        name: :sympp_worked_on_one_live_per_subject_index
      )
    )

    create(index(:sympp_worked_on, [:terminal_key, :state]))

    alter table(:sympp_work_requests) do
      add(:report, :map)
    end

    flush()

    fold_operator_reports()

    execute("DELETE FROM sympp_work_packages WHERE kind = 'delegation' AND id LIKE '#{@anchor_prefix}%'")
    execute("DELETE FROM sympp_phases WHERE id LIKE '#{@phase_prefix}%'")

    drop(table(:sympp_mcp_session_bindings))
    drop(table(:sympp_claim_leases))
    drop_agent_run_grant_column()
    drop(table(:sympp_access_grant_scopes))
    drop(table(:sympp_access_grants))
    drop(table(:sympp_chief_registrations))
    drop(table(:sympp_session_locations))

    alter table(:sympp_progress_events) do
      remove(:access_grant_id)
    end

    alter table(:sympp_findings) do
      remove(:access_grant_id)
    end
  end

  def down do
    raise Ecto.MigrationError, message: "claims, grants, bindings, chief registrations and architect anchors were removed and cannot be restored"
  end

  # The report is the fold of every valid architect_operator_report patch on the
  # WorkRequest's anchor, in sequence order. An open human escalation is kept as
  # report.pending_ask until asks exist; a resolved one is dropped.
  defp fold_operator_reports do
    %{rows: work_requests} = repo().query!("SELECT id FROM sympp_work_requests")

    %{rows: events} =
      repo().query!("""
      SELECT work_package_id, payload, created_at
      FROM sympp_progress_events
      WHERE work_package_id LIKE '#{@anchor_prefix}%'
        AND actor_type = 'architect'
        AND access_grant_id IS NOT NULL AND access_grant_id <> ''
        AND json_extract(payload, '$.type') = 'architect_operator_report'
        AND json_extract(payload, '$.source_tool') = 'architect_operator_report'
      ORDER BY work_package_id, sequence
      """)

    events_by_anchor = Enum.group_by(events, &Enum.at(&1, 0), fn [_id, payload, created_at] -> {Jason.decode!(payload), created_at} end)

    for [work_request_id] <- work_requests,
        report = fold(Map.get(events_by_anchor, anchor_id(work_request_id), [])),
        report != nil do
      repo().query!("UPDATE sympp_work_requests SET report = ?1 WHERE id = ?2", [Jason.encode!(report), work_request_id])
    end
  end

  defp fold(events) do
    events
    |> Enum.filter(fn {payload, _created_at} -> valid_patch?(payload) end)
    |> Enum.reduce(%{}, fn {payload, created_at}, report ->
      written_at = timestamp(created_at)

      payload
      |> Map.take(@report_fields)
      |> Enum.reduce(report, fn {field, value}, acc -> apply_field(acc, field, value, written_at) end)
      |> Map.put("updated_at", written_at)
    end)
    |> case do
      %{} = report when map_size(report) <= 1 -> nil
      report -> report
    end
  end

  defp apply_field(report, field, nil, _written_at) when field in ["brief", "eta"], do: Map.delete(report, field)
  defp apply_field(report, field, text, written_at) when field in ["brief", "eta"], do: Map.put(report, field, %{"text" => String.trim(text), "written_at" => written_at})

  defp apply_field(report, "parking", nil, written_at) do
    case report["parking"] do
      %{"resumed_at" => nil} = parking -> Map.put(report, "parking", %{parking | "resumed_at" => written_at})
      _closed_or_missing -> report
    end
  end

  defp apply_field(report, "parking", %{"reason" => reason}, written_at) do
    parked_at =
      case report["parking"] do
        %{"resumed_at" => nil, "parked_at" => parked_at} -> parked_at
        _closed_or_missing -> written_at
      end

    Map.put(report, "parking", %{"reason" => String.trim(reason), "parked_at" => parked_at, "resumed_at" => nil})
  end

  defp apply_field(report, "human_escalation", nil, _written_at), do: Map.delete(report, "pending_ask")

  defp apply_field(report, "human_escalation", %{"question" => question}, written_at) do
    raised_at = get_in(report, ["pending_ask", "raised_at"]) || written_at
    Map.put(report, "pending_ask", %{"question" => String.trim(question), "raised_at" => raised_at})
  end

  defp valid_patch?(payload) when is_map(payload) do
    payload
    |> Map.take(@report_fields)
    |> Enum.all?(fn
      {_field, nil} -> true
      {field, text} when field in ["brief", "eta"] -> nonblank?(text)
      {"parking", %{"reason" => reason}} -> nonblank?(reason)
      {"human_escalation", %{"question" => question}} -> nonblank?(question)
      _invalid -> false
    end)
  end

  defp valid_patch?(_payload), do: false

  defp nonblank?(text), do: is_binary(text) and String.trim(text) != ""

  defp timestamp(value) when is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    DateTime.to_iso8601(datetime)
  end

  defp anchor_id(work_request_id) do
    suffix =
      :sha256
      |> :crypto.hash([work_request_id])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    @anchor_prefix <> suffix
  end

  # SQLite cannot drop a column that carries a foreign key, so agent runs are
  # rebuilt without access_grant_id.
  defp drop_agent_run_grant_column do
    execute("""
    CREATE TABLE "sympp_agent_runs_new" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "work_package_id" TEXT NOT NULL CONSTRAINT "sympp_agent_runs_work_package_id_fkey" REFERENCES "sympp_work_packages"("id") ON DELETE CASCADE,
      "actor_id" TEXT, "status" TEXT NOT NULL, "attempt" INTEGER DEFAULT 0 NOT NULL,
      "worker_host" TEXT, "worker_task_handle" TEXT, "workspace_path" TEXT, "session_id" TEXT,
      "codex_input_tokens" INTEGER DEFAULT 0 NOT NULL, "codex_output_tokens" INTEGER DEFAULT 0 NOT NULL,
      "codex_total_tokens" INTEGER DEFAULT 0 NOT NULL, "turn_count" INTEGER DEFAULT 0 NOT NULL,
      "started_at" TEXT NOT NULL, "last_seen_at" TEXT NOT NULL, "finished_at" TEXT, "reason" TEXT,
      "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO sympp_agent_runs_new
    SELECT id, work_package_id, actor_id, status, attempt, worker_host, worker_task_handle, workspace_path,
      session_id, codex_input_tokens, codex_output_tokens, codex_total_tokens, turn_count, started_at,
      last_seen_at, finished_at, reason, inserted_at, updated_at
    FROM sympp_agent_runs
    """)

    execute("DROP TABLE sympp_agent_runs")
    execute("ALTER TABLE sympp_agent_runs_new RENAME TO sympp_agent_runs")
    execute(~s|CREATE UNIQUE INDEX "sympp_agent_runs_id_unique_index" ON "sympp_agent_runs" ("id")|)
    execute(~s|CREATE INDEX "sympp_agent_runs_work_package_id_index" ON "sympp_agent_runs" ("work_package_id")|)

    execute(~s|CREATE UNIQUE INDEX "sympp_agent_runs_one_active_per_work_package_index" ON "sympp_agent_runs" ("work_package_id") WHERE status IN ('starting', 'running', 'retrying')|)
  end
end
