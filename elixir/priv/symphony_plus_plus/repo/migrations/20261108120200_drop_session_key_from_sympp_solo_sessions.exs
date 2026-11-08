defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DropSessionKeyFromSymppSoloSessions do
  use Ecto.Migration

  def up do
    alter table(:sympp_solo_sessions) do
      remove(:session_key)
    end
  end

  def down do
    raise Ecto.MigrationError, message: "Solo session keys were removed and cannot be restored"
  end
end
