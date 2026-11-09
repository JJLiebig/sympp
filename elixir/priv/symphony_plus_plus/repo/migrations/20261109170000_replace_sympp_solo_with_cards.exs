defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.ReplaceSymppSoloWithCards do
  use Ecto.Migration

  # Cards replace Solo Sessions. A card is a terminal's own piece of work
  # (branch, PR, CI, review), observed by the factory; its terminal works on it
  # through a `sympp_worked_on` row with subject `card`. Solo Sessions and their
  # entries are dropped without export. The Solo retention setting becomes the
  # card retention setting and keeps its value. Asks gain a card subject, so
  # an ask names either a WorkRequest or a card.
  def up do
    drop(table(:sympp_solo_session_entries))
    drop(table(:sympp_solo_sessions))

    rename(table(:sympp_operator_settings), :solo_session_delete_after_days, to: :card_retention_days)

    create table(:sympp_cards, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:terminal_key, :text, null: false)
      add(:state, :text, null: false)
      add(:title, :text)
      add(:cwd, :text)
      add(:repository, :text)
      add(:base_branch, :text)
      add(:branch, :text)
      add(:pr, :map)
      add(:review_id, :text)
      add(:review, :map)
      add(:stale, :text, null: false, default: "[]")
      add(:ended_at, :utc_datetime_usec)
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_cards, [:terminal_key]))
    create(index(:sympp_cards, [:state, :ended_at]))

    # SQLite can't relax NOT NULL in place, so the asks table is rebuilt with
    # an optional WorkRequest and the new card subject.
    create table(:sympp_asks_next, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all))
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all))
      add(:card_id, references(:sympp_cards, type: :text, on_delete: :delete_all))
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

    flush()

    execute("""
    INSERT INTO sympp_asks_next (id, work_request_id, work_package_id, question, decision_prompt, state, asked_by_terminal,
      asked_by_address, answer, answered_by, resolved_at, delivered_at, inserted_at, updated_at)
    SELECT id, work_request_id, work_package_id, question, decision_prompt, state, asked_by_terminal,
      asked_by_address, answer, answered_by, resolved_at, delivered_at, inserted_at, updated_at
    FROM sympp_asks
    """)

    drop(table(:sympp_asks))
    rename(table(:sympp_asks_next), to: table(:sympp_asks))

    create(index(:sympp_asks, [:work_request_id, :state]))
    create(index(:sympp_asks, [:work_package_id], where: "work_package_id IS NOT NULL"))
    create(index(:sympp_asks, [:card_id, :state], where: "card_id IS NOT NULL"))
  end

  def down do
    raise Ecto.MigrationError, message: "Solo Sessions were dropped and cannot be restored"
  end
end
