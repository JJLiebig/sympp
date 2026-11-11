defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDelivery do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @spec start(module(), (module() -> term())) :: :ok
  def start(repo, fun) do
    # Runtime may close a request-owned repo as soon as HTTP returns. Delivery
    # owns its connection, against the exact ledger that accepted the write.
    %{rows: rows} = repo.query!("PRAGMA database_list")
    [_, "main", database] = Enum.find(rows, &(Enum.at(&1, 1) == "main"))

    {:ok, _pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        {:ok, pid} = Repo.start_link(database: database, name: nil, pool_size: 1, log: false)
        previous = Repo.put_dynamic_repo(pid)

        try do
          fun.(Repo)
        after
          Repo.put_dynamic_repo(previous)
          GenServer.stop(pid)
        end
      end)

    :ok
  end
end
