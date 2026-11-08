defmodule SymphonyElixir.SymphonyPlusPlus.RepoMigrationFileLockTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.MigrationFileLock
  alias SymphonyElixir.WorkPackageFactory

  @lock_wait_observer_key :sympp_migration_lock_wait_observer

  test "Repo database identity keys canonicalize equivalent Windows paths" do
    database_path = Path.join(System.tmp_dir!(), "Sympp-Case-Key.sqlite3")
    relative_uri = "file:tmp/sympp-uri-key.sqlite3?mode=rwc&cache=shared"
    expanded_uri = "file:#{Path.expand("tmp/sympp-uri-key.sqlite3")}?cache=shared&mode=rwc"

    assert Repo.process_key(relative_uri) == Repo.process_key(expanded_uri)

    case :os.type() do
      {:win32, _name} ->
        assert Repo.process_key(String.upcase(database_path)) == Repo.process_key(String.downcase(database_path))
        assert Repo.same_database_path?(String.upcase(database_path), String.downcase(database_path))

      _other ->
        assert Repo.process_key(database_path) == Repo.process_key(Path.expand(database_path))
    end
  end

  test "migration file lock waits for a live holder without a retry budget" do
    original_retry_delay = Application.fetch_env(:symphony_elixir, :sympp_migration_lock_retry_delay_ms)
    original_wait_observer = Application.fetch_env(:symphony_elixir, @lock_wait_observer_key)

    database_path = WorkPackageFactory.database_path()
    lock_path = database_path <> ".migration.lock"
    parent = self()

    Application.put_env(:symphony_elixir, :sympp_migration_lock_retry_delay_ms, 1)
    Application.put_env(:symphony_elixir, @lock_wait_observer_key, parent)

    try do
      File.mkdir_p!(Path.dirname(database_path))
      File.rm(lock_path)

      holder =
        spawn(fn ->
          result =
            MigrationFileLock.run(database_path, fn ->
              send(parent, :migration_file_lock_acquired)

              receive do
                :release -> :released
              end
            end)

          send(parent, {:migration_file_lock_result, result})
        end)

      assert_receive :migration_file_lock_acquired, 1_000

      waiter = Task.async(fn -> MigrationFileLock.run(database_path, fn -> :waited end) end)
      waiter_pid = waiter.pid

      try do
        assert_receive {:migration_lock_wait, ^lock_path, ^waiter_pid}, 1_000
        assert Task.yield(waiter, 50) == nil
      after
        send(holder, :release)
      end

      assert Task.await(waiter, 1_000) == :waited
      assert_receive {:migration_file_lock_result, :released}, 1_000
      refute File.exists?(lock_path)
    after
      restore_fetched_app_env(:sympp_migration_lock_retry_delay_ms, original_retry_delay)
      restore_fetched_app_env(@lock_wait_observer_key, original_wait_observer)
      File.rm(lock_path)
      File.rm(database_path)
    end
  end

  test "migration file lock rejects a concurrent attempt once its retries run out" do
    database_path = WorkPackageFactory.database_path()
    lock_path = database_path <> ".migration.lock"
    parent = self()

    try do
      File.mkdir_p!(Path.dirname(database_path))
      File.rm(lock_path)

      holder =
        spawn(fn ->
          result =
            MigrationFileLock.run(
              database_path,
              fn ->
                send(parent, :migration_file_lock_acquired)

                receive do
                  :release -> :held
                end
              end,
              1
            )

          send(parent, {:migration_file_lock_result, result})
        end)

      assert_receive :migration_file_lock_acquired, 1_000
      assert File.exists?(lock_path)

      try do
        assert {:error, :repo_migration_lock_busy} = MigrationFileLock.run(database_path, fn -> :unexpected end, 1)
      after
        send(holder, :release)
      end

      assert_receive {:migration_file_lock_result, :held}, 1_000
      refute File.exists?(lock_path)
    after
      File.rm(lock_path)
      File.rm(database_path)
    end
  end

  test "migration file lock recovers abandoned stale lock files" do
    database_path = WorkPackageFactory.database_path()
    lock_path = database_path <> ".migration.lock"

    try do
      File.mkdir_p!(Path.dirname(database_path))
      File.write!(lock_path, "stale\n")
      File.touch!(lock_path, {{2000, 1, 1}, {0, 0, 0}})

      assert :ok = MigrationFileLock.run(database_path, fn -> :ok end, 1)
      refute File.exists?(lock_path)
    after
      File.rm(lock_path)
      File.rm(database_path)
    end
  end

  test "migration file lock cleanup does not remove a newer owner's lock" do
    database_path = WorkPackageFactory.database_path()
    lock_path = database_path <> ".migration.lock"

    try do
      File.mkdir_p!(Path.dirname(database_path))
      File.write!(lock_path, "new-token\n")

      assert :ok = MigrationFileLock.remove_owned_for_test(lock_path, "old-token")
      assert File.read!(lock_path) == "new-token\n"

      assert :removed = MigrationFileLock.remove_owned_for_test(lock_path, "new-token")
      refute File.exists?(lock_path)
    after
      File.rm(lock_path)
      File.rm(database_path)
    end
  end

  defp restore_fetched_app_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_fetched_app_env(key, :error), do: Application.delete_env(:symphony_elixir, key)
end
