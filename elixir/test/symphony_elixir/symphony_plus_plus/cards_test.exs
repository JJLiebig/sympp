Code.require_file("../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CardsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.{Asks, Cards, Observer}
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
  alias SymphonyElixir.SymphonyPlusPlus.Cards.Card
  alias SymphonyElixir.SymphonyPlusPlus.Ownership.Terminal

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
    items = Cards.watch(repo, core: core(terminals), git: on_main)
    assert {:ok, _dismissed} = Cards.dismiss(repo, card_id)
    Cards.apply(repo, items, %{{:pr, "acme", "app", 4} => {:ok, %{pr(4, "open") | "head_sha" => "h2"}}}, review: fn _id, _machine -> :not_started end)
    assert [%{"state" => "dismissed", "pr" => %{"head_sha" => "h1"}}] = list(repo)
  end

  test "terminals on one branch share a board row and a dismissal", %{repo: repo} do
    parent = chief("t0")
    first = child("t1", "t0")
    second = child("t2", "t0")
    helper = child("t3", "t0")
    other = child("t4", "t0")
    terminals = [parent, first, second, helper, other]

    git = fn
      cwd when cwd in ["/work/t2", "/work/t3"] -> {:ok, %{@git | repository: "ACME/app"}}
      "/work/t4" -> {:ok, %{@git | repository: "acme/other"}}
      _cwd -> {:ok, @git}
    end

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core(terminals) end)
    sweep(repo, [parent, first, helper], %{}, git: git)
    sweep(repo, terminals, %{}, git: git)
    board = fn -> Enum.sort_by(list(repo), &{String.downcase(&1["repository"]), &1["branch"]}) end

    assert [
             %{"id" => card_id, "state" => "working", "branch" => "feature-1", "worked_on" => %{"address" => "testbox/t2", "liveness" => "live"}},
             %{"state" => "working", "repository" => "acme/other", "branch" => "feature-1"}
           ] = board.()

    terminal = %Terminal{key: Terminal.key(@core, "t3"), core_id: @core, address: "t3", display_address: "testbox/t3", role: "chief"}
    assert {:ok, %{id: ask_id}} = Asks.open(repo, terminal, %{"question" => "Ready for review?"})

    switched_git = fn
      "/work/t2" -> {:ok, %{@git | repository: "ACME/app", branch: "feature-2"}}
      cwd -> git.(cwd)
    end

    first = put_in(first, ["labels", "sympp.review_id"], "rvw_branchcard01")
    opened = pr(5, "open")
    upper = %{opened | "repository" => "ACME/app"}
    github = %{head("feature-1") => {:ok, opened}, {:head, "ACME", "app", "feature-1"} => {:ok, upper}}
    sweep(repo, [parent, first, second, other], github, git: switched_git)

    assert [
             %{
               "id" => ^card_id,
               "state" => "review_ci",
               "pr" => %{"number" => 5},
               "review" => %{"id" => "rvw_branchcard01"},
               "asks" => [%{"id" => ^ask_id, "card_id" => ^card_id}]
             },
             %{"state" => "working", "branch" => "feature-2"},
             %{"state" => "working", "repository" => "acme/other"}
           ] = board.()

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core([parent, first, second, other]) end)
    assert [%{"worked_on" => %{"address" => "testbox/t1"}}, _switched, _other] = board.()

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core([parent, second, other]) end)
    assert [%{"state" => "review_ci"} = unattended, _switched, _other] = board.()
    refute Map.has_key?(unattended, "worked_on")

    assert {:ok, %{state: "dismissed"}} = Cards.dismiss(repo, card_id)
    sweep(repo, [parent, first, second, helper, other], github, git: switched_git)

    assert [
             %{"id" => ^card_id, "state" => "dismissed", "asks" => []},
             %{"state" => "working", "branch" => "feature-2"},
             %{"state" => "working", "repository" => "acme/other"}
           ] = board.()

    assert {:error, :no_open_card} = Asks.open(repo, terminal, %{"question" => "Still open?"})
  end

  defp sweep(repo, terminals, github, opts) do
    Observer.sweep(
      repo,
      Keyword.merge(
        [
          core: core(terminals),
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
