defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DropSymppWorkRequestRepoScopes do
  use Ecto.Migration

  # A WorkRequest no longer declares secondary repositories up front: each
  # WorkPackage names its own repo and base branch.
  def up do
    drop(table(:sympp_work_request_repo_scopes))
  end
end
