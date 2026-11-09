Code.require_file("../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.OwnershipTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.HerdrCore

  setup %{repo: repo} do
    work_request = create_work_request!(repo, %{"title" => "Ownership"})
    on_exit(fn -> Application.put_env(:symphony_elixir, :sympp_herdr_core, nil) end)
    {:ok, work_request: work_request}
  end

  defp live_owner_rows(repo, work_request_id) do
    repo.all(from(row in WorkedOn, where: row.subject_id == ^work_request_id and row.state == "live"))
  end

  # The factory's herdr-core sees the test core and lists these terminals.
  defp factory_core(terminals) do
    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn ->
      {:ok, %{core_id: MCPHarness.test_core_id(), terminals: terminals}}
    end)
  end

  test "two terminals racing for one WorkRequest end with exactly one live owner", %{repo: repo, work_request: work_request} do
    results =
      ["t1", "t2", "t3", "t4"]
      |> Enum.map(fn address -> Task.async(fn -> Ownership.acquire(repo, work_request.id, test_terminal(address)) end) end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert [{:ok, _row, :acquired}] = Enum.filter(results, &match?({:ok, _row, _how}, &1))
    assert Enum.count(results, &match?({:error, {:owned_by_other_terminal, _owner}}, &1)) == 3
    assert [_one] = live_owner_rows(repo, work_request.id)
  end

  test "the factory core view never treats an unseen or unreachable terminal as finished" do
    Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
    assert HerdrCore.view("any-core", "t1") == :unknown

    factory_core(%{})
    assert HerdrCore.view("another-core", "t1") == :unseen
    assert HerdrCore.view(MCPHarness.test_core_id(), "t1") == :finished
  end
end
