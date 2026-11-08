defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  import Ecto.Query, only: [from: 2]

  @type repo :: module()
  @type error ::
          :database_busy
          | :not_found
          | :id_already_exists
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> WorkPackage.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
    |> notify_dashboard(repo)
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkPackage, id) do
      nil -> {:error, :not_found}
      work_package -> {:ok, work_package}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list(repo) when is_atom(repo) do
    work_packages =
      repo.all(
        from(work_package in WorkPackage,
          order_by: [asc: work_package.inserted_at, asc: work_package.id]
        )
      )

    {:ok, work_packages}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_phase(repo(), String.t()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list_for_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    work_packages =
      repo.all(
        from(work_package in WorkPackage,
          where: work_package.phase_id == ^phase_id,
          order_by: [asc: work_package.inserted_at, asc: work_package.id]
        )
      )

    {:ok, work_packages}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    repo
    |> update_directly(id, attrs)
    |> notify_dashboard(repo)
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_directly(repo, id, attrs) do
    with {:ok, work_package} <- get(repo, id) do
      work_package
      |> WorkPackage.update_changeset(attrs)
      |> repo.update()
    end
  end

  defp notify_dashboard({:ok, %WorkPackage{}} = result, repo) do
    unless repo.in_transaction?(), do: DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_dashboard(result, _repo), do: result

  defp normalize_insert_result({:ok, work_package}), do: {:ok, work_package}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_work_packages_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_work_packages_id_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
