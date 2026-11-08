defmodule SymphonyElixir.SymphonyPlusPlus.Repo.MigrationFileLock do
  @moduledoc """
  Cross-process file lock that serializes ledger migrations for one database path.
  """

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @heartbeat_ms 1_000
  @stale_seconds 30
  @retry_delay_ms 100
  @lock_wait_observer_key :sympp_migration_lock_wait_observer

  @spec run(Path.t(), (-> term())) :: term()
  @spec run(Path.t(), (-> term()), non_neg_integer() | :infinity) :: term()
  def run(database_path, fun, retries \\ :infinity)

  def run(_database_path, fun, 0) when is_function(fun, 0), do: {:error, :repo_migration_lock_busy}

  def run(database_path, fun, retries) when is_binary(database_path) and is_function(fun, 0) do
    lock_path = lock_path(database_path)

    case acquire(lock_path) do
      {:ok, io_device, heartbeat, token} ->
        try do
          fun.()
        after
          stop_heartbeat(heartbeat)
          File.close(io_device)
          remove_owned(lock_path, token)
        end

      :busy ->
        case remove_stale(lock_path) do
          :removed ->
            run(database_path, fun, retries)

          :ok ->
            notify_lock_wait(lock_path)
            Process.sleep(retry_delay_ms())
            run(database_path, fun, next_retry(retries))
        end

      {:error, reason} ->
        {:error, {:repo_migration_file_lock_failed, reason}}
    end
  end

  @doc false
  @spec remove_owned_for_test(Path.t(), String.t()) :: :removed | :ok
  def remove_owned_for_test(lock_path, token), do: remove_owned(lock_path, token)

  defp next_retry(:infinity), do: :infinity
  defp next_retry(retries), do: retries - 1

  defp retry_delay_ms do
    case Application.get_env(:symphony_elixir, :sympp_migration_lock_retry_delay_ms, @retry_delay_ms) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @retry_delay_ms
    end
  end

  defp notify_lock_wait(lock_path) do
    case Application.get_env(:symphony_elixir, @lock_wait_observer_key) do
      pid when is_pid(pid) -> send(pid, {:migration_lock_wait, lock_path, self()})
      _other -> :ok
    end
  end

  defp lock_path(database_path) do
    if Repo.filesystem_database_path?(database_path) do
      database_path <> ".migration.lock"
    else
      lock_name =
        database_path
        |> Repo.database_key()
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      Path.join([System.tmp_dir() || ".", "symphony_plus_plus_migration_locks", lock_name <> ".lock"])
    end
  end

  defp acquire(lock_path) do
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> open(lock_path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(lock_path) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io_device} ->
        token = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
        IO.write(io_device, "#{token}\n#{node()} #{inspect(self())}\n")
        heartbeat = spawn_link(fn -> heartbeat(lock_path) end)
        {:ok, io_device, heartbeat, token}

      {:error, :eexist} ->
        :busy

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp heartbeat(lock_path) do
    receive do
      :stop -> :ok
    after
      @heartbeat_ms ->
        File.touch(lock_path)
        heartbeat(lock_path)
    end
  end

  defp stop_heartbeat(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :ok
    end
  end

  defp remove_stale(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        if System.os_time(:second) - mtime > @stale_seconds, do: remove(lock_path), else: :ok

      _missing_or_unreadable ->
        :ok
    end
  end

  defp remove(lock_path) do
    case File.rm(lock_path) do
      :ok -> :removed
      {:error, _reason} -> :ok
    end
  end

  defp remove_owned(lock_path, token) do
    case File.read(lock_path) do
      {:ok, contents} ->
        if contents |> String.split("\n", parts: 2) |> List.first() == token, do: remove(lock_path), else: :ok

      {:error, _reason} ->
        :ok
    end
  end
end
