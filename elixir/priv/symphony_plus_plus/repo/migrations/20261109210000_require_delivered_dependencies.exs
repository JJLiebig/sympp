defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.RequireDeliveredDependencies do
  use Ecto.Migration

  # A dependency is met only by delivered work, so dependency edges no longer
  # pin a candidate head of an unmerged prerequisite. Progress events that
  # recorded consumed inputs stay as history and are no longer read.
  #
  # The Observer stores which packages' unmerged commits a PR carries
  # (`stacked_on`); it starts empty and is filled on the next sweep.
  def up do
    alter table(:sympp_product_tree_dependency_edges) do
      remove(:candidate_head_sha)
      remove(:selection_updated_at)
    end

    alter table(:sympp_work_package_observations) do
      add(:stacked_on, :text, null: false, default: "[]")
    end
  end

  def down do
    raise Ecto.MigrationError, message: "candidate pins on dependency edges were removed and cannot be restored"
  end
end
