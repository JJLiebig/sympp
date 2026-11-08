defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DeriveSymppWorkRequestPhase do
  use Ecto.Migration

  # A WorkRequest's phase is derived on read from its packages and their ending
  # rows. Only the operator overrides stay stored: operator completion and the
  # archive. `restored_at` (formerly `never_started_restored_at`) records the
  # operator's last restore, which restarts both retention clocks.
  def up do
    alter table(:sympp_work_requests) do
      add(:operator_completed_at, :utc_datetime_usec)
    end

    flush()

    execute("""
    UPDATE sympp_work_requests
    SET operator_completed_at = completed_at
    WHERE completion_source = 'operator' AND completed_at IS NOT NULL
    """)

    drop_if_exists(index(:sympp_work_requests, [:status, :repo, :base_branch], name: :sympp_work_requests_status_repo_base_branch_index))
    drop_if_exists(index(:sympp_work_requests, [:status], name: :sympp_work_requests_status_index))

    rename(table(:sympp_work_requests), :never_started_restored_at, to: :restored_at)

    alter table(:sympp_work_requests) do
      remove(:status)
      remove(:completed_at)
      remove(:completion_source)
    end
  end

  def down do
    raise Ecto.MigrationError, message: "stored WorkRequest statuses were removed and cannot be restored"
  end
end
