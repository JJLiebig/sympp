defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Finding do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          severity: String.t() | nil,
          sequence: non_neg_integer() | nil,
          idempotency_key: String.t() | nil,
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_findings" do
    field(:work_package_id, :string)
    field(:title, :string)
    field(:body, :string)
    field(:severity, :string)
    field(:sequence, :integer)
    field(:idempotency_key, :string)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> normalize_idempotency_key()
      |> put_new_value("id", stable_id("finding"))
      |> put_new_value("severity", "info")
      |> put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :work_package_id,
      :title,
      :body,
      :severity,
      :sequence,
      :idempotency_key,
      :created_at
    ])
    |> validate_required([:id, :work_package_id, :title, :body, :severity, :sequence, :created_at])
    |> validate_number(:sequence, greater_than_or_equal_to: 1)
    |> validate_nonblank_optional(:idempotency_key)
    |> unique_constraint(:id, name: :sympp_findings_id_unique_index)
    |> unique_constraint(:idempotency_key, name: :sympp_findings_scoped_idempotency_key_unique_index)
    |> foreign_key_constraint(:work_package_id)
  end

  defp validate_nonblank_optional(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "" do
        [{field, "cannot be blank"}]
      else
        []
      end
    end)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalize_idempotency_key(attrs) do
    Map.update(attrs, "idempotency_key", nil, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id(prefix) do
    Id.random(prefix)
  end
end
