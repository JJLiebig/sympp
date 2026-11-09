defmodule SymppV3Preview do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          source: :string,
          target: :string
        ]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")

    source = Keyword.get_lazy(opts, :source, &default_source/0)
    target = Keyword.get_lazy(opts, :target, &default_target/0)

    snapshot_database!(source, target)
    start_repo!(target)
    migrate!()

    IO.puts("preview_database=#{target}")
  end

  defp default_source do
    Path.expand("~/.agents/splusplus/symphony_plus_plus.sqlite3")
  end

  defp default_target do
    Path.expand("../tmp/v3-preview/symphony_plus_plus_v3_preview.sqlite3", File.cwd!())
  end

  defp snapshot_database!(source, target) do
    source = Path.expand(source)
    target = Path.expand(target)

    unless File.exists?(source), do: raise("source database does not exist: #{source}")

    File.mkdir_p!(Path.dirname(target))

    Enum.each([target, target <> "-wal", target <> "-shm"], fn path ->
      if File.exists?(path), do: File.rm!(path)
    end)

    {:ok, connection} = Exqlite.Sqlite3.open(source)

    try do
      :ok = Exqlite.Sqlite3.execute(connection, "VACUUM INTO '#{sqlite_string(target)}'")
    after
      :ok = Exqlite.Sqlite3.close(connection)
    end
  end

  defp sqlite_string(value), do: String.replace(value, "'", "''")

  defp start_repo!(target) do
    Application.put_env(:symphony_elixir, :sympp_repo_database, target)

    {:ok, pid} = Repo.start_link(database: target, name: Repo.process_name(target), pool_size: 1, log: false)
    Repo.put_dynamic_repo(pid)
  end

  defp migrate! do
    case WorkRequestRepository.migrate(Repo) do
      :ok -> :ok
      {:error, reason} -> raise("preview database migration failed: #{inspect(reason)}")
    end
  end
end

SymppV3Preview.run(System.argv())
