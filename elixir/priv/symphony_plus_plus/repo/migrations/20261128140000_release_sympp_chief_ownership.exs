defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.ReleaseSymppChiefOwnership do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE sympp_worked_on
    SET state = 'finished',
        finish_reason = 'chief_ownership_released',
        finished_at = STRFTIME('%Y-%m-%d %H:%M:%f000', 'now'),
        updated_at = STRFTIME('%Y-%m-%d %H:%M:%f000', 'now')
    WHERE subject_kind = 'work_request' AND role = 'chief' AND state = 'live'
    """)
  end

  def down do
    raise Ecto.MigrationError, message: "released chief ownership may already have been taken by an architect"
  end
end
