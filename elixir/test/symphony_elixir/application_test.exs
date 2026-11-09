defmodule SymphonyElixir.ApplicationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.OfflineSandbox
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Retention
  alias SymphonyElixir.SymphonyPlusPlus.Repo

  test "offline application boot refuses an unmarked ledger before starting legacy services" do
    database = Path.join(System.tmp_dir!(), "sympp-offline-boot-#{System.unique_integer([:positive])}.sqlite3")
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database)

    try do
      with_envs([{"SYMPP_OFFLINE_SANDBOX", "1"}, {"SYMPP_RUNTIME_ARTIFACT", nil}], fn ->
        assert_raise RuntimeError, ~r/requires a marked snapshot/, fn -> OfflineSandbox.verify!(nil) end
        assert_raise RuntimeError, ~r/requires a marked snapshot/, fn -> SymphonyElixir.Application.start(:normal, []) end
        refute File.exists?(database)
        children = SymphonyElixir.Application.children()
        refute SymphonyElixir.WorkflowStore in children
        refute SymphonyElixir.Orchestrator in children
        refute SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases in children
        refute Enum.any?(children, &match?({SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue, _}, &1))
        assert {Repo, Repo.child_options()} in children
        assert {Retention, repo: Repo} in children
      end)
    after
      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end
    end
  end

  defp with_envs(values, fun) do
    previous_values = Enum.map(values, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      for {name, value} <- values do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end

      fun.()
    after
      for {name, previous} <- previous_values do
        if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
      end
    end
  end
end
