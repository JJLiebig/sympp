defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppFailedCalls do
  use Ecto.Migration

  # Failed MCP tool calls are counted durably and always: one row per UTC day,
  # tool, reason and layer, with a count and the last time it happened. No
  # argument is ever stored. The operator setting that switched the old
  # process-local capture on is dropped.
  def up do
    create table(:sympp_failed_calls, primary_key: false) do
      add(:day, :date, null: false)
      add(:tool, :text, null: false)
      add(:reason, :text, null: false)
      add(:layer, :text, null: false)
      add(:count, :integer, null: false, default: 0)
      add(:last_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:sympp_failed_calls, [:day, :tool, :reason, :layer]))

    alter table(:sympp_operator_settings) do
      remove(:capture_failed_mcp_calls)
    end
  end
end
