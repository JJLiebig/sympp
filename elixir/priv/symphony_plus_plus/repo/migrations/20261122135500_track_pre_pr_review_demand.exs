defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.TrackPrePrReviewDemand do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_package_observations) do
      add(:pr_absent, :boolean, null: false, default: false)
    end
  end
end
