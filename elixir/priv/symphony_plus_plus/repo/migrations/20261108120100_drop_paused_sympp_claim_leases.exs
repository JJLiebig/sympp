defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DropPausedSymppClaimLeases do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE sympp_claim_leases
    SET status = 'released',
        released_at = COALESCE(paused_at, updated_at),
        release_reason = COALESCE(release_reason, 'paused_claim_removed')
    WHERE status = 'paused'
    """)

    drop(unique_index(:sympp_claim_leases, [:work_package_id], name: :sympp_claim_leases_one_current_per_work_package_index))

    create(
      unique_index(:sympp_claim_leases, [:work_package_id],
        where: "status = 'active'",
        name: :sympp_claim_leases_one_current_per_work_package_index
      )
    )

    alter table(:sympp_claim_leases) do
      remove(:paused_at)
      remove(:paused_by_actor_id)
      remove(:pause_reason)
    end
  end

  def down do
    raise Ecto.MigrationError, message: "the paused claim state was removed and cannot be restored"
  end
end
