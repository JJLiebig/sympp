Code.require_file("../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CardsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.{Asks, Cards, Observer}
  alias SymphonyElixir.SymphonyPlusPlus.Asks.Ask
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

  test "a chief's child follows its branch, PR, review and merge on a card", %{repo: repo} do
    terminals = [chief("t0"), child("t1", "t0")]

    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}})
    assert [%{"state" => "working", "title" => "t1 task", "branch" => "feature-1", "worked_on" => %{"address" => "testbox/t1", "role" => "card"}} = card] = list(repo)

    asked = mcp_tool(repo, "t1", "ask", %{"question" => "Which copy do you prefer?"})
    assert %{"card_id" => card_id, "state" => "open"} = get_in(asked, ["result", "structuredContent", "ask"])
    assert card_id == card["id"]

    reviewed = [chief("t0"), child("t1", "t0", %{"sympp.review_id" => "rvw_card"})]
    review = {:ok, %{"done" => true, "status" => "passed", "reviewed_head" => "h1"}}
    sweep(repo, reviewed, %{head("feature-1") => {:ok, pr(7, "open")}}, review: fn "rvw_card", nil -> review end)

    assert [%{"state" => "review_ci", "pr" => %{"number" => 7, "ci" => %{"status" => "passing"}}, "review" => %{"id" => "rvw_card", "state" => "done"}, "asks" => [_open]}] =
             list(repo)

    # A known PR is read by number from then on.
    sweep(repo, reviewed, %{{:pr, "acme", "app", 7} => {:ok, pr(7, "merged")}}, review: fn _id, _machine -> review end)

    assert [%{"state" => "merged", "asks" => []} = merged] = list(repo)
    assert is_binary(merged["ended_at"])
    assert repo.get!(Ask, get_in(asked, ["result", "structuredContent", "ask", "id"])).state == "withdrawn"
    assert %WorkedOn{state: "finished", finish_reason: "subject_ended"} = repo.get_by!(WorkedOn, subject_kind: "card", subject_id: card_id)
  end

  test "cards go to chief and architect children with a branch, and to sympp.card=1, never to workers", %{repo: repo} do
    repo.insert!(%WorkedOn{
      id: "wo-architect",
      subject_kind: "work_request",
      subject_id: "WR-ANY",
      terminal_key: "#{@core}/t9",
      display_address: "testbox/t9",
      role: "architect",
      state: "finished",
      started_at: DateTime.utc_now(:microsecond)
    })

    repo.insert!(%WorkedOn{
      id: "wo-remote-architect",
      subject_kind: "work_request",
      subject_id: "WR-OTHER",
      terminal_key: "desk-core/t1qt",
      display_address: "desk/t1qt",
      role: "architect",
      state: "live",
      started_at: DateTime.utc_now(:microsecond)
    })

    terminals = [
      chief("t0"),
      child("t2", "t0", %{"sympp.role" => "worker"}),
      child("t3", nil),
      child("t4", nil, %{"sympp.card" => "1"}),
      child("t5", "t9"),
      child("t6", "desk/t1qt"),
      child("t7", "t0"),
      child("t8", "t0"),
      child("t10", "t3")
    ]

    git = fn
      "/work/t7" -> {:ok, %{@git | branch: "main"}}
      "/work/t8" -> :error
      _cwd -> {:ok, @git}
    end

    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}}, git: git)

    assert repo.all(Card) |> Enum.map(& &1.terminal_key) |> Enum.sort() == Enum.sort(Enum.map(~w(t4 t5 t6), &"#{@core}/#{&1}"))
  end

  test "unknown inputs never end a card; a finished terminal without a PR does", %{repo: repo} do
    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}})

    # The core can't be read: the terminal's state is unknown.
    sweep(repo, :unavailable, %{head("feature-1") => {:ok, nil}})
    assert [%{"state" => "working"}] = list(repo)

    finished = [chief("t0"), Map.put(child("t1", "t0"), "state", "finished")]
    Observer.observe_terminals(repo, core(finished))

    sweep(repo, finished, %{head("feature-1") => {:error, :request_failed}})
    assert [%{"state" => "working", "stale" => ["github"]}] = list(repo)

    sweep(repo, finished, %{head("feature-1") => {:ok, nil}})
    assert [%{"state" => "done", "stale" => []}] = list(repo)
  end

  test "a closed PR ends the card; a new branch in the same terminal opens it again", %{repo: repo} do
    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("feature-1") => {:ok, pr(9, "open")}})
    assert [%{"state" => "review_ci"}] = list(repo)

    sweep(repo, terminals, %{{:pr, "acme", "app", 9} => {:ok, pr(9, "closed")}})
    assert [%{"state" => "done"}] = list(repo)

    # Still on the closed branch: nothing new.
    sweep(repo, terminals, %{})
    assert [%{"state" => "done"}] = list(repo)

    on_new_branch = fn _cwd -> {:ok, %{@git | branch: "feature-2"}} end
    sweep(repo, terminals, %{head("feature-2") => {:ok, nil}}, git: on_new_branch)
    assert [%{"state" => "working", "branch" => "feature-2", "worked_on" => %{"liveness" => _liveness}} = card] = list(repo)
    refute Map.has_key?(card, "pr")
    refute Map.has_key?(card, "ended_at")
  end

  test "the operator dismisses a card from the board or the Herdr panel", %{repo: repo} do
    sweep(repo, [chief("t0"), child("t1", "t0")], %{head("feature-1") => {:ok, nil}})
    [%{"id" => card_id}] = list(repo)
    asked = mcp_tool(repo, "t1", "ask", %{"question" => "Still needed?"})

    assert {:ok, %Card{state: "dismissed"}} = Cards.dismiss(repo, card_id)
    assert {:ok, %Card{state: "dismissed"}} = Cards.dismiss(repo, card_id)
    assert {:error, :not_found} = Cards.dismiss(repo, "card_missing")
    assert repo.get!(Ask, get_in(asked, ["result", "structuredContent", "ask", "id"])).state == "withdrawn"

    refused = mcp_tool(repo, "t1", "ask", %{"question" => "After dismissal?"})
    assert %{"reason" => "no_open_card", "state" => "no_card"} = get_in(refused, ["error", "data"])
  end

  test "an ask on a card is answered by the operator and typed into the asking terminal", %{repo: repo} do
    no_card = mcp_tool(repo, "t1", "ask", %{"question" => "Before any branch?"})
    assert %{"reason" => "no_open_card", "next_action" => next_action} = get_in(no_card, ["error", "data"])
    assert next_action =~ "work_request_id"

    package_only = mcp_tool(repo, "t1", "ask", %{"work_package_id" => "WP-ANY", "question" => "Which package?"})
    assert get_in(package_only, ["error", "data", "reason"]) == "missing_work_request_id"

    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("feature-1") => {:ok, nil}})
    asked = mcp_tool(repo, "t1", "ask", %{"question" => "Ship the dark theme?"})
    ask_id = get_in(asked, ["result", "structuredContent", "ask", "id"])

    decision = %{"source_type" => "human", "decision" => "Yes", "rationale" => "Asked", "scope_impact" => "None"}
    with_decision = mcp_tool(repo, "t1", "resolve_ask", %{"ask_id" => ask_id, "to" => "answered", "answer" => "Yes", "decision" => decision})
    assert get_in(with_decision, ["error", "data", "reason"]) == "decision_needs_work_request"

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core(terminals) end)
    parent = self()
    paste = fn target, text -> send(parent, {:pasted, target, text}) && :ok end
    Application.put_env(:symphony_elixir, :sympp_herdr_send, paste)

    assert {:ok, %Ask{state: "answered", card_id: card_id}, %{"state" => "delivered"}} =
             Asks.answer_by_operator(repo, ask_id, %{"answer" => "Yes, ship it."})

    assert card_id == Cards.card_id("#{@core}/t1")
    assert_receive {:pasted, "t1", "Answer: Yes, ship it."}
  end

  test "a PR from the base branch opens a card with its repository; a dismissal during a sweep wins", %{repo: repo} do
    on_main = fn _cwd -> {:ok, %{@git | branch: "main"}} end
    terminals = [chief("t0"), child("t1", "t0")]
    sweep(repo, terminals, %{head("main") => {:ok, nil}}, git: on_main)
    assert list(repo) == []

    sweep(repo, terminals, %{head("main") => {:ok, %{pr(4, "open") | "branch" => "main", "base_branch" => "release"}}}, git: on_main)
    assert [%{"id" => card_id, "state" => "review_ci", "repository" => "acme/app", "base_branch" => "main", "branch" => "main"}] = list(repo)

    # The operator dismisses after the sweep read the card, before it applies.
    items = Cards.watch(repo, core: core(terminals), terminal: fn _address -> :error end, git: on_main)
    assert {:ok, _dismissed} = Cards.dismiss(repo, card_id)
    Cards.apply(repo, items, %{{:pr, "acme", "app", 4} => {:ok, %{pr(4, "open") | "head_sha" => "h2"}}}, review: fn _id, _machine -> :not_started end)
    assert [%{"state" => "dismissed", "pr" => %{"head_sha" => "h1"}}] = list(repo)
  end

  test "sympp.health shows the caller's card and the answers to its asks", %{repo: repo} do
    sweep(repo, [chief("t0"), child("t1", "t0")], %{head("feature-1") => {:ok, nil}})
    asked = mcp_tool(repo, "t1", "ask", %{"question" => "Ship it?"})
    ask_id = get_in(asked, ["result", "structuredContent", "ask", "id"])

    # The terminal can't be reached, so the answer stays on the ask.
    assert {:ok, _ask, %{"state" => "not_delivered"}} = Asks.answer_by_operator(repo, ask_id, %{"answer" => "Yes."})

    health = mcp_tool(repo, "t1", "sympp.health", %{})
    assert %{"state" => "working", "asks" => [%{"id" => ^ask_id, "answer" => "Yes.", "state" => "answered"}]} = get_in(health, ["result", "structuredContent", "caller", "card"])
    refute get_in(mcp_tool(repo, "t2", "sympp.health", %{}), ["result", "structuredContent", "caller", "card"])
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

    Application.put_env(:symphony_elixir, :sympp_herdr_core, fn -> core([Map.put(child("t1", "t0"), "state", "finished")]) end)
    assert {:ok, 1} = Cards.delete_expired(repo, 30, later)
  end

  test "git reads the repository, base and branch of a checkout without origin/HEAD" do
    dir = Path.join(System.tmp_dir!(), "sympp-card-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git = fn args -> {_output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end
    git.(["init", "--quiet", "--initial-branch", "main"])
    git.(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "root"])
    git.(["remote", "add", "origin", "https://github.com/acme/app.git"])
    git.(["update-ref", "refs/remotes/origin/main", "HEAD"])
    git.(["checkout", "--quiet", "-b", "feature-1"])

    assert {:ok, %{repository: "acme/app", base_branch: "main", branch: "feature-1"}} = Cards.Git.read(dir)
  end

  defp sweep(repo, terminals, github, opts \\ []) do
    Observer.sweep(
      repo,
      Keyword.merge(
        [
          core: if(terminals == :unavailable, do: :unavailable, else: core(terminals)),
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

  defp child(address, parent, labels \\ %{}) do
    %{"address" => address, "state" => "live", "cwd" => "/work/#{address}", "name" => "#{address} task", "parent" => parent, "labels" => labels}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

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
