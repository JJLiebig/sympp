defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppWorkPackageCiOverride do
  use Ecto.Migration

  # An architect's recorded decision to qualify one PR head without known CI:
  # `reason`, `by` (the terminal) and `head`. A new head clears it. Existing
  # packages have none.
  def change do
    alter table(:sympp_work_packages) do
      add(:ci_override, :map)
    end
  end
end
