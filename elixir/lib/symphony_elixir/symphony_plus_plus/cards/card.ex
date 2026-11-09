defmodule SymphonyElixir.SymphonyPlusPlus.Cards.Card do
  @moduledoc """
  One terminal's card: its state and the factory's last observation of its
  work (repository, branch, PR, Review Suite cycle). The id is derived from the
  terminal key; the terminal works on the card through a `sympp_worked_on` row
  with subject `card`.
  """

  use Ecto.Schema

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:id, :string, autogenerate: false}

  @states ["working", "review_ci", "merged", "done", "dismissed"]

  @type t :: %__MODULE__{}

  schema "sympp_cards" do
    field(:terminal_key, :string)
    field(:state, :string)
    field(:title, :string)
    field(:cwd, :string)
    field(:repository, :string)
    field(:base_branch, :string)
    field(:branch, :string)
    field(:pr, :map)
    field(:review_id, :string)
    field(:review, :map)
    field(:stale, StringList, default: [])
    field(:ended_at, :utc_datetime_usec)
    field(:observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [String.t()]
  def states, do: @states
end
