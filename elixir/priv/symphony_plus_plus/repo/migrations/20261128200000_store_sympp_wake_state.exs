defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.StoreSymppWakeState do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_requests) do
      add(:owner_missing, :boolean, default: false, null: false)
    end

    alter table(:sympp_product_tree_dependency_edges) do
      add(:blocker_state, :string)
    end

    create(index(:sympp_worked_on, [:subject_kind, :subject_id, :started_at]))
  end
end
