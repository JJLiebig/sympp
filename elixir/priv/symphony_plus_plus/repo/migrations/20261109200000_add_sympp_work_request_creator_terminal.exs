defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSymppWorkRequestCreatorTerminal do
  use Ecto.Migration

  # The Herdr terminal that created a WorkRequest, by key (core id plus
  # address), so a flagged decision can be sent to the chief that created it.
  # Display addresses aren't identities: core names are local aliases.
  # Existing WorkRequests keep it empty.
  def change do
    alter table(:sympp_work_requests) do
      add(:creator_terminal, :text)
    end
  end
end
