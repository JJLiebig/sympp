defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DropSymppGuidanceRequestsAndComments do
  use Ecto.Migration

  def up do
    drop(table(:sympp_guidance_requests))
    drop(table(:sympp_comments))
  end

  def down do
    raise Ecto.MigrationError, message: "guidance requests and comments were removed and cannot be restored"
  end
end
