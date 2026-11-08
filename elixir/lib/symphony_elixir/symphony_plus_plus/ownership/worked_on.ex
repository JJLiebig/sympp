defmodule SymphonyElixir.SymphonyPlusPlus.Ownership.WorkedOn do
  @moduledoc """
  One terminal working on one subject. At most one `live` row exists per
  subject (partial unique index `sympp_worked_on_one_live_per_subject_index`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @subject_kinds ["work_request", "work_package", "card"]
  @roles ["chief", "architect", "worker", "card"]
  @finish_reasons ["terminal_finished", "subject_ended", "taken_over", "released_by_operator"]

  @type t :: %__MODULE__{}

  schema "sympp_worked_on" do
    field(:subject_kind, :string)
    field(:subject_id, :string)
    field(:terminal_key, :string)
    field(:display_address, :string)
    field(:role, :string)
    field(:domain, :string)
    field(:state, :string)
    field(:finish_reason, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @spec subject_kinds() :: [String.t()]
  def subject_kinds, do: @subject_kinds

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec finish_reasons() :: [String.t()]
  def finish_reasons, do: @finish_reasons
end
