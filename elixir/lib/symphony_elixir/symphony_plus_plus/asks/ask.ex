defmodule SymphonyElixir.SymphonyPlusPlus.Asks.Ask do
  @moduledoc """
  One question for the operator on a WorkRequest, optionally naming one of its
  packages. `asked_by_terminal` is the asking Herdr terminal's key (core id
  plus address); asks carried over from older records have none.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @states ["open", "answered", "withdrawn"]

  @type t :: %__MODULE__{}

  schema "sympp_asks" do
    field(:work_request_id, :string)
    field(:work_package_id, :string)
    field(:question, :string)
    field(:decision_prompt, :map)
    field(:state, :string)
    field(:asked_by_terminal, :string)
    field(:asked_by_address, :string)
    field(:answer, :string)
    field(:answered_by, :string)
    field(:resolved_at, :utc_datetime_usec)
    field(:delivered_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [String.t()]
  def states, do: @states
end
