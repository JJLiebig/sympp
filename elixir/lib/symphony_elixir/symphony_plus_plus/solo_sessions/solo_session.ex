defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ["active", "paused", "completed", "archived"]
  @current_statuses ["active", "paused"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          workspace_path: String.t() | nil,
          caller_id: String.t() | nil,
          title: String.t() | nil,
          status: String.t() | nil,
          last_activity_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_solo_sessions" do
    field(:repo, :string)
    field(:base_branch, :string)
    field(:workspace_path, :string)
    field(:caller_id, :string)
    field(:title, :string)
    field(:status, :string)
    field(:last_activity_at, :utc_datetime_usec)
    field(:archived_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec current_statuses() :: [String.t()]
  def current_statuses, do: @current_statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["id", "status", "last_activity_at", "archived_at", "inserted_at", "updated_at", "created_at"])
      |> trim_text_fields(["repo", "base_branch", "workspace_path", "caller_id", "title"])
      |> Map.update("title", nil, &Redactor.redact_text/1)
      |> Map.put("id", stable_id())
      |> Map.put("status", "active")
      |> Map.put("last_activity_at", now)

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :repo,
      :base_branch,
      :workspace_path,
      :caller_id,
      :title,
      :status,
      :last_activity_at,
      :archived_at
    ])
    |> validate_required([
      :id,
      :repo,
      :base_branch,
      :workspace_path,
      :caller_id,
      :status,
      :last_activity_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:id, name: :sympp_solo_sessions_id_unique_index)
    |> unique_constraint(:repo, name: :sympp_solo_sessions_current_scope_unique_index)
    |> unique_constraint(:repo, name: :sympp_solo_sessions_repo_base_branch_workspace_path_caller_id_index)
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = solo_session, attrs) do
    solo_session
    |> cast(normalize_keys(attrs), [:status, :last_activity_at, :archived_at])
    |> validate_required([:status, :last_activity_at])
    |> validate_inclusion(:status, @statuses)
  end

  defp trim_text_fields(attrs, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      Map.update(acc, field, nil, &trim_text/1)
    end)
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(value), do: value

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp stable_id do
    Id.random("solo")
  end
end
