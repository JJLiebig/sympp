defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppWorkPackageLaunch do
  use Ecto.Migration

  # Dispatch records how the worker reviews its change and where it runs:
  # `review_mode` (fast, normal, deep or none), the Review Suite id minted for
  # the package, and the Herdr machine named in the launch line. Packages
  # dispatched before this never had an id minted, so they review in mode none.
  def up do
    alter table(:sympp_work_packages) do
      add(:review_mode, :string)
      add(:review_id, :string)
      add(:launch_machine, :string)
    end

    flush()

    execute("""
    UPDATE sympp_work_packages
    SET review_mode = 'none'
    WHERE status IN ('dispatched', 'ready')
    """)

    create(unique_index(:sympp_work_packages, [:review_id], where: "review_id IS NOT NULL", name: :sympp_work_packages_review_id_index))
  end
end
