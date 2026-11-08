defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CollapseSymppWorkPackageStatuses do
  use Ecto.Migration

  # WorkPackages keep four stored statuses: planned, dispatched, ready and ended.
  # The ending row in sympp_work_package_deliveries is the only record of how a
  # package ended. Architect anchors (kind "delegation") are left untouched.
  def up do
    alter table(:sympp_work_package_deliveries) do
      add(:legacy_status, :text)
    end

    flush()

    # Ended packages without an ending row get one. Skipped packages get the row
    # skip_work_package would have written, so replaying that call stays
    # idempotent; merged, closed and abandoned packages keep their old status as
    # the migration-only "legacy" outcome.
    execute("""
    INSERT INTO sympp_work_package_deliveries (
      id, work_request_id, work_package_id, outcome, idempotency_key, recorded_by,
      recorded_at, legacy_status, inserted_at, updated_at
    )
    SELECT
      'wrsd_lifecycle_' || package.id,
      package.work_request_id,
      package.id,
      CASE package.status WHEN 'skipped' THEN 'skipped' ELSE 'legacy' END,
      CASE package.status WHEN 'skipped' THEN 'skip_work_package:' ELSE 'lifecycle_migration:' END || package.id,
      CASE package.status WHEN 'skipped' THEN NULL ELSE 'lifecycle_migration' END,
      package.updated_at,
      CASE package.status WHEN 'skipped' THEN NULL ELSE package.status END,
      package.updated_at,
      package.updated_at
    FROM sympp_work_packages AS package
    WHERE package.kind <> 'delegation'
      AND package.work_request_id IS NOT NULL
      AND package.status IN ('merged', 'closed', 'abandoned', 'skipped')
      AND NOT EXISTS (
        SELECT 1 FROM sympp_work_package_deliveries AS delivery
        WHERE delivery.work_package_id = package.id
      )
    """)

    execute("""
    UPDATE sympp_work_packages
    SET status = CASE
      WHEN status IN ('merged', 'closed', 'abandoned', 'skipped') THEN 'ended'
      WHEN EXISTS (
        SELECT 1 FROM sympp_work_package_deliveries AS delivery
        WHERE delivery.work_package_id = sympp_work_packages.id
      ) THEN 'ended'
      WHEN status = 'ready_for_merge' THEN 'ready'
      WHEN status IN (
        'created', 'ready_for_worker', 'active', 'claimed', 'planning',
        'implementing', 'reviewing', 'ci_waiting', 'blocked'
      ) THEN 'dispatched'
      ELSE status
    END
    WHERE kind <> 'delegation'
    """)
  end

  def down do
    raise Ecto.MigrationError, message: "the legacy WorkPackage statuses were removed and cannot be restored"
  end
end
