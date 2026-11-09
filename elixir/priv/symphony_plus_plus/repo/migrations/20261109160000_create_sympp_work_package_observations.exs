defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkPackageObservations do
  use Ecto.Migration

  # The Observer keeps its last snapshot of each watched package here: the
  # GitHub PR it watches, the Review Suite cycle and which inputs are stale.
  # Comparing against the stored snapshot, rather than an in-memory one, keeps
  # a restart from replaying transitions. Starts empty.
  def up do
    create table(:sympp_work_package_observations, primary_key: false) do
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), primary_key: true)
      add(:pr, :map)
      add(:review, :map)
      add(:stale, :text, null: false, default: "[]")
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
