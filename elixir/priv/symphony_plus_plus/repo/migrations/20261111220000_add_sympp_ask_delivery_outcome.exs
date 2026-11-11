defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppAskDeliveryOutcome do
  use Ecto.Migration

  def change do
    alter table(:sympp_asks) do
      add(:undelivered_reason, :text)
    end
  end
end
