defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppWorkPackageCiOverride do
  use Ecto.Migration

  # `ci_override`: an architect's recorded decision to qualify one PR head
  # without known CI (`reason`, `by`, `head`). A new head clears it; existing
  # packages have none.
  #
  # `sympp_repositories_with_ci`: GitHub repositories (lowercase `owner/name`)
  # where a recorded PR snapshot has reported checks. Kept apart from package
  # history so retention can't erase it; filled from the snapshots recorded so far.
  def up do
    alter table(:sympp_work_packages) do
      add(:ci_override, :map)
    end

    create table(:sympp_repositories_with_ci, primary_key: false) do
      add(:repository, :text, primary_key: true)
    end

    execute("""
    INSERT OR IGNORE INTO sympp_repositories_with_ci (repository)
    SELECT DISTINCT lower(json_extract(payload, '$.repository'))
    FROM sympp_progress_events
    WHERE status = 'pr_synced'
      AND json_extract(payload, '$.repository') IS NOT NULL
      AND json_extract(payload, '$.check_summary.status') IN ('passing', 'failing', 'pending')
    """)
  end

  def down do
    drop(table(:sympp_repositories_with_ci))

    alter table(:sympp_work_packages) do
      remove(:ci_override)
    end
  end
end
