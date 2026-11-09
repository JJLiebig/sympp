defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlanEdit do
  @moduledoc """
  Applies an ordered list of plan operations to one WorkRequest in one
  transaction. Any failing operation rolls back the whole edit and is reported
  with its index.

  Operations, each a map with an `"op"` key:

    * `add_package` - a new planned package: its contract, an optional `group`
      path, optional `depends_on` package references and an optional `key` that
      later operations in the same edit can use as a reference;
    * `update_package` - `work_package_id`, `expected_revision` and a contract
      `patch` (which may set or clear `group`);
    * `set_dependency` - `from` depends on `to`; creates the dependency or
      updates it, with an optional `candidate_head_sha` (null clears it);
    * `remove_dependency` - removes the dependency of `from` on `to`.

  A package reference is a WorkPackage id in this WorkRequest or the `key` of
  an earlier `add_package`.
  """

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Lifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @ops ["add_package", "update_package", "set_dependency", "remove_dependency"]
  @required_contract_strings ["title", "goal"]
  @required_contract_lists ["acceptance_criteria", "validation_steps", "stop_conditions"]
  @hard_edge_kinds ["depends_on", "blocks"]

  @type applied :: map()
  @type op_error :: {:op_failed, non_neg_integer(), String.t(), term()}

  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc """
  Applies `ops` in order. Returns what each operation did, in order, or the
  first failure: `{:op_failed, index, op, reason}`, or a WorkRequest-level
  reason such as `:work_request_archived`.
  """
  @spec run(module(), String.t(), [map()], String.t() | nil) :: {:ok, [applied()]} | {:error, op_error() | term()}
  def run(repo, work_request_id, ops, created_by) when is_atom(repo) and is_binary(work_request_id) and is_list(ops) do
    repo.transaction(fn ->
      with :ok <- require_authoring(repo, work_request_id),
           {:ok, applied} <- apply_ops(repo, work_request_id, ops, created_by) do
        applied
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp require_authoring(repo, work_request_id) do
    case repo.get(WorkRequest, work_request_id) do
      nil -> {:error, :not_found}
      %WorkRequest{operator_completed_at: %DateTime{}, archived_at: nil} -> {:error, {:work_request_terminal, "done"}}
      %WorkRequest{} = work_request -> Phase.require_writable(work_request)
    end
  end

  defp apply_ops(repo, work_request_id, ops, created_by) do
    context = %{repo: repo, work_request_id: work_request_id, created_by: created_by, keys: %{}}

    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, context, []}, fn {op, index}, {:ok, context, applied} ->
      case apply_op(op, context) do
        {:ok, context, result} -> {:cont, {:ok, context, [result | applied]}}
        {:error, reason} -> {:halt, {:error, {:op_failed, index, op_name(op), reason}}}
      end
    end)
    |> case do
      {:ok, _context, applied} -> {:ok, Enum.reverse(applied)}
      {:error, _reason} = error -> error
    end
  end

  defp op_name(%{"op" => op}) when op in @ops, do: op
  defp op_name(_op), do: nil

  defp apply_op(%{"op" => "add_package"} = op, context) do
    contract = Map.drop(op, ["op", "key", "depends_on"])

    with {:ok, key} <- optional_key(op, context),
         {:ok, prerequisite_refs} <- string_list(op, "depends_on"),
         :ok <- require_complete_contract(contract),
         {:ok, prerequisite_ids} <- resolve_all(prerequisite_refs, context),
         {:ok, work_package} <- Repository.add_work_package(context.repo, context.work_request_id, contract),
         :ok <- add_dependencies(work_package.id, prerequisite_ids, context) do
      context = if key, do: put_in(context, [:keys, key], work_package.id), else: context
      {:ok, context, %{"op" => "add_package", "work_package_id" => work_package.id} |> put_present("key", key)}
    end
  end

  defp apply_op(%{"op" => "update_package"} = op, context) do
    with {:ok, ref} <- required_string(op, "work_package_id"),
         {:ok, expected_revision} <- expected_revision(op),
         {:ok, patch} <- patch(op),
         {:ok, work_package_id} <- resolve(ref, context),
         {:ok, work_package} <- Repository.get_work_package(context.repo, context.work_request_id, work_package_id),
         :ok <- require_revision(work_package, expected_revision),
         :ok <- require_mutable(work_package),
         :ok <- require_complete_contract(effective_contract(work_package, patch)),
         {:ok, updated} <- update_work_package(context, work_package, expected_revision, patch) do
      {:ok, context, %{"op" => "update_package", "work_package_id" => updated.id, "revision" => updated.contract_revision}}
    end
  end

  defp apply_op(%{"op" => "set_dependency"} = op, context) do
    with {:ok, from_ref} <- required_string(op, "from"),
         {:ok, to_ref} <- required_string(op, "to"),
         {:ok, candidate} <- candidate_head_sha(op),
         {:ok, reason} <- optional_string(op, "reason"),
         {:ok, from} <- resolve(from_ref, context),
         {:ok, to} <- resolve(to_ref, context),
         :ok <- require_distinct(from, to),
         :ok <- set_dependency(from, to, candidate, reason, context) do
      {:ok, context, %{"op" => "set_dependency", "from" => from, "to" => to}}
    end
  end

  defp apply_op(%{"op" => "remove_dependency"} = op, context) do
    with {:ok, from_ref} <- required_string(op, "from"),
         {:ok, to_ref} <- required_string(op, "to"),
         {:ok, from} <- resolve(from_ref, context),
         {:ok, to} <- resolve(to_ref, context),
         :ok <- remove_dependency(from, to, context) do
      {:ok, context, %{"op" => "remove_dependency", "from" => from, "to" => to}}
    end
  end

  defp apply_op(_op, _context), do: {:error, {:invalid_op, @ops}}

  defp update_work_package(context, %WorkPackage{} = work_package, expected_revision, patch) do
    case Repository.update_work_package(context.repo, context.work_request_id, work_package.id, expected_revision, patch) do
      {:error, :stale_status} -> {:error, {:revision_conflict, work_package.status, work_package.contract_revision}}
      result -> result
    end
  end

  defp add_dependencies(work_package_id, prerequisite_ids, context) do
    Enum.reduce_while(prerequisite_ids, :ok, fn prerequisite_id, :ok ->
      with :ok <- require_distinct(work_package_id, prerequisite_id),
           :ok <- set_dependency(work_package_id, prerequisite_id, :keep, nil, context) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp set_dependency(from, to, candidate, reason, context) do
    case dependency_edges(context, from, to) do
      [] ->
        %{
          "work_request_id" => context.work_request_id,
          "source_kind" => "work_package",
          "source_id" => from,
          "target_kind" => "work_package",
          "target_id" => to,
          "kind" => "depends_on",
          "created_by" => context.created_by
        }
        |> put_present("reason", reason)
        |> put_candidate(candidate)
        |> DependencyEdge.create_changeset()
        |> context.repo.insert()
        |> ok_or_error()

      edges ->
        attrs = %{} |> put_present("reason", reason) |> put_candidate(candidate)
        Enum.reduce_while(edges, :ok, &update_edge(&1, &2, attrs, context))
    end
  end

  defp update_edge(edge, :ok, attrs, context) do
    case edge |> DependencyEdge.update_changeset(attrs) |> context.repo.update() |> ok_or_error() do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp remove_dependency(from, to, context) do
    case dependency_edges(context, from, to) do
      [] -> {:error, {:dependency_not_found, from, to}}
      edges -> Enum.each(edges, fn edge -> context.repo.delete!(edge) end)
    end
  end

  # A dependency of `from` on `to` is stored as `from depends_on to`, or in
  # older ledgers as `to blocks from`.
  defp dependency_edges(context, from, to) do
    context.repo.all(
      from(edge in DependencyEdge,
        where:
          edge.work_request_id == ^context.work_request_id and edge.kind in @hard_edge_kinds and
            ((edge.kind == "depends_on" and edge.source_id == ^from and edge.target_id == ^to) or
               (edge.kind == "blocks" and edge.source_id == ^to and edge.target_id == ^from)),
        order_by: [asc: edge.created_at, asc: edge.id]
      )
    )
  end

  defp ok_or_error({:ok, _record}), do: :ok
  defp ok_or_error({:error, _reason} = error), do: error

  defp put_candidate(attrs, :keep), do: attrs
  defp put_candidate(attrs, candidate), do: Map.put(attrs, "candidate_head_sha", candidate)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp resolve_all(refs, context) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, ids} ->
      case resolve(ref, context) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp resolve(ref, context) do
    case Map.fetch(context.keys, ref) do
      {:ok, id} ->
        {:ok, id}

      :error ->
        if context.repo.exists?(from(package in WorkPackage, where: package.id == ^ref and package.work_request_id == ^context.work_request_id)),
          do: {:ok, ref},
          else: {:error, {:unknown_work_package, ref}}
    end
  end

  defp optional_key(op, context) do
    case optional_string(op, "key") do
      {:ok, nil} -> {:ok, nil}
      {:ok, key} -> if Map.has_key?(context.keys, key), do: {:error, {:duplicate_key, key}}, else: {:ok, key}
      error -> error
    end
  end

  defp require_distinct(id, id), do: {:error, {:self_dependency, id}}
  defp require_distinct(_from, _to), do: :ok

  defp require_revision(%WorkPackage{contract_revision: revision}, revision), do: :ok

  defp require_revision(%WorkPackage{} = work_package, _expected),
    do: {:error, {:revision_conflict, work_package.status, work_package.contract_revision}}

  defp require_mutable(%WorkPackage{} = work_package) do
    cond do
      Lifecycle.ended?(work_package) -> {:error, {:work_package_ended, work_package.contract_revision}}
      Lifecycle.ready?(work_package) -> {:error, {:contract_frozen, work_package.contract_revision}}
      true -> :ok
    end
  end

  defp require_complete_contract(contract) do
    missing =
      Enum.reject(@required_contract_strings, &filled_string?(Map.get(contract, &1))) ++
        Enum.reject(@required_contract_lists, &string_list?(Map.get(contract, &1)))

    if missing == [], do: :ok, else: {:error, {:incomplete_contract, missing}}
  end

  defp effective_contract(%WorkPackage{} = work_package, patch) do
    Map.merge(
      %{
        "title" => work_package.title,
        "goal" => work_package.goal,
        "acceptance_criteria" => work_package.acceptance_criteria,
        "validation_steps" => work_package.validation_steps,
        "stop_conditions" => work_package.stop_conditions
      },
      patch
    )
  end

  defp expected_revision(op) do
    case Map.get(op, "expected_revision") do
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _revision -> {:error, {:invalid_field, "expected_revision"}}
    end
  end

  defp patch(op) do
    case Map.get(op, "patch") do
      %{} = patch when map_size(patch) > 0 -> {:ok, patch}
      _patch -> {:error, {:invalid_field, "patch"}}
    end
  end

  defp candidate_head_sha(op) do
    case Map.fetch(op, "candidate_head_sha") do
      :error -> {:ok, :keep}
      {:ok, nil} -> {:ok, nil}
      {:ok, sha} when is_binary(sha) -> if sha =~ ~r/\A[0-9a-fA-F]{40}\z/, do: {:ok, sha}, else: {:error, {:invalid_field, "candidate_head_sha"}}
      {:ok, _sha} -> {:error, {:invalid_field, "candidate_head_sha"}}
    end
  end

  defp required_string(op, field) do
    case optional_string(op, field) do
      {:ok, nil} -> {:error, {:invalid_field, field}}
      result -> result
    end
  end

  defp optional_string(op, field) do
    case Map.get(op, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> if filled_string?(value), do: {:ok, String.trim(value)}, else: {:error, {:invalid_field, field}}
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp string_list(op, field) do
    case Map.get(op, field) do
      nil -> {:ok, []}
      values when is_list(values) -> if string_list?(values), do: {:ok, Enum.map(values, &String.trim/1)}, else: {:error, {:invalid_field, field}}
      _values -> {:error, {:invalid_field, field}}
    end
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp string_list?(values) when is_list(values), do: Enum.all?(values, &filled_string?/1)
  defp string_list?(_values), do: false
end
