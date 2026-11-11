defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDelivery do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @spec start(module(), (module() -> term())) :: :ok
  def start(repo, fun) do
    # File-backed delivery owns a connection because Runtime may close the
    # request's repo on return. Memory ledgers belong to their existing pool.
    %{rows: rows} = repo.query!("PRAGMA database_list")
    [_, "main", database] = Enum.find(rows, &(Enum.at(&1, 1) == "main"))
    source = repo.get_dynamic_repo()
    source = if is_atom(source), do: Process.whereis(source), else: source

    {:ok, _pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        run(repo, source, database, fun)
      end)

    :ok
  end

  defp run(repo, source, "", fun) do
    repo.put_dynamic_repo(source)
    fun.(repo)
  end

  defp run(_repo, _source, database, fun) do
    {:ok, pid} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
    Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      GenServer.stop(pid)
    end
  end
end
