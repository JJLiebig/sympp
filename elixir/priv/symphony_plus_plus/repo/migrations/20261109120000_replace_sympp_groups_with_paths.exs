defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.ReplaceSymppGroupsWithPaths do
  use Ecto.Migration

  # Groups become a text path on each package, such as "Backend / Billing":
  # the ancestor group titles joined with " / ". Group records, their
  # parent links and group-level dependencies go away.
  #
  # A dependency that named a group is replaced by the package-to-package
  # dependencies it stood for (every package in the group or its subgroups),
  # so the execution graph is unchanged.
  #
  # SQLite cannot drop product_tree_node_id because it carries a foreign key,
  # so sympp_work_packages is rebuilt. Other tables reference it with
  # ON DELETE CASCADE, so the rebuild runs with foreign keys off; dropping the
  # old table with them on would delete those rows.

  @disable_ddl_transaction true

  @node_column_definition ~r/,\s*product_tree_node_id TEXT REFERENCES sympp_product_tree_nodes\(id\) ON DELETE SET NULL/

  def up do
    repo().checkout(fn ->
      query!("PRAGMA foreign_keys = OFF")

      try do
        transactional_up()
      after
        query!("PRAGMA foreign_keys = ON")
      end
    end)
  end

  def down do
    raise Ecto.MigrationError, message: "group records were replaced by group paths and cannot be restored"
  end

  defp transactional_up do
    query!("BEGIN IMMEDIATE")

    try do
      query!(~s|ALTER TABLE sympp_work_packages ADD COLUMN "group" TEXT|)
      nodes = load_nodes()
      backfill_group_paths(nodes)
      expand_group_dependencies(nodes)
      rebuild_work_packages_without_node_column()
      query!("DROP TABLE sympp_product_tree_nodes")
      assert_foreign_keys!()
      query!("COMMIT")
    rescue
      exception ->
        query!("ROLLBACK")
        reraise exception, __STACKTRACE__
    end
  end

  defp load_nodes do
    "SELECT id, parent_id, title FROM sympp_product_tree_nodes"
    |> query!()
    |> Map.fetch!(:rows)
    |> Map.new(fn [id, parent_id, title] -> {id, %{parent_id: parent_id, title: title}} end)
  end

  defp backfill_group_paths(nodes) do
    "SELECT id, product_tree_node_id FROM sympp_work_packages WHERE product_tree_node_id IS NOT NULL"
    |> query!()
    |> Map.fetch!(:rows)
    |> Enum.each(fn [id, node_id] ->
      query!(~s|UPDATE sympp_work_packages SET "group" = ?1 WHERE id = ?2|, [group_path(nodes, node_id), id])
    end)
  end

  # Ancestor titles, root first. Each title is split on "/" like any group
  # path, so a title containing "/" nests one level deeper. A broken parent
  # chain (missing parent or a cycle) ends the path at the last good ancestor.
  defp group_path(nodes, node_id) do
    nodes
    |> ancestor_titles(node_id, [], MapSet.new())
    |> Enum.flat_map(&String.split(&1, "/"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      segments -> Enum.join(segments, " / ")
    end
  end

  defp ancestor_titles(nodes, node_id, titles, seen) do
    case Map.fetch(nodes, node_id) do
      {:ok, %{parent_id: parent_id, title: title}} ->
        if MapSet.member?(seen, node_id),
          do: titles,
          else: ancestor_titles(nodes, parent_id, [title || "" | titles], MapSet.put(seen, node_id))

      :error ->
        titles
    end
  end

  defp expand_group_dependencies(nodes) do
    edges =
      """
      SELECT id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, decision_ref, created_by, created_at
      FROM sympp_product_tree_dependency_edges
      WHERE source_kind = 'product_node' OR target_kind = 'product_node'
      """
      |> query!()
      |> Map.fetch!(:rows)

    if edges != [] do
      members = group_members(nodes)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Enum.each(edges, fn [id | _rest] = edge ->
        insert_package_edges(edge, members, now)
        query!("DELETE FROM sympp_product_tree_dependency_edges WHERE id = ?1", [id])
      end)
    end
  end

  # Packages directly in each group, plus those of its subgroups.
  defp group_members(nodes) do
    direct =
      "SELECT id, product_tree_node_id FROM sympp_work_packages WHERE product_tree_node_id IS NOT NULL"
      |> query!()
      |> Map.fetch!(:rows)
      |> Enum.group_by(fn [_id, node_id] -> node_id end, fn [id, _node_id] -> id end)

    children = Enum.group_by(nodes, fn {_id, node} -> node.parent_id end, fn {id, _node} -> id end)

    Map.new(nodes, fn {id, _node} -> {id, descendant_members(id, children, direct, MapSet.new())} end)
  end

  defp descendant_members(id, children, direct, seen) do
    if MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)
      Enum.uniq(Map.get(direct, id, []) ++ Enum.flat_map(Map.get(children, id, []), &descendant_members(&1, children, direct, seen)))
    end
  end

  defp insert_package_edges([id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, decision_ref, created_by, created_at], members, now) do
    sources = endpoint_packages(source_kind, source_id, members)
    targets = endpoint_packages(target_kind, target_id, members)
    shared = MapSet.intersection(MapSet.new(sources), MapSet.new(targets))

    for source <- sources,
        target <- targets,
        source != target,
        not (MapSet.member?(shared, source) and MapSet.member?(shared, target)),
        not package_edge_exists?(work_request_id, source, target, kind) do
      query!(
        """
        INSERT INTO sympp_product_tree_dependency_edges
          (id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, decision_ref, created_by, created_at, inserted_at, updated_at)
        VALUES (?1, ?2, 'work_package', ?3, 'work_package', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
        """,
        [expanded_edge_id(id, source, target), work_request_id, source, target, kind, reason, decision_ref, created_by, created_at, now]
      )
    end
  end

  defp endpoint_packages("product_node", id, members), do: Map.get(members, id, [])
  defp endpoint_packages("work_package", id, _members), do: [id]
  defp endpoint_packages(_kind, _id, _members), do: []

  defp package_edge_exists?(work_request_id, source, target, kind) do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*) FROM sympp_product_tree_dependency_edges
        WHERE work_request_id = ?1 AND source_kind = 'work_package' AND source_id = ?2
          AND target_kind = 'work_package' AND target_id = ?3 AND kind = ?4
        """,
        [work_request_id, source, target, kind]
      )

    count > 0
  end

  defp expanded_edge_id(id, source, target) do
    suffix = :sha256 |> :crypto.hash([id, 0, source, 0, target]) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    "ptde_" <> suffix
  end

  defp rebuild_work_packages_without_node_column do
    %{rows: [[table_sql]]} = query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'sympp_work_packages'")

    new_table_sql =
      case Regex.scan(@node_column_definition, table_sql) do
        [_one] -> Regex.replace(@node_column_definition, table_sql, "")
        matches -> raise "expected one product_tree_node_id column definition in sympp_work_packages, found #{length(matches)}"
      end

    index_sql =
      "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'sympp_work_packages' AND sql IS NOT NULL"
      |> query!()
      |> Map.fetch!(:rows)
      |> Enum.map(fn [sql] -> sql end)
      |> Enum.reject(&String.contains?(&1, "product_tree_node_id"))

    query!(String.replace(new_table_sql, ~r/\ACREATE TABLE "?sympp_work_packages"?/, ~s|CREATE TABLE "sympp_work_packages_new"|, global: false))

    columns =
      ~s|SELECT name FROM pragma_table_info('sympp_work_packages_new')|
      |> query!()
      |> Map.fetch!(:rows)
      |> Enum.map_join(", ", fn [name] -> ~s|"#{name}"| end)

    query!("INSERT INTO sympp_work_packages_new (#{columns}) SELECT #{columns} FROM sympp_work_packages")
    query!("DROP TABLE sympp_work_packages")
    query!("ALTER TABLE sympp_work_packages_new RENAME TO sympp_work_packages")
    Enum.each(index_sql, &query!/1)
  end

  defp assert_foreign_keys! do
    case query!("PRAGMA foreign_key_check") do
      %{rows: []} -> :ok
      %{rows: rows} -> raise "foreign key check failed after replacing groups with paths: #{inspect(Enum.take(rows, 5))}"
    end
  end

  defp query!(sql, params \\ []), do: repo().query!(sql, params, log: false)
end
