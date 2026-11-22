defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.IndexOperationalLineage do
  use Ecto.Migration

  def change do
    create(
      index(:sympp_progress_events, [:status, :created_at, :sequence, :id],
        name: :sympp_progress_events_lineage_index,
        where: "status = 'operational_lineage_recorded'"
      )
    )
  end
end
