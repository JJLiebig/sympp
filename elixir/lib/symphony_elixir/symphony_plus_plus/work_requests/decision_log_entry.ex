defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @source_types ["human", "architect", "operator", "ask_pro_advisory"]
  @review_states ["recorded", "acknowledged", "feedback"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          sequence: integer() | nil,
          source_type: String.t() | nil,
          source_id: String.t() | nil,
          decision: String.t() | nil,
          rationale: String.t() | nil,
          scope_impact: String.t() | nil,
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          flagged: boolean(),
          review_state: String.t() | nil,
          feedback: String.t() | nil,
          reviewed_at: DateTime.t() | nil,
          undelivered_reason: String.t() | nil,
          recorded_by_terminal: String.t() | nil,
          recorded_by_address: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_request_decision_logs" do
    field(:work_request_id, :string)
    field(:sequence, :integer)
    field(:source_type, :string)
    field(:source_id, :string)
    field(:decision, :string)
    field(:rationale, :string)
    field(:scope_impact, :string)
    field(:created_by, :string)
    field(:created_at, :utc_datetime_usec)
    field(:flagged, :boolean, default: false)
    field(:review_state, :string)
    field(:feedback, :string)
    field(:reviewed_at, :utc_datetime_usec)
    field(:undelivered_reason, :string)
    field(:recorded_by_terminal, :string)
    field(:recorded_by_address, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec source_types() :: [String.t()]
  def source_types, do: @source_types

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_request_decision_logs_id_unique_index)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = decision, attrs) do
    decision
    |> cast(normalize_keys(attrs), [
      :id,
      :work_request_id,
      :sequence,
      :source_type,
      :source_id,
      :decision,
      :rationale,
      :scope_impact,
      :created_by,
      :created_at,
      :flagged,
      :review_state,
      :recorded_by_terminal,
      :recorded_by_address
    ])
    |> validate_required([
      :id,
      :work_request_id,
      :sequence,
      :source_type,
      :decision,
      :rationale,
      :scope_impact,
      :created_by,
      :created_at
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:review_state, @review_states)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    Id.random("wrd")
  end
end
