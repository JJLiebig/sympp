Code.require_file("../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CardsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.{Cards, Observer}
  alias SymphonyElixir.SymphonyPlusPlus.Cards.Card

  @core MCPHarness.test_core_id()
  @git %{repository: "acme/app", base_branch: "main", branch: "feature-1"}

  setup %{repo: repo} do
    repo.delete_all(Ask)
    repo.delete_all(Card)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
      Application.put_env(:symphony_elixir, :sympp_herdr_send, nil)
    end)

    :ok
  end

  test "a dismissal between a sweep's read and its apply wins", %{repo: repo} do
    on_main = fn _cwd -> {:ok, %{@git | branch: "main"}} end
    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("main") => {:ok, %{pr(4, "open") | "branch" => "main", "base_branch" => "release"}}}, git: on_main)
    assert [%{"id" => card_id, "state" => "review_ci"}] = list(repo)

    # The operator dismisses after the sweep read the card, before it applies.
    items = Cards.watch(repo, core: core(terminals), terminal: fn _address -> :error end, git: on_main)
    assert {:ok, _dismissed} = Cards.dismiss(repo, card_id)
    Cards.apply(repo, items, %{{:pr, "acme", "app", 4} => {:ok, %{pr(4, "open") | "head_sha" => "h2"}}}, review: fn _id, _machine -> :not_started end)
    assert [%{"state" => "dismissed", "pr" => %{"head_sha" => "h1"}}] = list(repo)
  end

  test "an ended card stays in the ledger while its terminal is live, so its branch isn't taken for new work", %{repo: repo} do
    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}})
    [%{"id" => card_id}] = list(repo)
    assert {:ok, _dismissed} = Cards.dismiss(repo, card_id)

    later = DateTime.add(DateTime.utc_now(:microsecond), 40 * 86_400, :second)
    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core(terminals) end)
    assert {:ok, 0} = Cards.delete_expired(repo, 30, later)
    assert Cards.list(repo, 30, later) == []

    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}})
    assert [%{"state" => "dismissed"}] = list(repo)

    # Liveness unknown: the card is kept too.
    Application.put_env(:symphony_elixir, :sympp_herdr_core, nil)
    assert {:ok, 0} = Cards.delete_expired(repo, 30, later)

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core([Map.put(child("t1", "t0"), "state", "finished")]) end)
    assert {:ok, 1} = Cards.delete_expired(repo, 30, later)
  end

  defp sweep(repo, terminals, github, opts \\ []) do
    Observer.sweep(
      repo,
      Keyword.merge(
        [
          core: core(terminals),
          terminal: fn _address -> :error end,
          git: fn _cwd -> {:ok, @git} end,
          snapshot: fn entries -> Map.new(entries, &{&1, Map.get(github, &1, {:ok, nil})}) end,
          review: fn _id, _machine -> :not_started end
        ],
        opts
      )
    )
  end

  defp core(terminals), do: {:ok, %{core_id: @core, core_name: "testbox", terminals: Map.new(terminals, &{&1["address"], &1})}}

  defp chief(address), do: %{"address" => address, "state" => "live", "cwd" => "/work/#{address}", "labels" => %{"sympp.role" => "chief"}}

  defp child(address, parent), do: %{"address" => address, "state" => "live", "cwd" => "/work/#{address}", "name" => "#{address} task", "parent" => parent, "labels" => %{}}

  defp head(branch), do: {:head, "acme", "app", branch}

  defp pr(number, state) do
    %{
      "repository" => "acme/app",
      "number" => number,
      "url" => "https://github.com/acme/app/pull/#{number}",
      "state" => state,
      "merged" => state == "merged",
      "head_sha" => "h1",
      "branch" => "feature-1",
      "base_branch" => "main",
      "ci" => %{"status" => "passing", "completed" => 3, "total" => 3}
    }
  end

  defp list(repo), do: Cards.list(repo, 30)
end
