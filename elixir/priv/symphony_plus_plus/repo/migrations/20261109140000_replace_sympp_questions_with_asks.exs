defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.ReplaceSymppQuestionsWithAsks do
  use Ecto.Migration

  # Asks are the only "Needs you": open -> answered | withdrawn, on a
  # WorkRequest and optionally one of its packages, attributed to the asking
  # Herdr terminal. Clarification questions become asks (open -> open,
  # answered -> answered, closed -> withdrawn) under their own ids, so decisions
  # that cite a question still cite the ask. An open escalation carried in
  # report.pending_ask becomes an open ask and the key is removed. Open asks on
  # archived or operator-completed WorkRequests are withdrawn.
  #
  # Findings and free progress notes go away with their tools. Blockers keep
  # their progress events, now written only by set_blocker, so older blocker
  # events are relabelled to that writer, and one that described another
  # package moves to that package.
  def up do
    create table(:sympp_asks, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all))
      add(:question, :text, null: false)
      add(:decision_prompt, :map)
      add(:state, :text, null: false)
      add(:asked_by_terminal, :text)
      add(:asked_by_address, :text)
      add(:answer, :text)
      add(:answered_by, :text)
      add(:resolved_at, :utc_datetime_usec)
      add(:delivered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_asks, [:work_request_id, :state]))
    create(index(:sympp_asks, [:work_package_id], where: "work_package_id IS NOT NULL"))

    flush()

    execute("""
    INSERT INTO sympp_asks (id, work_request_id, question, decision_prompt, state, answer, answered_by, resolved_at, inserted_at, updated_at)
    SELECT
      id,
      work_request_id,
      CASE WHEN trim(coalesce(why_needed, '')) = '' THEN question ELSE question || char(10) || char(10) || 'Why: ' || why_needed END,
      decision_prompt,
      CASE status WHEN 'answered' THEN 'answered' WHEN 'closed' THEN 'withdrawn' ELSE 'open' END,
      answer,
      answered_by,
      CASE status WHEN 'answered' THEN coalesce(answered_at, updated_at) WHEN 'closed' THEN updated_at END,
      inserted_at,
      updated_at
    FROM sympp_work_request_clarification_questions
    """)

    move_pending_asks()

    # Archiving or completing a WorkRequest withdraws its open asks.
    execute("""
    UPDATE sympp_asks
    SET state = 'withdrawn', answered_by = 'subject_ended', resolved_at = updated_at
    WHERE state = 'open'
      AND work_request_id IN (SELECT id FROM sympp_work_requests WHERE archived_at IS NOT NULL OR operator_completed_at IS NOT NULL)
    """)

    drop(table(:sympp_work_request_clarification_questions))
    drop(table(:sympp_findings))

    move_targeted_blockers()

    execute("""
    UPDATE sympp_progress_events
    SET payload = json_set(payload, '$.source_tool', 'set_blocker')
    WHERE json_extract(payload, '$.type') = 'blocker'
      AND json_extract(payload, '$.source_tool') IN ('report_blocker', 'resolve_blocker')
    """)
  end

  def down do
    raise Ecto.MigrationError, message: "clarification questions, findings and progress notes were replaced and cannot be restored"
  end

  # A blocker recorded on one package could describe another (`blocked_item`).
  # Blockers are now package-local, so each such blocker's whole history (its
  # resolution may not repeat the target) moves to the package it describes,
  # after that package's own history. Its id is suffixed with the package it
  # came from, so it can't merge with a blocker of the same id there.
  defp move_targeted_blockers do
    %{rows: targets} =
      repo().query!("""
      SELECT event.work_package_id, json_extract(event.payload, '$.blocker_id'), json_extract(event.payload, '$.blocked_item.id'), event.id
      FROM sympp_progress_events event
      JOIN sympp_work_packages target ON target.id = json_extract(event.payload, '$.blocked_item.id')
      WHERE json_extract(event.payload, '$.type') = 'blocker'
        AND json_extract(event.payload, '$.blocked_item.kind') = 'work_package'
        AND event.work_package_id <> target.id
      ORDER BY event.work_package_id, event.sequence
      """)

    # The latest target named for a blocker wins; events without a blocker id stand alone.
    targets
    |> Enum.reduce(%{}, fn [owner_id, blocker_id, target_id, event_id], acc ->
      Map.put(acc, {owner_id, blocker_id || {:event, event_id}}, target_id)
    end)
    |> Enum.sort()
    |> Enum.each(fn {{owner_id, blocker}, target_id} -> move_blocker_history(owner_id, blocker, target_id) end)
  end

  defp move_blocker_history(owner_id, {:event, event_id}, target_id), do: move_events([event_id], owner_id, target_id, nil)

  defp move_blocker_history(owner_id, blocker_id, target_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id FROM sympp_progress_events
        WHERE work_package_id = ?1 AND json_extract(payload, '$.type') = 'blocker' AND json_extract(payload, '$.blocker_id') = ?2
        ORDER BY sequence
        """,
        [owner_id, blocker_id]
      )

    move_events(Enum.map(rows, &hd/1), owner_id, target_id, blocker_id <> "@" <> owner_id)
  end

  defp move_events(event_ids, owner_id, target_id, blocker_id) do
    for id <- event_ids do
      repo().query!(
        """
        UPDATE sympp_progress_events
        SET work_package_id = ?2,
            sequence = (SELECT coalesce(max(sequence), 0) + 1 FROM sympp_progress_events WHERE work_package_id = ?2),
            idempotency_key = CASE WHEN idempotency_key IS NULL THEN NULL ELSE idempotency_key || ':from:' || ?3 END,
            payload = json_remove(
              CASE WHEN ?4 IS NULL THEN payload ELSE json_set(payload, '$.blocker_id', ?4) END,
              '$.blocked_item', '$.blocked_by'
            )
        WHERE id = ?1
        """,
        [id, target_id, owner_id, blocker_id]
      )
    end
  end

  defp move_pending_asks do
    %{rows: rows} =
      repo().query!("""
      SELECT id, json_extract(report, '$.pending_ask.question'), json_extract(report, '$.pending_ask.raised_at')
      FROM sympp_work_requests
      WHERE json_extract(report, '$.pending_ask') IS NOT NULL
      """)

    now = DateTime.utc_now(:microsecond)

    for [work_request_id, question, raised_at] <- rows do
      if is_binary(question) and String.trim(question) != "" do
        asked_at = timestamp(raised_at) || now

        repo().query!(
          "INSERT INTO sympp_asks (id, work_request_id, question, state, inserted_at, updated_at) VALUES (?, ?, ?, 'open', ?, ?)",
          [ask_id(), work_request_id, String.trim(question), asked_at, asked_at]
        )
      end

      repo().query!("UPDATE sympp_work_requests SET report = json_remove(report, '$.pending_ask') WHERE id = ?", [work_request_id])
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp ask_id, do: "ask_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
end
