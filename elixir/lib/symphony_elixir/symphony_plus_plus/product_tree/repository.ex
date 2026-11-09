defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Attrs, DependencyEdge, Revision}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @revision_number_retry_count 3
  @tree_read_chunk_size 400
  @revision_number_unique_index "sympp_product_tree_revisions_work_request_revision_unique_index"
  @id_collision_constraints [
    "sympp_product_tree_dependency_edges_pkey",
    "sympp_product_tree_dependency_edges_id_index",
    "sympp_product_tree_dependency_edges_id_unique_index",
    "sympp_product_tree_revisions_pkey",
    "sympp_product_tree_revisions_id_index",
    "sympp_product_tree_revisions_id_unique_index"
  ]
  @sqlite_primary_key_messages [
    "unique constraint failed: sympp_product_tree_dependency_edges.id",
    "unique constraint failed: sympp_product_tree_revisions.id"
  ]

  @type repo :: module()
  @type error ::
          :not_found
          | :database_busy
          | :id_already_exists
          | {:constraint_failed, String.t()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec tree_for_work_request(repo(), String.t()) ::
          {:ok,
           %{
             dependency_edges: [DependencyEdge.t()],
             latest_revision: Revision.t() | nil
           }}
          | {:error, error()}
  def tree_for_work_request(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    {:ok,
     %{
       dependency_edges: list_dependency_edges!(repo, work_request_id),
       latest_revision: latest_revision!(repo, work_request_id)
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec trees_for_work_requests(repo(), [String.t()]) :: {:ok, %{optional(String.t()) => map()}} | {:error, error()}
  def trees_for_work_requests(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    work_request_ids = Enum.uniq(work_request_ids)

    edges_by_request = list_dependency_edges_for_work_requests!(repo, work_request_ids)
    revisions_by_request = latest_revisions_for_work_requests!(repo, work_request_ids)

    {:ok,
     Map.new(work_request_ids, fn work_request_id ->
       {work_request_id,
        %{
          dependency_edges: Map.get(edges_by_request, work_request_id, []),
          latest_revision: Map.get(revisions_by_request, work_request_id)
        }}
     end)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_dependency_edge(repo(), map()) :: {:ok, DependencyEdge.t()} | {:error, error()}
  def create_dependency_edge(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_dependency_edge_scope(repo, attrs) do
      attrs
      |> DependencyEdge.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec record_revision(repo(), String.t(), map()) :: {:ok, Revision.t()} | {:error, error()}
  def record_revision(repo, work_request_id, attrs) when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    record_revision(repo, work_request_id, attrs, @revision_number_retry_count)
  end

  defp record_revision(repo, work_request_id, attrs, attempts_left) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("revision_number", next_revision_number(repo, work_request_id))

    case repo.insert(Revision.create_changeset(attrs)) do
      {:ok, revision} ->
        {:ok, revision}

      {:error, %Changeset{} = changeset} = error ->
        if revision_number_conflict?(changeset) and attempts_left > 0 do
          record_revision(repo, work_request_id, attrs, attempts_left - 1)
        else
          normalize_insert_result(error)
        end
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_dependency_edges!(repo, work_request_id) do
    repo.all(
      from(edge in DependencyEdge,
        where: edge.work_request_id == ^work_request_id,
        order_by: [asc: edge.kind, asc: edge.created_at, asc: edge.id]
      )
    )
  end

  defp latest_revision!(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        order_by: [desc: revision.revision_number],
        limit: 1
      )
    )
  end

  defp list_dependency_edges_for_work_requests!(repo, work_request_ids) do
    work_request_ids
    |> tree_read_chunks()
    |> Enum.flat_map(fn work_request_id_chunk ->
      repo.all(
        from(edge in DependencyEdge,
          where: edge.work_request_id in ^work_request_id_chunk,
          order_by: [asc: edge.work_request_id, asc: edge.kind, asc: edge.created_at, asc: edge.id]
        )
      )
    end)
    |> Enum.group_by(& &1.work_request_id)
  end

  defp latest_revisions_for_work_requests!(repo, work_request_ids) do
    work_request_ids
    |> tree_read_chunks()
    |> Enum.flat_map(fn work_request_id_chunk ->
      ranked_revisions =
        from(revision in Revision,
          where: revision.work_request_id in ^work_request_id_chunk,
          windows: [
            latest: [
              partition_by: [revision.work_request_id],
              order_by: [desc: revision.revision_number]
            ]
          ],
          select: %{id: revision.id, row_number: over(row_number(), :latest)}
        )

      repo.all(
        from(revision in Revision,
          join: ranked_revision in subquery(ranked_revisions),
          on: ranked_revision.id == revision.id,
          where: ranked_revision.row_number == 1,
          select: %{
            id: revision.id,
            work_request_id: revision.work_request_id,
            revision_number: revision.revision_number,
            reason: revision.reason,
            decision_ref: revision.decision_ref,
            created_by: revision.created_by,
            created_at: revision.created_at
          }
        )
      )
    end)
    |> Enum.map(&struct(Revision, &1))
    |> Map.new(&{&1.work_request_id, &1})
  end

  defp tree_read_chunks(work_request_ids), do: Enum.chunk_every(work_request_ids, @tree_read_chunk_size)

  defp validate_dependency_edge_scope(repo, %{"work_request_id" => work_request_id} = attrs) when is_binary(work_request_id) and work_request_id != "" do
    with :ok <- validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "source_kind"), Map.get(attrs, "source_id"), "source") do
      validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "target_kind"), Map.get(attrs, "target_id"), "target")
    end
  end

  defp validate_dependency_edge_scope(_repo, _attrs), do: :ok

  defp validate_dependency_endpoint_scope(repo, work_request_id, "work_package", id, label) do
    validate_record_scope(repo, WorkPackage, id, work_request_id, "product_tree_dependency_#{label}_scope")
  end

  defp validate_dependency_endpoint_scope(_repo, _work_request_id, _kind, _id, _label), do: :ok

  defp validate_record_scope(_repo, _schema, id, _work_request_id, _constraint) when id in [nil, ""], do: :ok

  defp validate_record_scope(repo, schema, id, work_request_id, constraint) do
    case repo.get(schema, id) do
      nil -> {:error, {:constraint_failed, constraint}}
      %{work_request_id: ^work_request_id} -> :ok
      _record -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp next_revision_number(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        select: max(revision.revision_number)
      )
    )
    |> case do
      number when is_integer(number) -> number + 1
      _number -> 1
    end
  end

  defp normalize_insert_result({:ok, record}), do: {:ok, record}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset), do: {:error, :id_already_exists}, else: {:error, changeset}
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp revision_number_conflict?(%Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        Keyword.get(options, :constraint) == :unique and
          Keyword.get(options, :constraint_name) == @revision_number_unique_index
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when constraint in @id_collision_constraints,
    do: {:error, :id_already_exists}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint),
    do: {:error, {:constraint_failed, constraint}}

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}), do: {:error, {:constraint_failed, Atom.to_string(type)}}

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    cond do
      Enum.any?(@sqlite_primary_key_messages, &String.contains?(normalized_message, &1)) ->
        {:error, :id_already_exists}

      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") ->
        {:error, :database_busy}

      true ->
        {:error, {:storage_failed, message}}
    end
  end
end
